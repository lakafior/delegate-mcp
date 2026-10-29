import Foundation

/// Zadania w tle (`delegate(background: true)`, `delegate_agent`): Claude zleca kilka naraz, pracuje dalej
/// i odbiera wyniki przez `delegate_result`. Z `store` stan każdego zadania trafia też na dysk, bo klient MCP
/// restartuje serwer po zerwanym wywołaniu, a zadania agentów trwają minuty: wynik przeżyje restart,
/// a zadanie przerwane razem z procesem zostanie tak oznaczone, zamiast „trwać” w nieskończoność.
public actor DelegateJobs {
    public enum State: Sendable, Equatable {
        case running
        case done(String)
        case failed(String)
    }

    /// Co to za zadanie, dla zakładki Jobs w apce. `branch` znamy dopiero po zakończeniu zadania w trybie zapisu.
    public struct Details: Sendable, Equatable, Codable {
        public var agent: String?
        public var model: String?
        public var repo: String?
        public var write: Bool?
        public var branch: String?

        public init(agent: String? = nil, model: String? = nil, repo: String? = nil, write: Bool? = nil, branch: String? = nil) {
            self.agent = agent
            self.model = model
            self.repo = repo
            self.write = write
            self.branch = branch
        }
    }

    /// Wynik operacji w tle: tekst dla `delegate_result` i gałąź z pracą agenta, jeśli została.
    public struct Outcome: Sendable {
        public var text: String
        public var branch: String?

        public init(text: String, branch: String? = nil) {
            self.text = text
            self.branch = branch
        }
    }

    public struct Job: Sendable {
        public let id: String
        public let label: String
        public let started: Date
        public var finished: Date?
        public var state: State
        public var details: Details?

        public init(id: String, label: String, started: Date, finished: Date? = nil, state: State, details: Details? = nil) {
            self.id = id
            self.label = label
            self.started = started
            self.finished = finished
            self.state = state
            self.details = details
        }
    }

    /// Górna granica czekania w jednym wywołaniu `delegate_result`. Claude zrywa wywołanie narzędzia po ok. 60 s,
    /// a po takim zerwaniu restartuje serwer.
    public static let maxWaitSeconds = 40.0

    private let run: @Sendable (DelegateRequest) async throws -> String
    private let store: JobStore?
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var counter = 0

    public init(run: @escaping @Sendable (DelegateRequest) async throws -> String, store: JobStore? = nil) {
        self.run = run
        self.store = store
    }

    public init(service: DelegateService, store: JobStore? = nil) {
        self.init(run: { try await service.delegate($0) }, store: store)
    }

    /// Uruchamia zadanie `delegate` i od razu zwraca jego ID.
    public func start(_ request: DelegateRequest) -> String {
        let run = self.run
        let details = Details(model: request.model ?? request.task.map { "task: \($0)" })
        return start(label: Self.label(for: request), details: details) { try await run(request) }
    }

    /// Uruchamia dowolną operację w tle.
    public func start(label: String, details: Details? = nil, operation: @escaping @Sendable () async throws -> String) -> String {
        start(label: label, details: details, outcome: { Outcome(text: try await operation()) })
    }

    /// Jak wyżej, ale operacja może zgłosić gałąź, na której zostawiła pracę.
    public func start(label: String, details: Details?, outcome: @escaping @Sendable () async throws -> Outcome) -> String {
        let id = newID()
        let job = Job(id: id, label: label, started: Date(), state: .running, details: details)
        jobs[id] = job
        order.append(id)
        store?.save(job)
        Task {
            do {
                let result = try await outcome()
                self.finish(id, .done(result.text), branch: result.branch)
            } catch {
                // Agent po przekroczeniu czasu może zostawić gałąź z niedokończoną pracą.
                self.finish(id, .failed("\(error)"), branch: (error as? DelegateError)?.branch)
            }
        }
        return id
    }

    /// Bez `store` krótkie `j1`, `j2`…; z `store` losowe, bo kilka procesów serwera (sesji) dzieli katalog.
    private func newID() -> String {
        guard let store else {
            counter += 1
            return "j\(counter)"
        }
        while true {
            let id = "j" + String(UInt32.random(in: 0x10000...0xFFFFF), radix: 16)
            if jobs[id] == nil && !store.exists(id) { return id }
        }
    }

    private func finish(_ id: String, _ state: State, branch: String?) {
        jobs[id]?.state = state
        jobs[id]?.finished = Date()
        if let branch {
            var details = jobs[id]?.details ?? Details()
            details.branch = branch
            jobs[id]?.details = details
        }
        if let job = jobs[id] { store?.save(job) }
    }

    public func job(_ id: String) -> Job? { jobs[id] }

    public var all: [Job] { order.compactMap { jobs[$0] } }

    /// Czeka (najwyżej `wait` s), aż wszystkie wskazane zadania się skończą; puste `ids` = zadania tej sesji.
    /// Zadania spoza pamięci (sprzed restartu serwera) czyta z dysku.
    /// Czeka na jedno zadanie najwyżej `seconds` i zwraca jego stan (`.running`, gdy nie zdążyło; `nil`: nie ma takiego).
    public func state(of id: String, waiting seconds: Double, now: @Sendable () -> Date = Date.init) async -> State? {
        let deadline = now().addingTimeInterval(max(seconds, 0))
        while now() < deadline, case .running? = jobs[id]?.state {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return jobs[id]?.state
    }

    public func result(ids: [String], wait: Double, now: @Sendable () -> Date = Date.init) async -> String {
        let wanted = ids.isEmpty ? order : ids
        let deadline = now().addingTimeInterval(min(max(wait, 0), Self.maxWaitSeconds))
        while now() < deadline, wanted.contains(where: { if case .running = jobs[$0]?.state { true } else { false } }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !wanted.isEmpty else { return "No background jobs." }
        return wanted.map { id in
            if let job = jobs[id] { return Self.describe(job, now: now()) }
            guard let stored = store?.load(id) else { return "## \(id): unknown job" }
            if case .running = stored.job.state, !stored.ownerAlive {
                return "## \(id) (\(stored.job.label)): interrupted (the server restarted while it ran); start it again"
            }
            return Self.describe(stored.job, now: now())
        }.joined(separator: "\n\n")
    }

    static func describe(_ job: Job, now: Date) -> String {
        switch job.state {
        case .running:
            return "## \(job.id) (\(job.label)): running for \(Int(now.timeIntervalSince(job.started))) s"
        case .done(let text):
            return "## \(job.id) (\(job.label)): done\n\(text)"
        case .failed(let error):
            return "## \(job.id) (\(job.label)): failed\n\(error)"
        }
    }

    /// Krótki podpis: plik wynikowy albo początek promptu.
    static func label(for r: DelegateRequest) -> String {
        if let out = r.outputFile { return "→ " + (out as NSString).lastPathComponent }
        return shortLabel(r.prompt)
    }

    public static func shortLabel(_ text: String) -> String {
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return first.count > 50 ? String(first.prefix(50)) + "…" : first
    }
}

/// Zadania na dysku: `jobs/<id>.json` z PID-em procesu, który je prowadzi.
public struct JobStore: Sendable {
    let directory: URL
    /// Po tylu sekundach pliki zadań są sprzątane.
    let maxAge: TimeInterval

    public init(directory: URL, maxAge: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.maxAge = maxAge
    }

    struct Record: Codable {
        var id: String
        var label: String
        var started: Date
        var finished: Date?
        var state: String
        var text: String?
        var pid: Int32
        var details: DelegateJobs.Details?
    }

    public struct Stored: Sendable, Identifiable {
        public var job: DelegateJobs.Job
        /// Czy proces, który zapisał zadanie, jeszcze żyje.
        public var ownerAlive: Bool
        public var id: String { job.id }

        /// Zadanie „trwa” na dysku, ale jego serwer już nie żyje.
        public var interrupted: Bool {
            if case .running = job.state { !ownerAlive } else { false }
        }
    }

    /// Z ułamkami sekund: zadania startujące w tej samej sekundzie muszą się dać posortować.
    private static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    func save(_ job: DelegateJobs.Job) {
        let (state, text): (String, String?) = switch job.state {
        case .running: ("running", nil)
        case .done(let t): ("done", t)
        case .failed(let t): ("failed", t)
        }
        let record = Record(id: job.id, label: job.label, started: job.started, finished: job.finished,
                            state: state, text: text, pid: ProcessInfo.processInfo.processIdentifier, details: job.details)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Self.dateFormat))
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Zapis atomowy: inny proces serwera nigdy nie przeczyta połowy pliku.
        try? encoder.encode(record).write(to: url(job.id), options: .atomic)
    }

    func load(_ id: String) -> Stored? {
        // ID pochodzi od Claude'a: nie pozwalamy wyjść poza katalog zadań.
        guard !id.contains("/"), !id.hasPrefix("."), let data = try? Data(contentsOf: url(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Starsze pliki mają sekundy bez ułamków.
            if let date = (try? Date(text, strategy: Self.dateFormat)) ?? (try? Date(text, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
        guard let r = try? decoder.decode(Record.self, from: data) else { return nil }
        let state: DelegateJobs.State = switch r.state {
        case "done": .done(r.text ?? "")
        case "failed": .failed(r.text ?? "")
        default: .running
        }
        let job = DelegateJobs.Job(id: r.id, label: r.label, started: r.started, finished: r.finished, state: state,
                                   details: r.details)
        return Stored(job: job, ownerAlive: kill(r.pid, 0) == 0)
    }

    /// Wszystkie zadania z dysku (każdej sesji), najnowsze pierwsze.
    public func all() -> [Stored] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.job.started > $1.job.started }
    }

    /// Usuwa plik zadania (z listy w apce); trwającego zadania nie ruszamy.
    public func remove(_ id: String) {
        guard let stored = load(id), !(stored.ownerAlive && stored.job.state == .running) else { return }
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Usuwa pliki zadań starsze niż `maxAge`.
    public func purge(now: Date = Date()) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(date) > maxAge { try? fm.removeItem(at: file) }
        }
    }
}

extension DelegateHome {
    /// Zadania w tle zapisane na dysk (`JobStore`).
    public var jobsURL: URL { directory.appendingPathComponent("jobs", isDirectory: true) }
}

/// Limit agentów pracujących naraz (`max_parallel_agents`): kolejne zadania czekają w kolejce na wolne miejsce,
/// żeby kilka zleceń naraz nie wyczerpało subskrypcji w kwadrans ani nie zatkało Maca budowaniem.
public actor AgentSlots {
    public nonisolated let limit: Int
    private var used = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async {
        if used < limit {
            used += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if waiting.isEmpty {
            used = max(0, used - 1)
        } else {
            waiting.removeFirst().resume()
        }
    }

    public var queued: Int { waiting.count }
}

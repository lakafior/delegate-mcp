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

    public struct Job: Sendable {
        public let id: String
        public let label: String
        public let started: Date
        public var finished: Date?
        public var state: State
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
        return start(label: Self.label(for: request)) { try await run(request) }
    }

    /// Uruchamia dowolną operację w tle.
    public func start(label: String, operation: @escaping @Sendable () async throws -> String) -> String {
        let id = newID()
        let job = Job(id: id, label: label, started: Date(), state: .running)
        jobs[id] = job
        order.append(id)
        store?.save(job)
        Task {
            let state: State
            do { state = .done(try await operation()) } catch { state = .failed("\(error)") }
            self.finish(id, state)
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

    private func finish(_ id: String, _ state: State) {
        jobs[id]?.state = state
        jobs[id]?.finished = Date()
        if let job = jobs[id] { store?.save(job) }
    }

    public func job(_ id: String) -> Job? { jobs[id] }

    public var all: [Job] { order.compactMap { jobs[$0] } }

    /// Czeka (najwyżej `wait` s), aż wszystkie wskazane zadania się skończą; puste `ids` = zadania tej sesji.
    /// Zadania spoza pamięci (sprzed restartu serwera) czyta z dysku.
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
    }

    struct Stored {
        var job: DelegateJobs.Job
        /// Czy proces, który zapisał zadanie, jeszcze żyje.
        var ownerAlive: Bool
    }

    private func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    func save(_ job: DelegateJobs.Job) {
        let (state, text): (String, String?) = switch job.state {
        case .running: ("running", nil)
        case .done(let t): ("done", t)
        case .failed(let t): ("failed", t)
        }
        let record = Record(id: job.id, label: job.label, started: job.started, finished: job.finished,
                            state: state, text: text, pid: ProcessInfo.processInfo.processIdentifier)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Zapis atomowy: inny proces serwera nigdy nie przeczyta połowy pliku.
        try? encoder.encode(record).write(to: url(job.id), options: .atomic)
    }

    func load(_ id: String) -> Stored? {
        // ID pochodzi od Claude'a: nie pozwalamy wyjść poza katalog zadań.
        guard !id.contains("/"), !id.hasPrefix("."), let data = try? Data(contentsOf: url(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let r = try? decoder.decode(Record.self, from: data) else { return nil }
        let state: DelegateJobs.State = switch r.state {
        case "done": .done(r.text ?? "")
        case "failed": .failed(r.text ?? "")
        default: .running
        }
        let job = DelegateJobs.Job(id: r.id, label: r.label, started: r.started, finished: r.finished, state: state)
        return Stored(job: job, ownerAlive: kill(r.pid, 0) == 0)
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

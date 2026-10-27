import Foundation

/// Zadania `delegate(background: true)`: Claude zleca kilka naraz, pracuje dalej i odbiera wyniki
/// przez `delegate_result`. Żyją w pamięci procesu serwera, czyli tyle, co sesja Claude'a.
public actor DelegateJobs {
    public enum State: Sendable {
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

    /// Górna granica czekania w jednym wywołaniu `delegate_result`, żeby nie wpaść w timeout klienta MCP.
    public static let maxWaitSeconds = 120.0

    private let run: @Sendable (DelegateRequest) async throws -> String
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var counter = 0

    public init(run: @escaping @Sendable (DelegateRequest) async throws -> String) {
        self.run = run
    }

    public init(service: DelegateService) {
        self.init(run: { try await service.delegate($0) })
    }

    /// Uruchamia zadanie i od razu zwraca jego ID.
    public func start(_ request: DelegateRequest) -> String {
        counter += 1
        let id = "j\(counter)"
        jobs[id] = Job(id: id, label: Self.label(for: request), started: Date(), state: .running)
        order.append(id)
        Task { [run] in
            let state: State
            do { state = .done(try await run(request)) } catch { state = .failed("\(error)") }
            self.finish(id, state)
        }
        return id
    }

    private func finish(_ id: String, _ state: State) {
        jobs[id]?.state = state
        jobs[id]?.finished = Date()
    }

    public func job(_ id: String) -> Job? { jobs[id] }

    public var all: [Job] { order.compactMap { jobs[$0] } }

    /// Czeka (najwyżej `wait` s), aż wszystkie wskazane zadania się skończą; puste `ids` = wszystkie.
    public func result(ids: [String], wait: Double, now: @Sendable () -> Date = Date.init) async -> String {
        let wanted = ids.isEmpty ? order : ids
        let deadline = now().addingTimeInterval(min(max(wait, 0), Self.maxWaitSeconds))
        while now() < deadline, wanted.contains(where: { if case .running = jobs[$0]?.state { true } else { false } }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !wanted.isEmpty else { return "No background jobs." }
        return wanted.map { id in
            guard let job = jobs[id] else { return "## \(id): unknown job" }
            switch job.state {
            case .running:
                return "## \(id) (\(job.label)): running for \(Int(now().timeIntervalSince(job.started))) s"
            case .done(let text):
                return "## \(id) (\(job.label)): done\n\(text)"
            case .failed(let error):
                return "## \(id) (\(job.label)): failed\n\(error)"
            }
        }.joined(separator: "\n\n")
    }

    /// Krótki podpis: plik wynikowy albo początek promptu.
    static func label(for r: DelegateRequest) -> String {
        if let out = r.outputFile { return "→ " + (out as NSString).lastPathComponent }
        let first = r.prompt.split(separator: "\n").first.map(String.init) ?? ""
        return first.count > 50 ? String(first.prefix(50)) + "…" : first
    }
}

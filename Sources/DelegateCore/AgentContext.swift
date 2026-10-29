import Foundation

/// Wejście agenta po referencji: raporty wcześniejszych zadań (`context_jobs`) i pliki (`context_files`) serwer
/// kopiuje do kopii repo, zamiast żeby dyrygent czytał je i przepisywał do briefu (płaci za odczyt i za drogie wyjście,
/// a agent dostaje jego streszczenie zamiast całości).
public struct AgentContext: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// Nazwa pliku w `directory`.
        public var name: String
        /// Skąd: „report of job j1 (…)” albo ścieżka pliku.
        public var source: String
        public var text: String
    }

    public var items: [Item]
    /// Najostrzejsza wrażliwość źródeł. Raport agenta zawiera kod repo, więc zadanie, które go dostaje, nie może
    /// pójść do regionu, do którego nie poszłoby zadanie źródłowe.
    public var sensitivity: Sensitivity

    /// Katalog w kopii repo; w trybie zapisu usuwany przed commitem (`remove`).
    public static let directory = ".delegate-context"

    public var isEmpty: Bool { items.isEmpty }

    /// `jobs`: zadania znalezione po ID (w tej sesji albo na dysku); brakujące ID to błąd.
    public static func resolve(jobIDs: [String], files: [String], jobs: [String: DelegateJobs.Job]) throws -> AgentContext {
        var items: [Item] = []
        var sensitivity = Sensitivity.public
        var total = 0
        func add(_ name: String, _ source: String, _ text: String) throws {
            guard text.utf8.count <= FileAttachments.maxFileBytes else {
                throw DelegateError(description: "Context \(source) is over \(FileAttachments.maxFileBytes / 1024) KB; pass a shorter report.")
            }
            total += text.utf8.count
            guard total <= FileAttachments.maxTotalBytes else {
                throw DelegateError(description: "Context is over \(FileAttachments.maxTotalBytes / 1024) KB in total.")
            }
            var unique = name
            var n = 2
            while items.contains(where: { $0.name == unique }) {
                unique = "\(n)-\(name)"
                n += 1
            }
            items.append(Item(name: unique, source: source, text: text))
        }

        for id in jobIDs {
            guard let job = jobs[id] else { throw DelegateError(description: "context_jobs: no job \(id).") }
            let text: String
            switch job.state {
            case .running: throw DelegateError(description: "context_jobs: job \(id) is still running; collect it with delegate_result first.")
            case .failed: throw DelegateError(description: "context_jobs: job \(id) failed; there is no report to pass on.")
            case .done(let result):
                // Z `report_file`/`output_file` wynik zadania to tylko podgląd; całość jest w pliku.
                text = job.details?.reportFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? result
            }
            // Zadanie bez zapisanej wrażliwości (sprzed tej wersji): ostrożnie, jak nieznana wartość.
            let source = job.details?.sensitivity.map { Sensitivity(rawValue: $0) ?? .personal } ?? .personal
            sensitivity = max(sensitivity, source)
            try add("\(id).md", "report of job \(id) (\(job.label))", text)
        }
        for path in files {
            guard path.hasPrefix("/") else { throw DelegateError(description: "context_files: \(path) is not an absolute path.") }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw DelegateError(description: "context_files: can't read \(path) as a text file.")
            }
            try add((path as NSString).lastPathComponent, path, text)
        }
        return AgentContext(items: items, sensitivity: sensitivity)
    }

    /// Zapisuje pliki do `root/.delegate-context/`. Katalog o tej nazwie w repo użytkownika to błąd: w trybie zapisu
    /// usunęlibyśmy go przed commitem razem z jego plikami.
    func write(into root: URL) throws {
        let dir = root.appendingPathComponent(Self.directory, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw DelegateError(description: "The repository already has \(Self.directory)/; context can't be passed to this repo.")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in items {
            try item.text.write(to: dir.appendingPathComponent(item.name), atomically: true, encoding: .utf8)
        }
    }

    static func remove(from root: URL) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(directory, isDirectory: true))
    }

    /// Dopisywane przed zadaniem; ostatnia linia promptu zostaje linią zadania.
    var promptNote: String {
        "Context from earlier work is in \(Self.directory)/ (copied by the server, not part of the repository). "
            + "Read it before you start:\n"
            + items.map { "- \(Self.directory)/\($0.name): \($0.source)" }.joined(separator: "\n")
    }
}

extension Sensitivity: Comparable {
    /// public < personal < private: większa = ostrzejsza.
    public static func < (a: Sensitivity, b: Sensitivity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

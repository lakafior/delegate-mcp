import Foundation

/// Jedna linia JSONL na wywołanie. Tylko metadane, bez treści promptów.
public struct UsageEntry: Codable, Sendable, Equatable {
    public var ts: Date
    public var provider: String
    public var model: String
    public var task: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var ok: Bool
    public var error: String?
    public var ms: Int

    public init(ts: Date = Date(), provider: String, model: String, task: String? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil, ok: Bool, error: String? = nil, ms: Int) {
        self.ts = ts
        self.provider = provider
        self.model = model
        self.task = task
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.ok = ok
        self.error = error
        self.ms = ms
    }

    enum CodingKeys: String, CodingKey {
        case ts, provider, model, task
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case ok, error, ms
    }
}

public struct UsageLog: Sendable {
    let url: URL

    public init(url: URL) { self.url = url }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func append(_ entry: UsageEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    public func entries(since: Date? = nil) -> [UsageEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = Self.decoder()
        return text.split(separator: "\n").compactMap { line in
            guard let e = try? decoder.decode(UsageEntry.self, from: Data(line.utf8)) else { return nil }
            if let since, e.ts < since { return nil }
            return e
        }
    }
}

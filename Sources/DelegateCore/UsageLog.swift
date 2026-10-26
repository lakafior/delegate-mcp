import Foundation

/// Jedna linia JSONL na wywołanie. Tylko metadane, bez treści promptów.
public struct UsageEntry: Codable, Sendable, Equatable {
    public var ts: Date
    public var provider: String
    public var model: String
    public var task: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    public var ok: Bool
    public var error: String?
    public var ms: Int

    public init(ts: Date = Date(), provider: String, model: String, task: String? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
                ok: Bool, error: String? = nil, ms: Int) {
        self.ts = ts
        self.provider = provider
        self.model = model
        self.task = task
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.ok = ok
        self.error = error
        self.ms = ms
    }

    enum CodingKeys: String, CodingKey {
        case ts, provider, model, task
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case ok, error, ms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Date.self, forKey: .ts)
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        ok = try c.decode(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        ms = try c.decode(Int.self, forKey: .ms)
    }
}

/// Narzędzia do szacowania kosztów i zaoszczędzonych środków względem modelu referencyjnego (Claude Sonnet).
public enum CostCalculator {
    /// Benchmark Claude Sonnet: $3.00 wejście / $15.00 wyjście za 1M tokenów.
    public static let sonnetPriceIn: Double = 3.0
    public static let sonnetPriceOut: Double = 15.0

    public static func computeCost(model: ModelConfig, inputTokens: Int?, outputTokens: Int?) -> Double? {
        if model.cost == "free" { return 0.0 }
        guard let priceIn = model.priceIn, let priceOut = model.priceOut else { return nil }
        let inCost = (Double(inputTokens ?? 0) / 1_000_000.0) * priceIn
        let outCost = (Double(outputTokens ?? 0) / 1_000_000.0) * priceOut
        return inCost + outCost
    }

    public static func benchmarkSonnetCost(inputTokens: Int?, outputTokens: Int?) -> Double {
        let inCost = (Double(inputTokens ?? 0) / 1_000_000.0) * sonnetPriceIn
        let outCost = (Double(outputTokens ?? 0) / 1_000_000.0) * sonnetPriceOut
        return inCost + outCost
    }

    /// Bez znanego kosztu (np. kategoria `cheap` bez kwot) nie zgadujemy oszczędności: zwraca 0.
    public static func savingsVsSonnet(cost: Double?, inputTokens: Int?, outputTokens: Int?) -> Double {
        guard let cost else { return 0 }
        let sonnet = benchmarkSonnetCost(inputTokens: inputTokens, outputTokens: outputTokens)
        return max(0, sonnet - cost)
    }

    /// Suma oszczędności liczona per wywołanie, tylko dla udanych wywołań ze znanym kosztem.
    public static func savingsVsSonnet(_ entries: [UsageEntry]) -> Double {
        entries.filter(\.ok).reduce(0) {
            $0 + savingsVsSonnet(cost: $1.costUSD, inputTokens: $1.inputTokens, outputTokens: $1.outputTokens)
        }
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

    /// Bezpieczny zapis z blokadą plikową (flock), chroniący przed uszkodzeniem JSONL przy równoległych zapytaniach.
    public func append(_ entry: UsageEntry) {
        guard var line = try? Self.encoder().encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer {
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
        }
        flock(handle.fileDescriptor, LOCK_EX)
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

    /// Usuwa wpisy starsze niż podana liczba dni. Zwraca liczbę usuniętych wpisów.
    @discardableResult
    public func prune(olderThan days: Int, now: Date = Date()) throws -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 1), to: now) else { return 0 }
        let all = entries()
        let kept = all.filter { $0.ts >= cutoff }
        let removed = all.count - kept.count
        guard removed > 0 else { return 0 }

        let encoder = Self.encoder()
        var data = Data()
        for entry in kept {
            if var line = try? encoder.encode(entry) {
                line.append(0x0A)
                data.append(line)
            }
        }
        try data.write(to: url, options: .atomic)
        return removed
    }

    /// Eksportuje wpisy do formatu CSV.
    public static func csv(from entries: [UsageEntry]) -> String {
        var out = "timestamp,provider,model,task,input_tokens,output_tokens,cost_usd,ok,ms\n"
        let df = ISO8601DateFormatter()
        for e in entries {
            let costStr = e.costUSD.map { String(format: "%.6f", $0) } ?? ""
            out += "\(df.string(from: e.ts)),\(e.provider),\(e.model),\(e.task ?? ""),\(e.inputTokens ?? 0),\(e.outputTokens ?? 0),\(costStr),\(e.ok),\(e.ms)\n"
        }
        return out
    }

    /// Eksportuje wpisy do formatu JSON.
    public static func json(from entries: [UsageEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        return String(decoding: data, as: UTF8.self)
    }

    /// Parsuje wpisy z formatu JSON.
    public static func parseJSON(_ json: String) throws -> [UsageEntry] {
        try decoder().decode([UsageEntry].self, from: Data(json.utf8))
    }
}

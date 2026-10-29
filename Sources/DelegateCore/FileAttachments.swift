import Foundation

/// Pliki z `delegate(files:)`: serwer czyta je sam, żeby Claude nie przepisywał długich tekstów do promptu
/// (to kosztowałoby go tyle tokenów wyjściowych, ile sam plik). Tylko tekst, z limitami rozmiaru.
/// Do dostawcy idzie nazwa pliku, nie pełna ścieżka (ta zdradza np. nazwę użytkownika).
enum FileAttachments {
    static let maxFileBytes = 512 * 1024
    static let maxTotalBytes = 1024 * 1024

    struct Composed: Sendable {
        var prompt: String
        var count: Int
        var bytes: Int
    }

    static func compose(prompt: String, paths: [String]) throws -> Composed {
        guard !paths.isEmpty else { return Composed(prompt: prompt, count: 0, bytes: 0) }
        var out = prompt
        var total = 0
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw DelegateError(description: "File \"\(raw)\": give an absolute path.")
            }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                throw DelegateError(description: "File \"\(raw)\": doesn't exist or isn't a regular file.")
            }
            let size = values?.fileSize ?? 0
            guard size <= maxFileBytes else {
                throw DelegateError(description: "File \"\(raw)\": \(size / 1024) KB, limit \(maxFileBytes / 1024) KB per file.")
            }
            total += size
            guard total <= maxTotalBytes else {
                throw DelegateError(description: "Files together exceed \(maxTotalBytes / 1024) KB.")
            }
            let data = try Data(contentsOf: url)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                throw DelegateError(description: "File \"\(raw)\": not UTF-8 text.")
            }
            out += "\n\n--- File: \(url.lastPathComponent) ---\n\(text)\n--- End of file ---"
        }
        return Composed(prompt: out, count: paths.count, bytes: total)
    }
}

/// `delegate(output_file:)`: odpowiedź idzie prosto na dysk, a Claude dostaje tylko nagłówek i podgląd.
/// Bez tego musiałby sam zapisać wynik (`Write`), czyli wygenerować go jeszcze raz swoimi tokenami.
public enum OutputFile {
    static let previewLines = 8

    /// Dopisywane do `system`: bez tego modele zaczynają od „Here is the file:”, które ląduje w pliku, a dyrygent
    /// zdejmuje je dodatkową turą (płot ``` zdejmuje `stripFence`, wstępu i komentarza na końcu nie).
    static let fileOnlyRule = "Your reply is written to a file as is. Reply with the file content only: "
        + "no preamble, no explanation or closing remarks, no code fence around it."

    static func system(adding rule: String = fileOnlyRule, to system: String?) -> String {
        guard let system, !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rule }
        return system + "\n\n" + rule
    }

    /// Sprawdzane przed wywołaniem modelu, żeby nie płacić za odpowiedź, której nie da się zapisać.
    public static func validate(_ raw: String) throws -> URL {
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw DelegateError(description: "output_file \"\(raw)\": give an absolute path.")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw DelegateError(description: "output_file \"\(raw)\" is a directory.")
        }
        return URL(fileURLWithPath: path)
    }

    /// Modele lubią owijać całą odpowiedź w ```…```; w pliku ten płot jest zbędny.
    static func stripFence(_ text: String) -> (text: String, stripped: Bool) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count >= 2, lines[0].hasPrefix("```"), lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
              !lines.dropFirst().dropLast().contains(where: { $0.hasPrefix("```") }) else { return (text, false) }
        lines.removeFirst()
        lines.removeLast()
        return (lines.joined(separator: "\n") + "\n", true)
    }

    /// Zapisuje odpowiedź i zwraca opis dla Claude'a (zamiast pełnej treści).
    public static func write(_ reply: String, to url: URL) throws -> String {
        let (text, stripped) = stripFence(reply)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        let lines = text.components(separatedBy: "\n")
        let preview = lines.prefix(previewLines).map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
        var out = "\(existed ? "Overwrote" : "Wrote") \(url.path): \(lines.count) lines, \(text.utf8.count) bytes"
        if stripped { out += " (outer code fence removed)" }
        out += ". Review with git diff or Read rather than trusting it blindly.\nPreview:\n" + preview.joined(separator: "\n")
        if lines.count > previewLines { out += "\n…" }
        return out
    }
}

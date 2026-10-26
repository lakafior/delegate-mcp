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

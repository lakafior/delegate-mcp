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
                throw DelegateError(description: "Plik „\(raw)”: podaj ścieżkę absolutną.")
            }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else {
                throw DelegateError(description: "Plik „\(raw)”: nie istnieje albo to nie jest zwykły plik.")
            }
            let size = values?.fileSize ?? 0
            guard size <= maxFileBytes else {
                throw DelegateError(description: "Plik „\(raw)”: \(size / 1024) KB, limit \(maxFileBytes / 1024) KB na plik.")
            }
            total += size
            guard total <= maxTotalBytes else {
                throw DelegateError(description: "Pliki razem przekraczają \(maxTotalBytes / 1024) KB.")
            }
            let data = try Data(contentsOf: url)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                throw DelegateError(description: "Plik „\(raw)”: to nie jest tekst UTF-8.")
            }
            out += "\n\n--- File: \(url.lastPathComponent) ---\n\(text)\n--- End of file ---"
        }
        return Composed(prompt: out, count: paths.count, bytes: total)
    }
}

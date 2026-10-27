import Foundation

/// Rejestracja serwera `delegate` w OpenAI Codex CLI. Codex trzyma serwery MCP w `~/.codex/config.toml`,
/// po jednej tabeli `[mcp_servers.<name>]` z `command`. TOMLKit przy zapisie przestawia klucze i gubi
/// komentarze, więc plik edytujemy tekstowo: podmieniamy (albo dopisujemy) wyłącznie tabelę `delegate`,
/// a reszta pliku — inne tabele, komentarze, puste linie, kolejność — zostaje bajt w bajt.
public enum CodexMCPConfig {
    /// Nagłówek tabeli serwera w configu Codexa.
    private static let tableHeader = "[mcp_servers.delegate]"
    /// Prefiks podtabel `[mcp_servers.delegate]`, np. `[mcp_servers.delegate.env]`.
    private static let subtablePrefix = "[mcp_servers.delegate."

    /// `~/.codex/config.toml` w katalogu domowym użytkownika.
    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    /// Wartość `command` z tabeli `[mcp_servers.delegate]`, czyli ścieżka zarejestrowanego serwera;
    /// `nil`, gdy tabeli albo klucza nie ma. Szukamy tylko w liniach tej tabeli (do najbliższego
    /// nagłówka innej tabeli), więc `command` pozostałych serwerów nie myli wyniku.
    public static func registeredCommand(in text: String) -> String? {
        let all = lines(of: text)
        guard let (header, end) = locatedTable(in: all) else { return nil }
        for line in all[(header + 1)..<end] {
            let trimmed = line.trimmed
            if trimmed.hasPrefix("[") { break }
            if let value = commandValue(in: trimmed) { return value }
        }
        return nil
    }

    /// Tekst po wpisaniu (`command != nil`) albo usunięciu (`command == nil`) tabeli `delegate`.
    /// Przy zapisie cała tabela — łącznie z podtabelami jak `[mcp_servers.delegate.env]` — zamienia się
    /// na świeży wpis samego `command`; komentarz tuż przed następną tabelą zostaje na miejscu.
    /// Brak tabeli przy zapisie oznacza dopisanie na końcu pliku, po pustej linii. Cała pozostała
    /// treść pliku — inne tabele, komentarze, puste linie, kolejność kluczy — zostaje bez zmian.
    public static func updating(_ text: String, command: String?) -> String {
        let all = lines(of: text)
        guard let (header, end) = locatedTable(in: all) else {
            guard let command else { return text }
            return appending(command, to: text)
        }
        if let command {
            return text.replacingCharacters(
                in: all[header].start..<bodyEnd(in: all, header: header, end: end),
                with: freshTable(command)
            )
        }
        var prefix = String(text[..<all[header].start])
        let suffix = String(text[bodyEnd(in: all, header: header, end: end)...])
        // Na łączeniu po usunięciu nie zostają dwie puste linie ani pusty separator na końcu pliku.
        if prefix.hasSuffix("\n\n"), suffix.isEmpty || suffix.hasPrefix("\n") { prefix.removeLast() }
        return prefix + suffix
    }

    /// Koniec treści tabeli (za ostatnią linią): kolejne bloki niepustych linii — klucze i podtabele
    /// `delegate`. Blok z samymi komentarzami wchodzi do wpisu tylko wtedy, gdy po nim następuje blok
    /// treści; komentarz tuż przed obcą tabelą należy do niej i zostaje na miejscu.
    private static func bodyEnd(in all: [Line], header: Int, end: Int) -> String.Index {
        var last = all[header].end
        var index = header + 1
        while index < end {
            let blockStart = index
            while index < end, !all[index].trimmed.isEmpty { index += 1 }
            let block = all[blockStart..<index]
            if !block.allSatisfy({ $0.trimmed.hasPrefix("#") }) { last = all[index - 1].end }
            while index < end, all[index].trimmed.isEmpty { index += 1 }
        }
        return last
    }

    // MARK: - budowanie wpisu

    /// Świeży wpis: sam nagłówek i `command` jako podstawowy string TOML.
    private static func freshTable(_ command: String) -> String {
        tableHeader + "\ncommand = \"" + escaped(command) + "\"\n"
    }

    /// Ścieżka jako podstawowy string TOML; uciekamy tylko `\` i `"` — w ścieżce nic więcej nie występuje.
    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Dopisanie wpisu na koniec pliku, po pustej linii (chyba że plik jest pusty).
    private static func appending(_ command: String, to text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return freshTable(command) }
        var base = text
        if !base.hasSuffix("\n") { base += "\n" }
        if !base.hasSuffix("\n\n") { base += "\n" }
        return base + freshTable(command)
    }

    // MARK: - czytanie

    /// Wartość klucza `command` z jednej linii (podstawowy string `"…"` albo literalny `'…'`);
    /// `nil`, gdy linia nie definiuje `command` lub wartość nie jest stringiem.
    private static func commandValue(in line: String) -> String? {
        var rest = Substring(line)
        guard rest.hasPrefix("command") else { return nil }
        rest = rest.dropFirst("command".count)
        guard let first = rest.first, first == "=" || first == " " || first == "\t" else { return nil }
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst()
        while let c = rest.first, c == " " || c == "\t" { rest = rest.dropFirst() }
        guard let quote = rest.first else { return nil }
        rest = rest.dropFirst()
        if quote == "'" {
            guard let close = rest.firstIndex(of: "'") else { return nil }
            return String(rest[..<close])
        }
        guard quote == "\"" else { return nil }
        var value = ""
        var index = rest.startIndex
        while index < rest.endIndex {
            let c = rest[index]
            if c == "\"" { return value }
            if c == "\\" {
                index = rest.index(after: index)
                guard index < rest.endIndex else { return nil }
                switch rest[index] {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "b": value.append("\u{08}")
                case "f": value.append("\u{0C}")
                case "u", "U":
                    let width = rest[index] == "u" ? 4 : 8
                    let start = rest.index(after: index)
                    guard let end = rest.index(start, offsetBy: width, limitedBy: rest.endIndex),
                          let code = UInt32(rest[start..<end], radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    value.unicodeScalars.append(scalar)
                    index = rest.index(before: end)
                default:
                    return nil
                }
            } else {
                value.append(c)
            }
            index = rest.index(after: index)
        }
        return nil
    }

    // MARK: - analiza tekstu

    /// Jedna linia pliku: treść bez terminatora oraz zakres od startu linii do za jej `\n`.
    private struct Line {
        let raw: Substring
        let start: String.Index
        let end: String.Index

        var trimmed: String { raw.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Wszystkie linie tekstu, od pierwszej do ostatniej znaku (terminatory w zakresach).
    private static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let end = newline < text.endIndex ? text.index(after: newline) : newline
            result.append(Line(raw: text[start..<newline], start: start, end: end))
            start = end
        }
        return result
    }

    /// Indeks linii nagłówka `[mcp_servers.delegate]` oraz pierwszej za nią linii, która jest
    /// nagłówkiem obcej tabeli (podtabele `delegate` są częścią wpisu), albo liczby linii przy końcu pliku.
    private static func locatedTable(in all: [Line]) -> (header: Int, end: Int)? {
        guard let header = all.firstIndex(where: { isDelegateHeader($0.trimmed) }) else { return nil }
        var end = all.count
        for (index, line) in all.enumerated() where index > header {
            let trimmed = line.trimmed
            if trimmed.hasPrefix("["), !trimmed.hasPrefix(subtablePrefix) {
                end = index
                break
            }
        }
        return (header, end)
    }

    /// Czy linia (bez białych znaków) jest nagłówkiem tabeli `delegate`; toleruje komentarz za `]`.
    private static func isDelegateHeader(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix(tableHeader) else { return false }
        let rest = trimmed.dropFirst(tableHeader.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "#"
    }
}

# delegate — serwer MCP do delegowania zadań na inne modele

Claude (na subskrypcji Pro) dostaje narzędzia, którymi może oddać samodzielne zadania
do Mistrala, Gemini, DeepSeeka albo OpenRoutera. Kolejność prób ustalasz w
`delegate.toml` (kolejność `[[provider]]` = priorytet). Gdy model zwróci błąd (limit,
brak środków, awaria), serwer automatycznie próbuje następnego.

Całość jest w Swift, bez Pythona i `uv`: aplikacja menu bar (SwiftUI, Liquid Glass) do edycji
configu i kluczy + serwer MCP po stdio. Minimum: macOS 26. Dostawcą może być też model na
urządzeniu (Apple Foundation Models, `type = "foundation"`): bez klucza, offline, krótkie zadania.

## Struktura

| Element | Rola | Stan |
|---|---|---|
| `Sources/DelegateCore` | config (TOML), klienci dostawców, model na urządzeniu, router z fallbackiem, log użycia, klucze, integracja z Claude | gotowe |
| `Sources/delegate-mcp` | serwer MCP po stdio (oficjalne `modelcontextprotocol/swift-sdk`) | gotowe |
| `Tests/DelegateCoreTests` | testy na mockowanym transporcie HTTP (swift-testing) | gotowe |
| `Sources/Delegate` | aplikacja menu bar: klucze (Keychain), kolejność (przeciąganie), modele/tagi, routing, użycie, instalacja w Claude Desktop/Code | gotowe, do testów z prawdziwymi kluczami |

## Narzędzia, które widzi Claude

| Narzędzie | Do czego |
|---|---|
| `list_models` | Lista dostawców i modeli wg priorytetu, z tagami, kosztami, statusem klucza i zasadami routingu |
| `delegate` | Wysyła zadanie: `model` (`provider/model`), `task` (tag) albo automatycznie wg priorytetu; opcjonalnie `system`, `temperature`, `max_tokens`, `fallback=false` |
| `list_remote_models` | Pyta API dostawcy o aktualne ID modeli, z sugerowanymi tagami, kontekstem i cenami (jeśli API je podaje) |
| `update_models` | Zapisuje tagi i koszt modeli w `delegate.toml` (upsert, bez kluczy). Koszt: kategoria (`free`/`cheap`/`paid`/`varies`) albo `price_in`/`price_out` w USD za 1M tokenów |
| `usage_summary` | Podsumowanie wywołań i tokenów z lokalnego logu |

Każda odpowiedź `delegate` zaczyna się od nagłówka: który model odpowiedział, ile tokenów
zużył i jakie były fallbacki.

## Budowanie i testy

```bash
swift build
swift test
```

Wymaga Xcode z Swift 6.2+ i macOS 26+. Zależności (swift-sdk, TOMLKit) pobiera SwiftPM.

Aplikacja: `./scripts/build-app.sh` składa `dist/Delegate.app` (serwer w `Contents/Helpers/delegate-mcp`,
podpis ad-hoc; `SIGN_ID="Developer ID Application: …"` do dystrybucji). Flagi aplikacji do ręcznego
sprawdzania widoków: `--settings` otwiera okno przy starcie, `--select=routing|usage|general|<id dostawcy>`
wybiera panel. `DELEGATE_HOME=/tmp/x` odcina od prawdziwego configu.

## Instalacja i dystrybucja

Ikona: `Assets/AppIcon.icon` (Icon Composer), kompilowana przez `actool` w `build-app.sh`.

- **Na własnym Macu:** `SIGN_ID="Apple Development: …" ./scripts/install.sh` buduje, podpisuje i kopiuje do
  `/Applications`. Stabilny podpis zespołu (zamiast ad-hoc) sprawia, że zgoda „Zawsze zezwalaj” na
  Keychain przeżywa przebudowania. Tożsamości: `security find-identity -v -p codesigning`.
- **Dla innych ludzi:** podpis „Developer ID Application” → `./scripts/build-app.sh` →
  `./scripts/notarize.sh` (profil `notarytool store-credentials`) → `./scripts/make-dmg.sh`.

## Pliki użytkownika

Katalog: `~/Library/Application Support/Delegate/` (nadpisywany przez `$DELEGATE_HOME`).

- `delegate.toml` — config. Tworzony z domyślnego, jeśli go brak (`delegate-mcp --init`).
  Wczytywany przy każdym wywołaniu, więc restart nie jest potrzebny.
- `.env` — awaryjne klucze (`MISTRAL_API_KEY=...`), `chmod 600`.
- `delegate_usage.jsonl` — log użycia (tylko metadane, bez treści promptów).

Klucze: zmienna środowiska → `.env` → Keychain (service `com.mar.delegate`, account =
`api_key_env` z configu). Dostawca bez klucza jest pomijany, nic się nie psuje.

## Podpięcie w Claude

Najprościej z aplikacji: Ogólne → Claude → „Zainstaluj” (Desktop, Code, blok instrukcji).
Ręcznie:

```bash
swift build -c release
claude mcp add delegate -s user -- "$(swift build -c release --show-bin-path)/delegate-mcp"
```

Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`,
**absolutna** ścieżka do binarki:

```json
{
  "mcpServers": {
    "delegate": { "command": "/ABSOLUTNA/ŚCIEŻKA/delegate-mcp" }
  }
}
```

Flagi CLI: `--init`, `--print-config-path`, `--version`. W trybie serwera nic nie wolno
drukować na stdout (należy do protokołu), logi idą na stderr.

## Pierwsze kroki po instalacji

ID modeli zmieniają się często. Poproś Claude'a: *„użyj list_remote_models dla każdego
dostawcy i zaktualizuj delegate.toml”*.

## Żeby Claude faktycznie delegował

Zasady routingu są w `routing_guidance` w `delegate.toml`, a Claude czyta je przez
`list_models`. Dodatkowo dopisz do `~/.claude/CLAUDE.md`:

```markdown
## Delegowanie
Masz serwer MCP `delegate`. Przy zadaniach samowystarczalnych (masowe generowanie,
tłumaczenia, pierwsze drafty, streszczenia wklejonego tekstu, druga opinia o fragmencie kodu)
najpierw wywołaj `list_models`, potem `delegate` zgodnie z routing_guidance.
Wynik zawsze zweryfikuj. Nie wysyłaj danych z pracy, sekretów ani danych osobowych.
```

## Ważne

- **Mistral za darmo** działa tylko z kluczem na planie *Experiment* w Mistral Studio. Subskrypcja Pro (Vibe) nie daje kredytów API.
- Darmowe plany (Mistral Experiment, Gemini free tier) zwykle pozwalają dostawcy używać przesłanych danych. Sprawdź regulaminy, zanim wyślesz coś prywatnego.
- DeepSeek przetwarza dane w Chinach. Niczego z pracy tam nie wysyłaj.
- Delegowany model widzi **tylko** prompt: nie ma dostępu do plików, repo ani narzędzi.
- TOMLKit nie dekoduje liczby całkowitej jako `Double`; pola liczbowe w configu dekodujemy ostrożnie (patrz `Config.init(from:)`).

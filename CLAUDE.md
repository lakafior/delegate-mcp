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
| `delegate` | Wysyła zadanie: `model` (`provider/model`), `task` (tag) albo automatycznie wg priorytetu; opcjonalnie `system`, `temperature`, `max_tokens`, `fallback=false`, `sensitivity` (`public`/`personal`/`private`), `files` (ścieżki plików tekstowych, które serwer czyta sam), `output_file` (serwer zapisuje odpowiedź na dysk, Claude dostaje podgląd), `check` (kryterium akceptacji, niżej), `background` (od razu zwraca ID zadania) |
| `delegate_result` | Status i wyniki zadań w tle (`ids`, `wait` do 40 s); zadania żyją w pamięci procesu serwera, czyli tyle co sesja. Claude zrywa wywołanie narzędzia po ok. 60 s (i restartuje serwer), więc `delegate` bez `background` startuje zadanie w tle i czeka na nie do 50 s (`DelegateRequest.syncDeadlineSeconds`, `DelegateJobs.state(of:waiting:)`): szybkie wraca w tej samej turze, wolniejsze zostaje zadaniem z ID (R1: każda dodatkowa tura dyrygenta kosztuje) |
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
sprawdzania widoków: `--settings` otwiera okno przy starcie, `--select=overview|routing|agents|agent:<id>|jobs|usage|settings|<id dostawcy>`
wybiera panel. `DELEGATE_HOME=/tmp/x` odcina od prawdziwego configu.

Binarki z `swift build` mają podpis ad-hoc, którego ACL wpisów w Keychain nie zna, więc odczyt klucza
pyta o hasło (przy każdym przebudowaniu od nowa). `./scripts/dev-sign.sh` buduje i podpisuje je tą samą
tożsamością i identyfikatorami co `Delegate.app` (uruchom ponownie po każdym `swift build`). Statusy kluczy
sprawdzamy przez `hasSecret` (same atrybuty), który nigdy nie pyta o hasło.

## Instalacja i dystrybucja

Ikona: `Assets/AppIcon.icon` (Icon Composer), kompilowana przez `actool` w `build-app.sh`.

- **Na własnym Macu:** `SIGN_ID="Apple Development: …" ./scripts/install.sh` buduje, podpisuje i kopiuje do
  `/Applications`. Stabilny podpis zespołu (zamiast ad-hoc) sprawia, że zgoda „Zawsze zezwalaj” na
  Keychain przeżywa przebudowania. Tożsamości: `security find-identity -v -p codesigning`.
- **Dla innych ludzi:** podpis „Developer ID Application” → `./scripts/build-app.sh` →
  `./scripts/notarize.sh` (profil `notarytool store-credentials`) → `./scripts/make-dmg.sh` → `./scripts/notarize.sh dist/Delegate.dmg`.
- **Wydanie na GitHubie** (`.github/workflows/release.yml`): podbij `let version` w `Sources/delegate-mcp/main.swift`
  (jedyne źródło wersji; `build-app.sh` wpisuje ją do Info.plist, numer kompilacji = liczba commitów), commit,
  `git tag v<wersja> && git push origin v<wersja>`. Workflow sprawdza zgodność taga z wersją, puszcza testy, podpisuje,
  notaryzuje apkę i DMG i publikuje release z `Delegate-<wersja>.dmg` + `.sha256`. Sekrety repo:
  `DEVELOPER_ID_P12_BASE64` / `DEVELOPER_ID_P12_PASSWORD` (certyfikat „Developer ID Application” z kluczem, `base64 -i cert.p12`),
  `NOTARY_KEY_P8_BASE64` / `NOTARY_KEY_ID` / `NOTARY_ISSUER_ID` (klucz API App Store Connect, rola Developer).
  `notarize.sh` w CI używa klucza API (`NOTARY_KEY_PATH`), lokalnie profilu z Keychain.

## Pomiar oszczędności: `eval/`

`eval/run.py` (Python, tylko narzędzie deweloperskie) puszcza zadania z `eval/tasks/` przez `claude -p` z serwerem
`delegate` i bez, liczy koszt dyrygenta z `modelUsage`, uruchamia `check.py` i sędziego. Opis: `eval/README.md`.
Wyniki w `eval/results/` (poza gitem), katalogi robocze w `/tmp/delegate-eval` (poza repo, żeby ten `CLAUDE.md`
nie wchodził do każdego przebiegu). Wymaga zalogowanego CLI (`claude auth login`).

## Strona: delegate.smigi.net

`website/`: czysty HTML + `style.css`, bez frameworka i kroku budowania, jak strony Kickon/Dutch/WorldWard; tylko po
angielsku. Worker Cloudflare ze statycznymi plikami (`website/wrangler.jsonc`, `assets.directory = "."`, domena przez
route `delegate.smigi.net/*` na proxowanym rekordzie `AAAA 100::`; nie custom domain, bo jej osobny certyfikat
z `smigi.net` daje w Safari 421 Misdirected Request przy współdzielonym połączeniu). Okno macOS (światła, minimalizacja do docka smigi.net) daje `https://smigi.net/os/chrome.js`
z `data-app="delegate"`; lokalnie się nie ładuje. Zrzuty to kopie `docs/screenshots/`. Podgląd: `.claude/launch.json`
(`wrangler dev`, port 8787). Wdrożenie: push na `main` ze zmianą w `website/` → `.github/workflows/website.yml`
(sekrety `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`); ręcznie `cd website && wrangler deploy`.
`compatibility_date` nie może być nowsza niż obsługuje lokalny wrangler.

## Pliki użytkownika

Katalog: `~/Library/Application Support/Delegate/` (nadpisywany przez `$DELEGATE_HOME`).

- `delegate.toml` — config. Tworzony z domyślnego, jeśli go brak (`delegate-mcp --init`). Domyślny ma tylko
  model na urządzeniu; chmurowych dostawców dodaje się z presetów (`ProviderPreset`, menu + w aplikacji). Darmowe bez
  karty: Mistral (Experiment), Gemini, Groq, NVIDIA NIM, SambaNova (20 zapytań dziennie na model), Cloudflare Workers AI
  (w adresie `ACCOUNT_ID` do podmiany, brak `/models`).
  Wczytywany przy każdym wywołaniu, więc restart nie jest potrzebny.
- `.env` — awaryjne klucze (`MISTRAL_API_KEY=...`), `chmod 600`.
- `delegate_usage.jsonl` — log użycia (tylko metadane, bez treści promptów).
- `model_cooldowns.json` — przerwy dla modeli po błędach (`ModelCooldowns`), wspólne dla wszystkich sesji.
- `price_catalog.json` — kopia cennika LiteLLM: odświeżana co tydzień, wcześniej (najwyżej raz na dobę), gdy brakuje
  ceny modelu czatowego, oraz ręcznie (Ogólne → Cennik LiteLLM, „Uzupełnij z API” przy dostawcy). `modelInfos` uzupełnia z niego ceny,
  których API dostawcy nie podaje (Mistral, Gemini, DeepSeek, Anthropic, OpenAI…); dopasowanie po hoście `base_url`.

Preset „Gateway (OmniRoute / LiteLLM)” (`asksRegion`): apka przy dodaniu pyta, dokąd gateway wysyła dane, i zapisuje
`privacy`; bez wyboru i tak `other` (R0).

Klucze: zmienna środowiska → `.env` → Keychain (service `com.mar.delegate`, account =
`api_key_env` z configu). Dostawca bez klucza jest pomijany, nic się nie psuje. Zmiana nazwy dostawcy
lub `api_key_env` w aplikacji przenosi wpis w Keychain; usunięcie dostawcy usuwa jego klucz.

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

Flagi CLI: `--init`, `--print-config-path`, `--version`, `doctor` (diagnostyka w terminalu),
`--check-keys` (JSON: czy ta binarka odczyta klucze bez okna z hasłem; interakcję z Keychain wyłącza, więc
nigdy nie pyta). Diagnostyka (`DelegateDoctor` + `HelperProbe`) testuje binarkę zarejestrowaną w Claude:
handshake MCP, instrukcje i `--check-keys`. W trybie serwera nic nie wolno
drukować na stdout (należy do protokołu), logi idą na stderr.

## Pierwsze kroki po instalacji

ID modeli zmieniają się często. Poproś Claude'a: *„użyj list_remote_models dla każdego
dostawcy i zaktualizuj delegate.toml”*.

## Żeby Claude faktycznie delegował

Główny mechanizm to **instrukcje serwera MCP** (`DelegationGuide.serverInstructions`): serwer podaje je
przy `initialize`, a Claude Code i Claude Desktop wstrzykują je do każdej sesji. Są generowane z configu
przy starcie serwera: kiedy delegować (wyjście powyżej ~300 linii w trybie `balanced` albo duże wejście, jedna runda:
`files`, `output_file`, jeden `git diff`; próg z pomiaru R1, `eval/`), katalog po jednej linii na dostawcę
(region, koszt, do 5 modeli z tagami, wskazówka) i `routing_guidance`. Model wybiera Claude; kolejność
dostawców to tylko domyślna trasa i fallback (najpierw modele o wspólnych tagach). Instrukcje i opisy narzędzi
idą w każdym zapytaniu, więc są krótkie (test `instructionsStayCompact`). Claude Code chowa narzędzia MCP za
ToolSearch (dodatkowa tura dyrygenta); `delegate` i `delegate_result` mają `_meta["anthropic/alwaysLoad"] = true`,
więc są zawsze w prompcie, reszta zostaje odłożona. `doctor` pokazuje, ile narzędzi tak oznaczono. Teksty dla Claude'a są po angielsku.

Aplikacja (Ogólne → Claude) może dodatkowo dopisać do `~/.claude/CLAUDE.md` krótki blok
(`ClaudeIntegration.instructions`), który tylko wzmacnia nawyk; starszy blok podmienia przyciskiem „Zaktualizuj”.
Subagenta `grunt` aplikacja już nie instaluje (nie korzystał z `delegate`); istniejący plik zostaje nietknięty.

## Routing: prywatność, budżet, tryb

`DelegateService.routingPlan` buduje kolejność prób i listę pominiętych z powodami (używa go `delegate`
i podgląd w zakładce Routing):
- **Region danych** dostawcy (`privacy` w `[[provider]]`: `local`/`eu`/`us`/`cn`/`other`, domyślnie wnioskowany
  z hosta, `PrivacyRegion.inferred`; localhost jest `local` tylko na portach Ollamy 11434 i LM Studio 1234, inaczej
  `other`, bo gateway na localhost wysyła dane do chmury; presety Ollama/LM Studio zapisują `privacy = "local"` jawnie). Zadanie `sensitivity = personal` trafia tylko do `personal_regions`
  (domyślnie local, eu, us), `private` tylko do lokalnych. Nieznana wartość `sensitivity` = `personal`.
- **Dzienny budżet** (`daily_budget_usd`): po wydaniu limitu (suma `cost_usd` z dzisiejszego logu) płatne modele
  odpadają; nieznana cena liczy się jako płatna, lokalne i `free` zawsze przechodzą.
- **Przerwy** (`ModelCooldowns`): model, który odmówił, jest pomijany przez jakiś czas, zamiast zjadać limit czasu:
  429 z `limit: 0` → doba, 429 z „retry in …” → tyle, ile podał dostawca, inny 429 → 60 s, 402 → godzina,
  503/502/504/529 i timeout (gdy model miał pełny limit albo co najmniej 25 s) → 5 min, 500 → 2 min, 404 i 400 „only supports…”
  → tydzień. Sukces zdejmuje przerwę; w Routingu przycisk „Resume paused models” zdejmuje wszystkie.
  Z wyprzedzeniem (`RateLimit`): po udanej odpowiedzi API zgodnego z OpenAI nagłówki `x-ratelimit-remaining-*` /
  `x-ratelimit-reset-*` (Groq, SambaNova…) dają przerwę do odnowienia, gdy licznik spadł do zera albo tokenów zostało
  mniej, niż zużyło to zapytanie; model odpada przed odmową. Przy 429 nagłówek `retry-after` ustala długość przerwy.
  Odrzucony klucz (401, 403, 402 „authentication”) nie daje przerwy, ale pozostałe modele tego dostawcy odpadają w tym
  wywołaniu (`DelegateService.isKeyRejected`), a błąd mówi, czyje klucze sprawdzić.
- **Myślenie Gemini** (`ProviderClient.geminiThinking`): Flash i Pro 3+ (także `-latest`) dostają `thinkingLevel: low`,
  bo ich domyślne `medium`/`high` to minuty na zwykłe zadanie; Flash-Lite (domyślnie `minimal`), 1.x/2.x i Gemma nic.
  Nadpisanie per model: `thinking = "high"` w `[[provider.model]]`, `"default"` = nic nie wysyłać. Odrzucony poziom
  (400 o „thinking”) → jedno ponowienie bez niego. `thoughtsTokenCount` liczy się do tokenów wyjścia.
- **Odmowy z instrukcją**: gdy nikt nie zostanie, błąd ma „What to do:” z `RoutingPlan.refusalAdvice` (po linii na
  rodzaj wykluczenia, `RoutingExclusion.Kind`: region, budżet, przerwa, brak klucza; przy `fallback = false` tylko powody
  wskazanego modelu), na końcu „do the task yourself”. „All attempts failed” też kończy się wskazówką.
- **Tryb** (`delegation_mode`: `conservative`/`balanced`/`aggressive`) zmienia ton i próg słów w instrukcjach serwera.

## Agenci ACP (w budowie)

Plan i stan: `docs/acp-plan.md`. Gotowe agenty z rejestru ACP (jak w Zedzie) wykonują analizy repo w tle:
`delegate_agent` (widoczne tylko, gdy jakiś agent jest zainstalowany) → `AgentRunner`: kopia repo
(`RepoSnapshot`, HEAD + niezacommitowane zmiany śledzonych plików), `sandbox-exec` (`AgentSandbox`, zapis tylko do
stanu agenta i `tmp` zadania, oryginalne repo i klucze niewidoczne), tryb tylko do odczytu (w piaskownicy zgoda na
polecenia, odmowa dla edycji, usuwania i przenoszenia plików). Wynik przez `delegate_result`; zadania w tle zapisywane w `jobs/<id>.json` (`JobStore`), więc przeżywają
restart serwera; z `details` (agent, model, repo, tryb, gałąź) czyta je zakładka Jobs w apce (`JobsView`, `JobStore.all`). Instalacja: `agents/<id>/<wersja>/` + `agents/installed.json` (`AgentInstaller`: binarki z SHA-256 z rejestru
albo z podpisem Developer ID (`CodeSignature`), niepodpisane tylko za zgodą (`UnverifiedAgentError`, `--allow-unverified`); paczki npm instalowane raz przez systemowy Node, `NodeRuntime`, `npm install --prefix --ignore-scripts`,
uruchamiane `node <skrypt>` bez npx), z terminala `delegate-mcp --install-agent <id>` / `--agents`. W apce: zainstalowani agenci w pasku bocznym ze stronami
(`AgentDetailView`), rejestr pod „Browse agents” (`AgentsView`), sekcja Agents w Overview; stan logowania (`AgentAccount.check`: próbna sesja w pustym katalogu) i logowanie
(`agent` → ACP `authenticate`, agent otwiera przeglądarkę; `terminal` → plik `.command` w Terminalu).
Ustawienia agenta w `delegate.toml` (`[[agent]] id/model/effort/enabled/privacy/guidance`, `AgentSettings`, strona agenta):
domyślny model i wysiłek (gdy dyrygent ich nie poda), wyłączenie (agent znika z `delegate_agent`), region zamiast
tabeli `AgentRegions`. **Priorytet:** kolejność `[[agent]]` (`Config.prioritizedAgents`, przeciąganie w pasku
bocznym, `reorderAgents`); wpis bez ustawień zostaje jako samo `id`, bo trzyma miejsce. Instrukcje serwera, opis
`delegate_agent` i `list_models` wymieniają agentów w tej kolejności z `guidance`. Pole `agent` jest opcjonalne: bez
niego `AgentChoice.pick` bierze pierwszego dozwolonego (reguła repo, wrażliwość, zalogowanie; agenta dyrygenta tylko
z ustawionym tańszym modelem), a odpowiedź mówi, kogo pominął.
**Przerwy i zawieszenia agentów:** watchdog w `AgentRunner.run` kończy zadanie po ciszy (brak `session/update` i próśb
o zgodę; `idleLimit`: 180 s odczyt, 360 s zapis) zamiast czekać 600 s. `AgentPause` (we wspólnym `model_cooldowns.json`,
klucz `agent:<id>`): brak logowania → tydzień (zdejmuje udane sprawdzenie w apce), limit planu → do resetu albo godzina,
drugi z rzędu limit czasu/zawieszenie → godzina; sukces zdejmuje przerwę. Wstrzymany agent odpada z automatycznego
wyboru; przy wyborze automatycznym błąd na starcie (logowanie, limit) bez gałęzi z pracą przechodzi na następnego
agenta. `list_models` pokazuje przerwy i statystyki z logu (30 dni: zadania, udane, mediana czasu); w opisie narzędzia
ich nie ma (cache promptu). Reguły repo `[[repo]] path/agents` (`RepoRule`, sekcja w Routingu): najdłuższa pasująca ścieżka,
pusta lista = żaden agent; sprawdzane w `AgentRegions.refusal` razem z wrażliwością. Lista agentów liczona przy każdym
wywołaniu, serwer wysyła `tools/list_changed` po zmianie (co 30 s). `list_models` opisuje agentów z
`agents/checks.json` (`AgentCheckCache`, zapisuje apka). Tryb sesji: pierwszy dostępny z `plan`, `ask`.
**Tryb zapisu** (`delegate_agent` z `mode = "write"`): worktree na nowej gałęzi `delegate/<agent>-<zadanie>-<id>`
od `HEAD` (niezacommitowane zmiany użytkownika do niej nie wchodzą, raport to zaznacza). W piaskownicy zapis do
worktree, `.git/objects`, `refs/heads/delegate/*`, metadanych worktree, cache narzędzi (`buildDirectories`: SwiftPM, npm,
`~/.cache`…) i katalogów tymczasowych użytkownika; hooki, config i inne gałęzie tylko do odczytu. Zgody: wszystko tak
(tylko w piaskownicy), tryb sesji `acceptEdits`/`accept-edits`. Agent nie commituje; po zadaniu `finishBranch`
commituje jako „Delegate (<agent>)”, zwraca `--stat` i polecenia review/merge/discard; pusta gałąź jest usuwana.
SwiftPM w piaskownicy wymaga `--disable-sandbox` (mówi to polecenie dla agenta). Polecenie (`writePrompt`) każe też
robić najmniejszą zmianę, bez nowych abstrakcji, zależności i refaktoryzacji obok (jak Ponytail w teście marmelab:
mniej rund poprawek i mniejszy diff do przejrzenia); niezmierzone u nas.
**Kontekst po referencji** (`context_jobs`, `context_files`, `AgentContext`): wyniki zakończonych zadań (z
`report_file`/`output_file` cały plik, nie podgląd) i pliki tekstowe serwer kopiuje do `.delegate-context/` w kopii
repo, a przed zadaniem dopisuje, gdzie leżą; dyrygent nie przepisuje raportu do briefu. W trybie zapisu katalog jest
usuwany przed commitem. Zadanie dziedziczy najostrzejszą `sensitivity` źródłowych zadań (zapisaną w `Details`;
starsze zadania bez niej liczą się jak `personal`). Limit równoległych agentów:
`max_parallel_agents` (domyślnie 3, `AgentSlots`). `branch_from` (tylko zapis): runda poprawek startuje z gałęzi
poprzedniego agenta zamiast z `HEAD`.
**`check` (model seniora z juniorami):** `delegate` (z `output_file`) i `delegate_agent` w trybie zapisu przyjmują polecenie
akceptacji (testy, build, walidator). `CheckRunner` uruchamia je w piaskownicy (`AgentSandbox` z `network`/`keychain`:
zapis tylko do katalogu zadania, tmp i cache narzędzi; bez Keychain; sieć tylko dla agenta) z limitem 300 s. Nie przejdzie →
do `DelegateRequest.maxFixRounds` (2) rund poprawek: `delegate` wysyła błąd i bieżący plik temu samemu modelowi
(`modelRef` z nagłówka), agent dostaje `fixPrompt` w tej samej sesji (watchdog ciszy śpi w czasie polecenia). Dyrygent
dostaje jedną linię (`CheckResult.line`) zamiast podglądu, a z agentem krótki raport: wynik, `--stat`, ~600 znaków
podsumowania. R1 pokazał, że koszt robiły nie tanie modele, tylko dyrygent sprawdzający wynik własnymi skryptami.
**Skill `/swarm`** (`SwarmSkill`): procedura dyrygenta dla Claude Code w `~/.claude/skills/swarm/SKILL.md`, instalowana
z Overview (rozpoznawana po znaczniku `<!-- delegate-mcp swarm skill -->`; cudzego skilla o tej nazwie nie nadpisujemy).
Inni klienci MCP (sekcja „Other assistants” w Overview): `MCPClients.swift` (`MCPClient`, `MCPClientConfig`: Cursor
`~/.cursor/mcp.json`, VS Code `…/Code/User/mcp.json` z `servers` + `type: stdio`, Gemini CLI `~/.gemini/settings.json`,
Antigravity `~/.gemini/config/mcp_config.json`, Zed `context_servers` — plik z komentarzami trzeba edytować ręcznie)
i `CodexMCPConfig.swift` (tekstowa podmiana tabeli `[mcp_servers.delegate]` w `~/.codex/config.toml`).
Dyrygent: serwer zapamiętuje `clientInfo.name` z `initialize` (`initializeHook`); `AssistantClient` wskazuje agenta na tej
samej subskrypcji (Claude Code → `claude-acp`, Codex → `codex-acp`…), a opis `delegate_agent` i `list_models` dopisują,
że ma sens tylko z tańszym modelem. Instrukcje serwera są stałe (powstają przed `initialize`), więc tam tego nie ma.
Testy na atrapie agenta (Python) w `ACPTests.swift` i `AgentRunTests.swift`.

## Ważne

- **Mistral za darmo** działa tylko z kluczem na planie *Experiment* w Mistral Studio. Subskrypcja Pro (Vibe) nie daje kredytów API.
- Darmowe plany (Mistral Experiment, Gemini free tier) zwykle pozwalają dostawcy używać przesłanych danych. Sprawdź regulaminy, zanim wyślesz coś prywatnego.
- DeepSeek przetwarza dane w Chinach. Niczego z pracy tam nie wysyłaj.
- Delegowany model widzi **tylko** prompt: nie ma dostępu do plików, repo ani narzędzi.
- TOMLKit nie dekoduje liczby całkowitej jako `Double`; pola liczbowe w configu dekodujemy ostrożnie (patrz `Config.init(from:)`).

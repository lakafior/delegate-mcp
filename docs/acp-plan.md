# Plan: agenci ACP jako wykonawcy `delegate`

Status: propozycja, nic nie jest zaimplementowane. Fakty o protokole i agentach sprawdzone 2026-10-27
(specyfikacja ACP v1, rejestr `agentclientprotocol/registry`, handshake z `vibe-acp` 3.0.1).

## Cel

Claude zleca zadanie na repo („gdzie używana jest funkcja X i co trzeba zmienić”), a gotowy agent
(Mistral Vibe, później Gemini CLI i inni z rejestru) wykonuje je w tle w osobnej kopii repo i oddaje raport.
Apka zostaje centrum sterowania: instaluje agentów, loguje, pilnuje regionów danych i budżetu.

**MVP:** tylko agenci z dystrybucją `binary` (bez Node/uv), tylko tryb **tylko do odczytu** (raport, zero zmian),
zawsze w tle, jeden agent na start: Mistral Vibe.

## Co wiemy o ACP (ważne dla projektu)

- JSON-RPC 2.0 po stdio, agent to podproces klienta. Przebieg: `initialize` → (`authenticate`) →
  `session/new {cwd}` → `session/prompt` → strumień `session/update` → odpowiedź z `stopReason`; `session/cancel` przerywa.
- Klient deklaruje możliwości (`fs.readTextFile`, `fs.writeTextFile`, `terminal`). Agent **może**, ale nie musi
  prosić o zgodę (`session/request_permission`) i może czytać/pisać pliki własnymi narzędziami. **Protokół nie
  gwarantuje tylko-do-odczytu** — gwarancję daje dopiero piaskownica systemowa (niżej).
- Logowanie w rejestrze: `agent` (agent sam robi OAuth: lokalny serwer + przeglądarka, sam trzyma tokeny) albo
  `terminal` (klient uruchamia agenta z dodatkowymi `args`, np. `--setup`, w terminalu).
- Vibe 3.0.1 (sprawdzone): `authMethods = [browser-auth: "Sign in through Mistral AI Studio"]`; tryby sesji
  `ask` / `accept-edits` (domyślny) / `smart-approve` / `auto-approve`; `configOptions` z modelem (GLM-5.3,
  GLM-5.3 Flash, Mistral Medium 3.5) i poziomem myślenia; wysyła `usage_update` z tokenami; ładuje skille
  z katalogu domowego użytkownika; zgłasza `workspace_trust: untrusted`.
- Rejestr: `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json`, wpis = `id`, `name`, `version`,
  `distribution` z `binary` (archiwum per platforma + `sha256` + `cmd`), `npx` albo `uvx`. Wersje aktualizowane co godzinę.

## Wynik etapu 0 (2026-10-27)

Vibe 3.0.1 w `sandbox-exec` na snapshocie repo (`git worktree --detach`), sesja w trybie `ask`, klient odrzucał
każdą prośbę o zgodę. Zadanie: analiza, co zmienić, żeby zadania w tle przetrwały restart serwera.

- **Jakość:** raport trafny i konkretny; wszystkie sprawdzone cytaty `plik:linia` zgodne z kodem. Wyraźnie lepszy
  niż jednorazowa recenzja z `mistral-code-latest` przez `delegate`.
- **Czas i zużycie:** 17,5 s, 4 kroki, 117 tys. tokenów wejścia (90 tys. z cache), 2,3 tys. wyjścia; Vibe podał
  koszt $0,07. Konto Vibe jest na planie czatu (`plan_type: chat`), więc to najpewniej liczy się do subskrypcji,
  a kwota jest orientacyjna — do potwierdzenia w panelu Mistrala.
- **Uprawnienia:** mimo trybu `ask` Vibe **uruchomił 6 poleceń bash bez pytania** (`grep`, `cat`, `sed` — uznał je
  za bezpieczne). O zgodę zapytał tylko przy zapisie pliku (odrzucone, plik nie powstał). Wniosek: tryb sesji
  i prośby o zgodę nie wystarczą; piaskownica jest obowiązkowa.
- **Piaskownica** (sprawdzona osobno shellem w tym samym profilu): zapis do snapshotu, prawdziwego repo i `~`
  zablokowany; odczyt `~/.ssh` i katalogu `Delegate` zablokowany; odczyt snapshotu i zapis do katalogu
  tymczasowego zadania działa. Vibe pracował normalnie z zapisem tylko do `~/.vibe` i `$TMPDIR` zadania.
- **Do poprawy w implementacji:** agent dostaje polecenia bash, więc piaskownica musi też objąć jego procesy
  potomne (`sandbox-exec` to robi, bo dziedziczą profil) i warto zablokować zapis do `/tmp` poza katalogiem zadania.

Decyzja: kierunek potwierdzony, można zaczynać etap 1.

## Stan etapu 1

Zrobione w `DelegateCore` (bez zmian w serwerze MCP i apce):
- `JSONValue` — wartość JSON `Sendable` dla komunikatów ACP.
- `ACPConnection` — podproces + JSON-RPC po stdio: żądania z limitem czasu, powiadomienia po kolei, żądania od
  agenta przez `onRequest`, śmierć agenta kończy oczekujące żądania błędem; `initialize` (domyślnie bez `fs`
  i `terminal`) i `newSession` (`RemoteError.isAuthRequired` przy braku logowania).
- `ACPRegistry` + `ACPRegistryStore` — model indeksu (sprawdzony na prawdziwym: 43 agentów, wszystkie pola
  wymagane obecne), cache `agents/registry.json` na dobę. `installKind`: `binary` / `needsRuntime(Node.js|uv)` / `unavailable`.
- `AgentInstaller` — pobranie, SHA-256 (bez sumy nie instaluje: dotyczy 8 z 20 agentów binarnych na Maca),
  rozpakowanie `tar.*`/`zip` albo goły plik wykonywalny, ochrona przed `..`, ścieżkami absolutnymi
  i linkami poza katalog, wersja obok wersji z przełączeniem po weryfikacji, `installed.json`.
- Testy (`ACPTests.swift`) na atrapie agenta w Pythonie: handshake, sesja, prompt z prośbą o zgodę, brak
  logowania, śmierć agenta, timeout; rejestr i cache; instalacja, aktualizacja, odinstalowanie, złe sumy
  i ścieżki. Opcjonalny test na prawdziwym agencie: `DELEGATE_REAL_ACP_AGENT=/ścieżka swift test --filter realAgent`.

## Stan etapu 2

- `RepoSnapshot` (`AgentWorkspace.swift`) — `git stash create` + `git worktree add --detach` w
  `~/Library/Caches/com.mar.delegate/agent-jobs/<id>/repo`; usuwany po zadaniu.
- `AgentSandbox` — profil `sandbox-exec`: zapis zabroniony w `~`, `/Volumes`, `/private/tmp`, `/private/var/folders`;
  dozwolony w katalogach stanu agenta (`stateDirectories`, np. `~/.vibe`) i `tmp` zadania; kopia repo tylko do odczytu;
  niewidoczne: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.docker`, `~/.kube`, `~/.config/gh`, `.git-credentials`,
  `.npmrc`, `.pypirc`, nasz `.env` i **oryginalne repo** (więc nieśledzone pliki typu `.env` w projekcie są poza zasięgiem).
- `AgentRunner` (`AgentRun.swift`) — snapshot → piaskownica → `initialize` → `session/new` (brak logowania = czytelny
  błąd) → tryb `ask` → opcjonalny model (zła nazwa = lista poprawnych) → prompt z zasadami tylko do odczytu →
  raport (`AgentReport.formatted`): tekst, kroki, odrzucone prośby, tokeny z `usage_update`.
  Polityka: w piaskownicy zgoda na odczyty i polecenia (zapisu i tak nie zrobią), odmowa dla `edit`/`delete`/`move`
  i nieznanego rodzaju; bez piaskownicy odmowa wszystkiego; `fs/*` i `terminal/*` nieogłaszane. Katalog zadania
  w Caches znika po sukcesie, po błędzie zostaje (`agent.log`, `sandbox.sb`).
- Test na żywo przez serwer MCP: `delegate_agent` → Vibe (GLM-5.3) → raport po 30 s, 9 kroków, 122 tys. tokenów
  wejścia; sprawdzone cytaty `plik:linia` trafne (jeden przesunięty o linię). Pierwsza wersja polityki odrzuciła
  Vibe zwykłe `sed`/`grep`, stąd zmiana powyżej.
- `AgentRegions` — region danych agenta z wbudowanej tabeli (Vibe `eu`); `private` nigdy, `personal` tylko do `personal_regions`.
- `DelegateJobs` + `JobStore` — zadania w tle zapisywane w `Delegate/jobs/<id>.json` (losowe ID, PID właściciela);
  po restarcie serwera `delegate_result` czyta wynik z dysku, a zadanie martwego procesu zgłasza jako przerwane;
  pliki starsze niż 7 dni sprzątane przy starcie.
- Serwer: narzędzie `delegate_agent` (tylko gdy jest zainstalowany agent) i jedna linia w instrukcjach;
  flagi `--agents`, `--install-agent <id>`. Użycie agentów w `delegate_usage.jsonl` jako `agent:<id>`, bez kosztu
  (subskrypcja nie liczy się do dziennego budżetu).

## Stan etapu 3

- `ACPConnection.authenticate`, `AuthMethod.env`; `AgentAccount` (`check`: `initialize` + `session/new` w pustym
  katalogu → zalogowany / wymaga logowania / błąd, plus modele z sesji; `signIn` dla typu `agent`; `.command`
  w Terminalu dla typu `terminal`).
- Apka: zakładka Agents w pasku bocznym (`--select=agents`): zainstalowani (kropka stanu, wersja, region, modele,
  Zaloguj / Aktualizuj / menu: sprawdź, zaloguj ponownie, usuń), dostępni z rejestru z wyszukiwarką; agenci bez
  sumy SHA-256 albo wymagający Node/uv pokazani z powodem zamiast przycisku.
- Nie zrobione: ustawienia per agent (region, domyślny model, włączony) w `delegate.toml` — region dalej z tabeli
  `AgentRegions`, model wybiera Claude parametrem `model`. Do zrobienia, jeśli okaże się potrzebne.

## Podział ról

| Kto | Co |
|---|---|
| Apka (`Sources/Delegate`) | lista agentów z rejestru, instalacja/aktualizacja/usuwanie, logowanie, ustawienia per agent (model, region, włączony) |
| `DelegateCore` | rejestr, instalator, połączenie ACP, polityka uprawnień, piaskownica, kopia repo, zapis wyników |
| Serwer MCP (`delegate-mcp`) | narzędzie `delegate_agent`, uruchamianie w tle, `delegate_result` |

Agentów uruchamia serwer MCP (proces sesji Claude'a); logowanie robi apka. Tokeny trzyma sam agent
(np. Vibe w swoim katalogu), my ich nie widzimy ani nie zapisujemy.

## Komponenty w `DelegateCore`

1. **`ACPRegistry`** — pobiera `registry.json`, cache w `Delegate/agents/registry.json` (jak cennik LiteLLM:
   odświeżanie najwyżej raz na dobę + ręcznie). Filtruje do `darwin-aarch64`/`darwin-x86_64`; w MVP pokazuje
   wpisy `npx`/`uvx` jako „wymaga Node/uv, wkrótce”.
2. **`AgentInstaller`** — `URLSession` pobiera archiwum, `CryptoKit.SHA256` weryfikuje sumę, `/usr/bin/tar`
   (albo `ditto` dla zip) rozpakowuje do `Delegate/agents/<id>/<version>/`. Nowa wersja trafia obok starej,
   przełączenie po weryfikacji, stara usuwana. `installed.json` zapamiętuje id, wersję, ścieżkę `cmd`.
   Nic nie trafia do `PATH`, usunięcie agenta = usunięcie katalogu.
3. **`ACPConnection`** (actor) — `Process` + pipe'y, ramki JSON-RPC po liniach, korelacja `id` → continuation,
   obsługa żądań od agenta (`session/request_permission`, ewentualnie `fs/*`) i powiadomień. Logi agenta ze
   stderr do pliku zadania, nigdy na stdout serwera (należy do MCP). Wzorzec jak w `HelperProbe` (handshake MCP).
4. **`AgentPolicy`** — odpowiedzi klienta: w trybie tylko-do-odczytu `fs.writeTextFile = false`, `terminal = false`,
   każda prośba o zgodę na zapis/wykonanie → `reject_once`; sesja w trybie `ask`, jeśli agent go ma.
5. **`AgentSandbox`** — prawdziwa gwarancja: agent startuje przez `sandbox-exec` z profilem generowanym per
   zadanie: zapis zabroniony wszędzie poza katalogiem stanu agenta (jego tokeny, cache), `$TMPDIR` zadania
   i katalogiem wyników; odczyt zabroniony w `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/Library/Keychains`,
   katalogu `Delegate` (`.env`!) i innych wrażliwych; sieć dozwolona (model jest w chmurze).
   `sandbox-exec` jest oficjalnie przestarzały, ale działa i korzysta z niego m.in. Claude Code — ryzyko opisane niżej.
6. **`RepoSnapshot`** — kopia repo dla agenta: `git stash create` (commit z niezacommitowanymi zmianami
   śledzonych plików, bez ruszania working tree) → `git worktree add --detach <cache>/worktrees/<job> <commit>`.
   Agent widzi więc też Twoje niezacommitowane zmiany. Pliki nieśledzone nie wchodzą (do decyzji: można je
   skopiować). Po zadaniu `git worktree remove --force` + `git worktree prune`.
7. **`AgentRun`** — składa całość: snapshot → sandbox → `initialize` → sprawdzenie logowania → `session/new` →
   ustawienie trybu i modelu → `session/prompt` z zadaniem i regułami („tylko analiza, nie zmieniaj plików,
   odpowiedz raportem w formacie …”) → zbiera `agent_message_chunk` (raport), listę wywołań narzędzi
   (co czytał) i `usage_update` (tokeny do `delegate_usage.jsonl`) → limit czasu (domyślnie 10 min) z `session/cancel`.

## Narzędzie dla Claude'a

Nowe narzędzie `delegate_agent` (osobne, żeby nie komplikować schematu `delegate`):

- `agent` (id z listy zainstalowanych i zalogowanych), `repo` (ścieżka absolutna), `task`,
  opcjonalnie `model` (wartość z `configOptions` agenta), `sensitivity`, `report_file` (raport od razu na dysk, jak `output_file`).
- Zawsze w tle: zwraca ID zadania, wynik przez istniejące `delegate_result`.
- Region danych agenta jak u dostawców (Vibe: `eu`, Gemini: `us`); `sensitivity = personal` tylko do
  `personal_regions`, `private` nigdy do agenta chmurowego. Agent wysyła do dostawcy wszystko, co przeczyta w repo.
- Wynik: raport, lista przeczytanych plików, tokeny, czas, ewentualne odrzucone próby zapisu.
- **Trwałość zadań:** stan i wynik zadań agentów zapisywane w `Delegate/jobs/<id>.json`, bo serwer bywa
  restartowany przez klienta, a zadanie trwa minuty. `delegate_result` czyta też stamtąd.
- Instrukcje serwera: krótka sekcja tylko wtedy, gdy jest gotowy agent: „do przeszukiwania i analizy repo
  (gdzie używane, co zmienić, przegląd modułu) użyj `delegate_agent`, zamiast czytać pliki samemu”. Test
  `instructionsStayCompact` dalej obowiązuje.

## Apka

Nowa sekcja w pasku bocznym **Agents**:

- Lista z rejestru: ikona, nazwa, opis, wersja, typ dystrybucji; filtr „działa bez dodatkowych narzędzi”.
- Przyciski: Zainstaluj / Aktualizuj / Usuń; status: nie zainstalowany → zainstalowany → zalogowany.
- **Zaloguj:** metoda `agent` → apka uruchamia agenta, `initialize`, `authenticate(methodId)`; agent sam otwiera
  przeglądarkę. Metoda `terminal` → apka otwiera Terminal z poleceniem agenta i `args` z rejestru.
  Sprawdzenie „zalogowany”: `initialize` + `session/new` bez błędu `auth_required`.
- Ustawienia per agent: włączony, region danych, domyślny model, limit czasu, wskazówka dla Claude'a
  (jak `guidance` u dostawców).
- Podgląd ostatnich zadań: raport, czas, tokeny, odrzucone zapisy.

## Etapy

| Etap | Zakres | Gotowe, gdy |
|---|---|---|
| 0. Próba | ręczny skrypt: Vibe w sandboxie na snapshocie repo, jedno zadanie analizy | raport wraca, próba zapisu zostaje zablokowana, tokeny policzone, wiadomo, czy działa na limitach planu Vibe |
| 1. Rdzeń | `ACPConnection`, `ACPRegistry`, `AgentInstaller`, testy na atrapie agenta | instalacja Vibe z rejestru do katalogu `Delegate` i handshake w testach |
| 2. Wykonanie | `RepoSnapshot`, `AgentSandbox`, `AgentPolicy`, `AgentRun`, trwałe zadania | zadanie z Claude'a przez `delegate_agent` → raport w `delegate_result` |
| 3. Apka | sekcja Agents, logowanie, ustawienia, podgląd zadań | instalacja i logowanie bez terminala |
| 4. Instrukcje | sekcja w instrukcjach serwera, `list_models` pokazuje agentów | Claude sam używa agenta do analizy repo |
| Później | tryb zapisu (worktree na gałęzi, diff do przejrzenia, testy z białej listy); agenci `npx` (Gemini CLI) z wykrywaniem Node | osobny plan |

Etap 0 jest najważniejszy: rozstrzyga, czy to w ogóle ma sens, zanim powstanie kod apki.

## Testy

- Atrapa agenta: mały wykonywalny skrypt/binarka mówiąca ACP ze scenariuszami (sukces, prośba o zapis,
  `auth_required`, zawieszenie, błąd w połowie). `ACPConnection` i `AgentRun` testowane na niej, bez sieci.
- `ACPRegistry` na zapisanym `registry.json`; `AgentInstaller` na lokalnym archiwum (zła suma → odmowa).
- `AgentSandbox`: proces w profilu próbuje zapisać do repo i czytać `~/.ssh` → oba odrzucone.
- `RepoSnapshot`: niezacommitowana zmiana widoczna w kopii, oryginalne repo nietknięte, sprzątanie po zadaniu.

## Ryzyka i pytania otwarte

- **Prywatność:** agent czyta całe repo i wysyła je dostawcy. Potrzebna świadoma zgoda (np. włączenie agenta
  per projekt) i egzekwowanie regionów. Vibe na planie Experiment może używać danych do trenowania.
- **Skille i config z katalogu domowego:** Vibe ładuje Twoje skille — wpływa to na zachowanie i może wynieść
  ich treść. Do sprawdzenia, czy da się to wyłączyć bez psucia logowania (osobny `HOME` zgubiłby tokeny).
- **`sandbox-exec` przestarzały:** działa dziś, ale Apple może go usunąć. Bez niego tryb tylko-do-odczytu
  opierałby się na dobrej woli agenta — wtedy lepiej wyłączyć funkcję niż udawać bezpieczeństwo.
- **Limity planu:** czy `browser-auth` w Vibe liczy się do subskrypcji Pro (Vibe) i jakie są limity — sprawdzić w etapie 0.
- **Jakość:** raporty tańszych modeli trzeba weryfikować (próbna recenzja z `mistral-code-latest` była słaba).
  Mierzyć: czy Claude po raporcie i tak czyta te same pliki? Jeśli tak, oszczędności nie ma.
- **Pliki nieśledzone** w snapshocie: kopiować czy nie (domyślnie nie, `.gitignore` chroni np. `.env`).
- **Wersje ACP:** jest już v2; MVP na v1, którą mówi Vibe. Negocjacja wersji w `initialize`.

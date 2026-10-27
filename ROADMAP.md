# Roadmapa

Stan na 27.10.2026. Szczegóły techniczne i wyniki prób agentów: `docs/acp-plan.md`.

## Cel

Claude (albo inny asystent) jako dyrygent: rozbija pracę na zadania, oddaje je w tle tańszym modelom i agentom
(każdy na swoim loginie albo kluczu), a sam tylko przegląda wyniki i scala. Oszczędza to limity głównej subskrypcji.

## Zrobione

- [x] **Delegowanie tekstu** — `delegate` z `files` (serwer czyta pliki sam), `output_file` (wynik prosto na dysk),
  `background` + `delegate_result` (kilka zadań naraz), limity czasu dopasowane do klienta MCP.
- [x] **Odporność na awarie dostawców** — przerwy dla modeli po 429/503/400/404 (`model_cooldowns.json`), fallback do
  podobnych modeli, informacja o pominiętych w nagłówku odpowiedzi.
- [x] **Agenci ACP do analizy repo** — `delegate_agent`: agent z rejestru ACP (jak w Zedzie) pracuje w tle na kopii repo,
  w piaskownicy macOS, tylko do odczytu, na swoim loginie. Przetestowani na żywo: Mistral Vibe, Google Antigravity,
  GitHub Copilot. Zainstalowani też Codex i Claude Agent.
- [x] **Instalacja agentów** — binarki (suma SHA-256 z rejestru albo podpis Developer ID, niepodpisane za zgodą),
  paczki npm przez systemowy Node, logowanie z apki (przeglądarka albo Terminal).
- [x] **Agenci w apce** — sekcja w pasku bocznym ze stronami agentów, przeglądanie rejestru, diagnostyka w Overview.

## Do zrobienia (w tej kolejności)

### A. Ustawienia per agent — fundament pod resztę
- [x] **A1. Domyślny model i wysiłek per agent.** Przykład, dla którego to robimy: Claude Code oddaje zadanie
  Claude Agentowi z modelem `haiku` i wysiłkiem `low` — ta sama subskrypcja, ale dużo mniej zużytego limitu
  (jak subagent z tańszym modelem, tylko w tle i w piaskownicy). Claude Agent ogłasza modele `haiku`/`sonnet`/
  `opus`/`fable`, poziomy `low`…`max` i tryb `plan`. Zapis w `delegate.toml` (sekcja `[[agent]]`).
- [x] **A2. Region danych i włącz/wyłącz per agent.** Dziś region pochodzi z wbudowanej tabeli.
- [x] **A3. Lista agentów sprawdzana na bieżąco po stronie serwera**, żeby nowo zainstalowany agent działał bez
  restartu Claude'a (dziś schemat `delegate_agent` powstaje przy starcie sesji).
- [x] **A4. Zgoda per repo** — „to repo może iść do Copilota, to firmowe nigdzie”. Ważniejsze przed trybem zapisu.
- [x] **A5. Natywny tryb tylko do odczytu agenta** (np. `plan` w Claude Agent) jako dodatek do piaskownicy.

- [x] **Dodatek:** `list_models` pokazuje agentów z modelami, poziomami wysiłku, ustawieniami domyślnymi, stanem
  logowania i regułami repo (z `agents/checks.json`, zapisywanego przez apkę przy sprawdzaniu agentów).

### B. Tryb zapisu — serce swarmu, największy kawałek pracy
- [ ] **B1.** Agent dostaje worktree na gałęzi `delegate/<zadanie>`, który może zmieniać; wszystko poza nim nadal
  blokuje piaskownica.
- [ ] **B2.** Agent może uruchomić testy (`swift build`, `npm test`): zapis w swoim worktree i, dla menedżerów
  pakietów, sieć.
- [ ] **B3.** Wynik: gałąź z commitem, `git diff --stat` i raport. Dyrygent robi `git diff main...delegate/<zadanie>`,
  przegląda i scala albo odrzuca. Gałąź jest w Twoim repo, więc do scalenia nie trzeba nowych narzędzi.
- [ ] **B4.** Sprzątanie porzuconych gałęzi i limit równoległych agentów (żeby pięć naraz nie wyczerpało
  subskrypcji w kwadrans).

### C. Skill `/swarm` — jawny tryb dyrygenta
- [ ] Instrukcje serwera tylko zachęcają do delegowania, a Claude i tak decyduje sam. `/swarm wdroż roadmapę
  z ROADMAP.md` daje mu procedurę: rozbić cel na niezależne zadania → dobrać agentów i modele → wysłać równolegle →
  przejrzeć wyniki → scalić dobre, zgłosić resztę. Najpewniej największy efekt najmniejszym kosztem; ma sens po B.

### D. Podgląd zadań w apce
- [ ] Zakładka „Jobs”: zadania trwające i zakończone (dane już są w `jobs/*.json`) z agentem, czasem, wynikiem
  i gałęzią. Przy kilku agentach naraz trzeba widzieć, co się dzieje.

### E. Próba w prawdziwej pracy
- [ ] Kilka dni normalnej pracy, potem zakładka Usage: czy dyrygent sam sięga po agentów, czy trzeba go popychać
  skillem; które zadania się opłacają, a które kończą się poprawkami.

### F. Zgodność z innymi narzędziami AI
Serwer to zwykły serwer MCP, więc działa w każdym kliencie MCP (Codex, Cursor, Zed, VS Code, Antigravity). Brakuje:
- [ ] **F1.** Przycisków podpięcia w Overview dla innych klientów: Codex (`~/.codex/config.toml`), Cursor
  (`~/.cursor/mcp.json`), Zed (`context_servers`), VS Code, Gemini/Antigravity (`~/.gemini/settings.json`).
- [ ] **F2.** Uogólnienia tekstów pisanych pod Claude'a („save the user's Claude usage limits”).
- [ ] **F3.** Użycia nazwy klienta z `initialize` (`clientInfo`): serwer wie, kto jest dyrygentem, i może podpowiedzieć,
  że agent na tej samej subskrypcji (Claude Code → Claude Agent, Codex → Codex) ma sens tylko z tańszym modelem.

### G. Inne modele w Claude Agent („model backend”) — opcjonalnie
- [ ] Claude Agent to w środku Claude Code, a ten da się przepiąć zmiennymi `ANTHROPIC_BASE_URL` /
  `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` na dostawcę, który udaje API Anthropic (oficjalnie DeepSeek:
  `https://api.deepseek.com/anthropic`). Na stronie Claude Agent wybór „subskrypcja Claude” albo dostawca z configu;
  serwer wstawia adres, klucz z Keychain i model, a dla dyrygenta to osobny agent, np. `claude-acp@deepseek`.
  Region od dostawcy (DeepSeek zostaje `cn`). To działa na kluczu API, nie na loginie — dlatego na końcu.

### Odłożone
- Agenci wymagający `uv` (2 niszowe, bez własnych modeli).
- Własny harness przez OpenCode/goose dla dostawców bez agenta z logowaniem.

---

## Wcześniejsze fazy

  - Dodanie `.github/workflows/ci.yml` kompilującego i testującego projekt (`swift test`) oraz budującego aplikację produkcyjną pod macOS.

---

## Faza 5: UI/UX, Menu Bar i Dystrybucja (Polish & Ecosystem)
*Cel: Dostępność dla społeczności globalnej i wygoda codziennego użytkowania.*

- [x] **5.1. Skróty i status w Menu Bar**
  - Pokazywanie bieżącego statusu (lub dzisiejszego kosztu) w nagłówku menu bar oraz w widoku rozwijanym.
  - Przycisk szybkiego testu wszystkich połączeń bezpośrednio z menu podręcznego wraz ze wskaźnikami statusu na żywo.
- [x] **5.2. Język: tylko angielski**
  - Interfejs, odpowiedzi narzędzi i diagnostyka po angielsku. Polską lokalizację (`Localizable.xcstrings`) usunięto: teksty dla Claude'a po angielsku są skuteczniejsze i tańsze w tokenach, a przełącznik języka nie był potrzebny.
- [x] **5.3. Publiczne repozytorium i dokumentacja open-source**
  - Kompletna dokumentacja w języku angielskim (`README.md`), instrukcje kontrybucji (`CONTRIBUTING.md`) oraz szablony zgłoszeń GitHub (`bug_report.md`, `feature_request.md`).

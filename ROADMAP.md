# Roadmapa

Stan na 29.10.2026 (wersja 0.4.0). Szczegóły techniczne i wyniki prób agentów: `docs/acp-plan.md`.

## Cel

Claude (albo inny asystent) jako dyrygent: rozbija pracę na zadania, oddaje je w tle tańszym modelom i agentom
(każdy na swoim loginie albo kluczu), a sam tylko przegląda wyniki i scala. Oszczędza to limity głównej subskrypcji.

## Do zrobienia (w tej kolejności)

| Etap | Zakres | Gotowe, gdy |
|---|---|---|
| R1. Pomiar oszczędności | zestaw ok. 10 typowych zadań (tłumaczenie locale, README, fixture, review długiego pliku, analiza repo agentem…), każde przez `claude -p --output-format json` z serwerem `delegate` i bez, po 2 przebiegi; tokeny i koszt Claude'a + ocena wyniku wg rubryki. Najpierw pilot: 3–4 zadania po jednym przebiegu, żeby sprawdzić skrypt i rubrykę | tabela: które rodzaje zadań oszczędzają, które nie; wnioski wpisane do instrukcji serwera |
| R2. Raporty agentów z dowodami | `delegate_agent` read: stały format raportu (tezy z `plik:linia`, osobno pewne i do sprawdzenia), żeby Claude weryfikował wyrywkowo | w R1 Claude czyta po raporcie mniej plików niż bez agenta |
| R6, krok 3. Kolejność agentów z danych | w R1 te same ok. 5 zadań przez każdego agenta | domyślna kolejność `[[agent]]` ustawiona z wyników, nie z opinii |
| E. Próba w prawdziwej pracy | uzupełnienie R1: kilka dni normalnej pracy, potem zakładka Usage i statystyki agentów w `list_models` | wiadomo, czy dyrygent sam sięga po agentów, czy trzeba go popychać skillem; które zadania kończą się poprawkami |
| Później | tylko jeśli R1 pokaże zysk: wagi routingu zamiast samej kolejności (jak „mode packs” w OmniRoute); panel tanich modeli + sędzia do review | osobny plan |

Drobne:
- [ ] Pole `thinking` przy modelu (R5) jest tylko w TOML; kontrolka w edytorze modeli w apce.

Opcjonalnie:
- [ ] **G. Inne modele w Claude Agent („model backend”).** Claude Agent to w środku Claude Code, a ten da się przepiąć
  zmiennymi `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` na dostawcę, który udaje API Anthropic
  (oficjalnie DeepSeek: `https://api.deepseek.com/anthropic`). Na stronie Claude Agent wybór „subskrypcja Claude” albo
  dostawca z configu; serwer wstawia adres, klucz z Keychain i model, a dla dyrygenta to osobny agent, np.
  `claude-acp@deepseek`. Region od dostawcy (DeepSeek zostaje `cn`). Działa na kluczu API, nie na loginie.

## Zrobione

Podstawy:
- **Delegowanie tekstu**: `delegate` z `files` (serwer czyta pliki sam), `output_file` (wynik prosto na dysk),
  `background` + `delegate_result` (kilka zadań naraz), limity czasu dopasowane do klienta MCP.
- **Odporność na awarie dostawców**: przerwy dla modeli po 429/503/400/404 (`model_cooldowns.json`), fallback do
  podobnych modeli, informacja o pominiętych w nagłówku odpowiedzi.
- **Apka**: status i koszt w menu bar, szybki test połączeń, tylko angielski interfejs, publiczne repo z dokumentacją,
  CI i wydania z podpisem i notaryzacją.

Agenci ACP (etapy A–D, F):
- **Analiza repo**: `delegate_agent` pracuje w tle na kopii repo, w piaskownicy macOS, tylko do odczytu, na loginie agenta.
- **Instalacja**: binarki (SHA-256 z rejestru albo podpis Developer ID, niepodpisane za zgodą), paczki npm przez
  systemowy Node, logowanie z apki (przeglądarka albo Terminal).
- **A. Ustawienia per agent**: domyślny model i wysiłek, region, włącz/wyłącz, lista agentów liczona na bieżąco,
  zgoda per repo (`[[repo]]`), natywny tryb tylko do odczytu; `list_models` opisuje agentów.
- **B. Tryb zapisu**: worktree na gałęzi `delegate/…`, testy i budowanie w piaskownicy, wynik jako commit + `--stat`,
  sprzątanie gałęzi, limit równoległych agentów.
- **C. Skill `/swarm`** (instalacja z Overview) i `branch_from` na rundy poprawek.
- **D. Zakładka Jobs**: zadania wszystkich sesji z agentem, modelem, repo, trybem, czasem, wynikiem i gałęzią.
- **F. Inni klienci MCP**: przyciski podpięcia (Codex, Cursor, Zed, VS Code, Gemini CLI, Antigravity), teksty bez
  nazwy Claude'a, dyrygent rozpoznawany z `clientInfo`.

Wersja 0.4.0 (etapy R z 29.10.2026):
- **R0. Region gatewayów**: localhost jest `local` tylko na portach Ollamy (11434) i LM Studio (1234), inaczej `other`;
  presety Ollama i LM Studio zapisują region jawnie.
- **R3. Odmowy z instrukcją**: każda odmowa routingu i „All attempts failed” kończą się „What to do:”.
- **R4. Preset gatewaya**: „Gateway (OmniRoute / LiteLLM)” z obowiązkowym wyborem regionu przy dodawaniu.
- **R5. Gemini**: niski poziom myślenia dla Flash/Pro 3+, pole `thinking` per model, tokeny myślenia w logu (wyniki niżej).
- **R6, kroki 1–2. Ranking agentów**: kolejność `[[agent]]` = priorytet (przeciąganie w apce), `guidance` per agent,
  opcjonalne pole `agent`; przerwy dla agentów (logowanie, limit planu, dwa limity czasu z rzędu), wykrywanie
  zawieszenia po ciszy (180 s odczyt, 360 s zapis), fallback na następnego agenta po błędzie na starcie, statystyki
  z logu (30 dni) w `list_models`.

## Źródła i wnioski (29.10.2026)

- **Anthropic, „Building agents: when to fold subagents into your main agent loop”** (2026-10-22). Jeden agent
  z jednym kontekstem, skillami i narzędziami zwykle wygrywa z orkiestratorem i specjalistami: każde przekazanie
  między agentami gubi szczegóły. Subagenci mają sens, gdy kontekst puchnie, gdy zadania idą równolegle w świeżych,
  wyrzucanych kontekstach, albo gdy model myli narzędzia. Dzielić pracę według kontekstu (niezależne ścieżki
  badania, komponenty z czystym interfejsem, weryfikacja „czarnej skrzynki”), nie według rodzaju problemu.
  Ewaluacje: ok. 10 złotych przykładów end-to-end, każde zadanie więcej niż raz. Reguły i uprawnienia w narzędziach
  (odmowa z instrukcją, co dalej), procedury w skillach. Wybór narzędzi psuje się powyżej 30–50 definicji.
  O delegowaniu do tańszych modeli artykuł nie mówi nic.
- **OmniRoute** (`cheaper-inference/OmniRoute`, kanoniczne repo prawdopodobnie `diegosouzapw/OmniRoute`). Gateway
  w TypeScripcie z jednym endpointem zgodnym z OpenAI: 377 dostawców, scoring z 16 czynników, łączenie darmowych
  limitów, fallback subskrypcja → klucz → tani → darmowy, dashboard, MCP. Claude Code podpina się przez
  `ANTHROPIC_BASE_URL`. Liczby oszczędności i darmowych tokenów podaje sam projekt; TPROXY (przechwytywanie TLS)
  i maskowanie odcisku TLS wymagają przeglądu bezpieczeństwa.

Wnioski:
- **Nie stajemy się gatewayem.** OmniRoute podmienia model pod klientem; my zostawiamy Claude'a jako dyrygenta na
  jego subskrypcji i oddajemy zadania poboczne. Wyróżniki: natywny macOS, Keychain, egzekwowane regiony danych,
  agenci ACP w piaskownicy. Gateway może być jednym z naszych dostawców (R4).
- **Model „pliki na wejściu, `output_file` na wyjściu” jest zgodny z artykułem**: mało kontekstu przechodzi przez
  granicę, wynik da się sprawdzić `git diff`.
- **Najsłabszy punkt: raporty `delegate_agent` w trybie read.** To dokładnie stratne streszczenie, przed którym
  ostrzega artykuł. Pytanie z `acp-plan.md` („czy Claude po raporcie i tak czyta te same pliki?”) trzeba zmierzyć (R1, R2).
- **Nie mamy żadnego pomiaru, czy delegowanie oszczędza** tokeny Claude'a przy tej samej jakości. Bez tego każda
  kolejna funkcja routingu to zgadywanie (R1).
- Narzędzi jest 7, więc limit 30–50 nas nie dotyczy. Claude Code ładuje je przez tool search (odroczone), więc
  główną dźwignią zostają instrukcje serwera: trzymać je krótkie (`instructionsStayCompact`).

## Wyniki

### Gemini (R5)

- Stary log (13 wywołań, 27.10): „cancelled” po 60 s i timeout po 120 s były przed poprawką limitów czasu
  (`fa92325`); 400 „Interactions API”, 500 z Gemmy i 429 `limit: 0` z Pro już mają przerwy, a modele wyleciały z configu.
- Prawdziwa przyczyna wolnych odpowiedzi: `gemini-flash-latest` (Gemini 3.x) domyślnie myśli na `medium`/`high`.
  To samo zadanie (README na 400 słów, w tle): domyślne myślenie → timeout po 120 s (dwa razy), `thinkingLevel: low` → 36,5 s.
  Serwer wysyła `low` dla Flash/Pro 3+, Flash-Lite zostaje na swoim `minimal` (`ProviderClient.geminiThinking`).
- Darmowy plan i tak jest wolny (flash-lite ok. 14 tokenów/s, 20–25 s na 300 tokenów) i `flash-latest` często zwraca 503
  w godzinach szczytu: wszystko dłuższe niż akapit tylko w tle.

### Agenci przed R6 (z `jobs/`, mała próbka, głównie 27.10)

Problem był taki: Claude wybierał agentów z listy w kolejności alfabetycznej, bez danych, więc często brał Antigravity
(pierwszy na liście, dużo błędów) i Codexa (darmowy plan z limitami, długo myśli), a prawie nigdy Mistral Vibe, który
zwykle wystarcza i jest najszybszy.

| Agent | Udane | Czas (read) | Czas (write) | Uwagi |
|---|---|---|---|---|
| mistral-vibe (glm-5-3) | 3/3 | 19–29 s | 278 s | raporty trafne |
| claude-acp (haiku, low) | 7/7 | 7–122 s | — | ta sama subskrypcja co dyrygent |
| codex-acp (gpt-6-luna, medium) | 6/7 | 332 s | 160–280 s | 1× limit 600 s, 38–66 kroków |
| antigravity-acp | 2/3 | 78–394 s | — | 1× limit 600 s: uruchomił zadanie w tle i czekał na nie do końca |
| github-copilot-cli | 1/2 | 30 s | — | 1× niezalogowany |

Statystyki liczymy z logu użycia, nie z `JobStore`: pliki zadań znikają po tygodniu. Są tylko w `list_models`, nie
w opisie narzędzia, bo opis jest w cache'owanym prefiksie i zmieniające się liczby psułyby prompt cache dyrygenta.

## Czego nie robimy

- Własnego proxy pod `ANTHROPIC_BASE_URL` ani łączenia kont subskrypcyjnych (regulaminy, inny produkt).
- Hierarchii subagentów i kolejnych narzędzi MCP bez pomiaru, że pomagają.
- Gonienia OmniRoute liczbą dostawców: kto potrzebuje setek modeli, podpina gateway jako dostawcę (R4).

Odłożone:
- Agenci wymagający `uv` (2 niszowe, bez własnych modeli).
- Własny harness przez OpenCode/goose dla dostawców bez agenta z logowaniem.

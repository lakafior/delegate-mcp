# Roadmapa

Stan na 29.10.2026 (wersja 0.7.1). Szczegóły techniczne i wyniki prób agentów: `docs/acp-plan.md`.

## Cel

Claude (albo inny asystent) jako dyrygent: rozbija pracę na zadania, oddaje je w tle tańszym modelom i agentom
(każdy na swoim loginie albo kluczu), a sam tylko przegląda wyniki i scala. Oszczędza to limity głównej subskrypcji.

## Do zrobienia (w tej kolejności)

| Etap | Zakres | Gotowe, gdy |
|---|---|---|
| R1c. Jakość przy delegowaniu | z R1b: tani model psuje szczegóły, które Opus robi sam (kategorie liczby mnogiej w es/fr), a Opus nie dał `check`. Instrukcje: reguły łatwe do przeoczenia wprost w briefie, `check` przy każdym pliku z formatem (JSON, testy); dużo powtarzalnych danych → skrypt generujący zamiast delegowania | tłumaczenie na 4 języki z `delegate` zachowuje oszczędność ok. 50% i ocenę sędziego ≥ 4 |
| R2. Raporty agentów z dowodami | `delegate_agent` read: stały format raportu (tezy z `plik:linia`, osobno pewne i do sprawdzenia), żeby Claude weryfikował wyrywkowo. R1b: z agentem dyrygent czytał 3–6 plików zamiast 10–13, ale wciąż weryfikował; sędzia wytknął zmyślone odwołania w jednym raporcie | po raporcie dyrygent czyta najwyżej 1–2 pliki, ocena sędziego 5 |
| R6, krok 3. Kolejność agentów z danych | te same ok. 5 zadań przez każdego agenta (`delegate_agent` z podanym `agent`) | domyślna kolejność `[[agent]]` ustawiona z wyników, nie z opinii |
| E. Próba w prawdziwej pracy | uzupełnienie R1: kilka dni normalnej pracy, potem zakładka Usage i statystyki agentów w `list_models` | wiadomo, czy dyrygent sam sięga po agentów, czy trzeba go popychać skillem; które zadania kończą się poprawkami |
| Później | tylko jeśli R1 pokaże zysk: wagi routingu zamiast samej kolejności (jak „mode packs” w OmniRoute); panel tanich modeli + sędzia do review | osobny plan |

Drobne:
- [ ] Pole `thinking` przy modelu (R5) jest tylko w TOML; kontrolka w edytorze modeli w apce.
- [ ] Claude Code ma `timeout` per serwer MCP (ms, progress go nie przedłuża): sprawdzić, czy pozwala czekać dłużej
  niż 60 s w jednym wywołaniu; jeśli tak, instalator go wpisuje, a `delegate_result` czeka dłużej (mniej tur).
- [ ] Pomiar z co najmniej 5 przebiegami (`--runs 5`) dla `translate-locale` i `analyze-repo-agent`: liczby w README
  (−50%, −38%) są z 2 przebiegów, a w claude-token-efficient −63% z małej próbki skurczyło się do −1…−18%. Przy okazji
  sprawdza instrukcje 0.7.1 (nowa kolejność, przycinany katalog).
- [ ] Mapa repo na start `delegate_agent` (jak `workspace-map` w intentic: obszary repo do 2800 znaków; u nich −47%
  listowań katalogów, −18% wywołań przed pierwszą edycją). Odciąża agentów, nie dyrygenta; najpierw zadanie w `eval/`.
- [ ] Pomiar 0.6.0: `translate-four` (czy `alwaysLoad` zdejmuje turę ToolSearch) i nowe zadanie analiza → zmiana
  z `context_jobs` i bez.

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
- **R1. Pomiar oszczędności** (`eval/`, wyniki niżej) i poprawki z niego: `delegate` bez `background` czeka na wynik
  w tej samej turze (wolniejszy zostaje zadaniem w tle), instrukcje serwera i blok w `~/.claude/CLAUDE.md` z progiem
  ~300 linii i zasadą jednej rundy; zły albo nieczytelny klucz nie przechodzi po wszystkich modelach dostawcy.
- **R1b. Pomiar po poprawkach** (wyniki niżej): delegowanie oszczędza przy dużym wyjściu i z agentem, kosztem jakości szczegółów.
- **Model seniora z juniorami**: `check` w `delegate` i `delegate_agent` (zapis) z rundami poprawek po stronie serwera
  (do 2), akceptacja po zielonym `check` i `--stat`, krótkie briefy w instrukcjach i `/swarm`. Z R1: po delegowaniu
  Opus robił 4–11 wywołań, pisał własne walidatory (venv, `npx ajv`), a briefy miały 1–5 tys. znaków.
- **R6, kroki 1–2. Ranking agentów**: kolejność `[[agent]]` = priorytet (przeciąganie w apce), `guidance` per agent,
  opcjonalne pole `agent`; przerwy dla agentów (logowanie, limit planu, dwa limity czasu z rzędu), wykrywanie
  zawieszenia po ciszy (180 s odczyt, 360 s zapis), fallback na następnego agenta po błędzie na starcie, statystyki
  z logu (30 dni) w `list_models`.

Wersja 0.7.1 (z artykułów o oszczędzaniu tokenów i repo claude-token-efficient, intentic):
- **Instrukcje w limicie klienta**: Claude Code ucinał instrukcje po ok. 4096 znakach i przy 9 dostawcach przepadały
  zasady agentów. Teraz najwyżej 3800 znaków, katalog na końcu i tylko on się skraca; każdy tag zachowuje widoczny model,
  pominięci dostawcy są wymienieni z nazwy (routing po `task` i fallback dalej ich używają).
- **`output_file` bez wstępu**: model dostaje w `system` polecenie „sama treść pliku”, więc „Here is the file:” nie
  ląduje w pliku i nie kosztuje dyrygenta tury z Edit.

Wersja 0.7.0 (z katalogu darmowych dostawców OmniRoute, bez gatewaya):
- **Darmowi dostawcy**: presety Groq, NVIDIA NIM, SambaNova i Cloudflare Workers AI (API zgodne z OpenAI, bez karty,
  region `us`); poza nimi zostały dostawcy z ostrzeżeniami w regulaminie (webowe czaty, cudze logowania OAuth).
- **Limity z wyprzedzeniem**: nagłówki `x-ratelimit-*` po udanej odpowiedzi dają przerwę, zanim model odmówi;
  `retry-after` przy 429 ustala długość przerwy.

Wersja 0.6.0 (z artykułów i repo z sekcji niżej; jeszcze niezmierzone):
- **`alwaysLoad`**: `delegate` i `delegate_result` mają `_meta["anthropic/alwaysLoad"]`, więc Claude Code nie chowa ich
  za ToolSearch (R1 liczył ToolSearch jako dodatkową turę); `doctor` pokazuje, ile narzędzi tak oznaczono.
- **Kontekst po referencji**: `delegate_agent` z `context_jobs` / `context_files` dostaje pełne raporty wcześniejszych
  zadań jako pliki w kopii repo, zamiast żeby dyrygent je czytał i przepisywał; najostrzejsza `sensitivity` źródeł.
- **Najmniejsza zmiana**: polecenie agenta w trybie zapisu zabrania abstrakcji, zależności i refaktoryzacji obok
  (jak Ponytail u marmelab).

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

### Pomiar oszczędności (R1, 29.10.2026)

Skrypt: `eval/run.py`, 8 zadań, każde przez `claude -p` z serwerem `delegate` i bez; koszt dyrygenta z `modelUsage`,
jakość z `check.py` i sędziego (Sonnet, 1–5). Pilot na Sonnecie (1 przebieg), potem Opus (2 przebiegi dla 3 zadań,
1 dla pozostałych 5: w połowie skończył się limit sesji). Szum przy jednym przebiegu: ok. ±25%.

Opus, koszt dyrygenta z `delegate` względem bez (mediana):

| Zadanie | Delegował? | Koszt | Tury | Sędzia (bez → z) |
|---|---|---|---|---|
| fixture'y (25 zamówień) | tak, Mistral | **+49%** (oba przebiegi +48–50%) | 8,5 → 16 | 4,5 → 4,5 |
| testy jednostkowe | tak | **+57%** | 6 → 15 | 5 → 4 |
| dokumentacja CLI | tak | **+27%** | 8 → 20 | 5 → 4 |
| tłumaczenie 199 tekstów | tak | −1% | 5 → 9 | 3 → 4 |
| analiza repo | nie (agenta ani razu) | −17% | 20,5 → 18,5 | 5 → 5 |
| incydenty z logu | nie | −12% | 18 → 16 | 4 → 4 |
| review 422 linii | nie | −7% | 4,5 → 6 | 3,5 → 4 |
| changelog | nie | +8% | 5 → 5 | 5 → 5 |

Wnioski:
- **Na krótkich zadaniach delegowanie nie oszczędza, tylko kosztuje.** Każda tura od nowa czyta z cache cały kontekst
  (100–300 tys. tokenów); delegowanie dokładało 4–12 tur (ToolSearch, `delegate_result`, sprawdzanie wyniku, poprawki).
  Nawet tokeny wyjścia dyrygenta nie spadały: brief i poprawki zjadały różnicę (testy: 7,9 → 11,1 tys.).
- **Próg.** Wyjście Opusa jest ok. 5× droższe od wejścia, odczyt cache ok. 10% wejścia, więc jedna tura przy 150 tys.
  kontekstu to ok. 3 tys. tokenów wyjścia. Przy kilku dodatkowych turach delegowanie zwraca się dopiero powyżej
  ok. 12–15 tys. tokenów wyjścia (kilkaset linii). Nasze zadania miały 4–9 tys.
- **Jakość tanich modeli nie jest problemem:** Mistral dał tę samą albo lepszą ocenę (fixture'y, tłumaczenie); gorzej
  o punkt tylko testy i dokumentacja.
- **Opus rzadko deleguje i nie użył `delegate_agent` ani razu**, także przy analizie repo. R2 trzeba mierzyć wprost.
- Różnice w zadaniach bez delegowania (−17%…+8%) to szum, nie efekt serwera.

### Pomiar po poprawkach (R1b, 29.10.2026)

Nowy serwer (`delegate` czeka na wynik w tej samej turze, próg ~300 linii, `check`, briefy w stylu seniora), Opus,
2 przebiegi na wariant.

| Zadanie | Bez `delegate` | Z `delegate` | Tury | Sędzia (bez → z) |
|---|---|---|---|---|
| tłumaczenie 199 tekstów na 4 języki | $1,11 | **$0,56 (−50%)** | 10 → 22,5 | 5 i 4 → 4 i 2 |
| 200 fixture'ów | $0,48 | $0,48 (0%) | 10,5 → 12 | 4 → 4 |
| analiza repo, agent wymuszony | $0,98 (z R1) | **$0,61 (−38%)** | 20,5 → 11,5 | 5 → 4 |

Wnioski:
- **Powyżej progu delegowanie oszczędza:** przy dużym wyjściu (4 tłumaczenia: wyjście dyrygenta 28,6 → 9,1 tys.
  tokenów) i przy analizie repo agentem (mniej tur, 3–6 odczytów plików zamiast 10–13).
- **Ceną jest jakość szczegółów:** jedno tłumaczenie dostało 2/5 za błędne kategorie liczby mnogiej (`many` w es/fr
  z wymyślonymi formami); Opus pisze to poprawnie sam, tani model trzeba o to poprosić. Opus nie użył `check`.
- **Przy dużych powtarzalnych danych najtańszy jest skrypt:** przy 200 fixture'ach Opus w obu wariantach napisał
  generator w Pythonie, więc delegowanie nie miało czego oszczędzić.
- Raport agenta zastępuje część czytania, ale dyrygent go weryfikuje; dowody `plik:linia` w raporcie (R2) mogą to skrócić.

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

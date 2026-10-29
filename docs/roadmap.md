# Roadmapa (od 2026-10-29)

Punkt wyjścia: dwa źródła przeczytane 2026-10-29.

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

## Wnioski dla `delegate`

- **Nie stajemy się gatewayem.** OmniRoute podmienia model pod klientem; my zostawiamy Claude'a jako dyrygenta na
  jego subskrypcji i oddajemy zadania poboczne. Wyróżniki: natywny macOS, Keychain, egzekwowane regiony danych,
  agenci ACP w piaskownicy. Gateway może być jednym z naszych dostawców.
- **Model „pliki na wejściu, `output_file` na wyjściu” jest zgodny z artykułem**: mało kontekstu przechodzi przez
  granicę, wynik da się sprawdzić `git diff`.
- **Najsłabszy punkt: raporty `delegate_agent` w trybie read.** To dokładnie stratne streszczenie, przed którym
  ostrzega artykuł. Pytanie z `acp-plan.md` („czy Claude po raporcie i tak czyta te same pliki?”) trzeba zmierzyć.
- **Nie mamy żadnego pomiaru, czy delegowanie oszczędza** tokeny Claude'a przy tej samej jakości. Bez tego każda
  kolejna funkcja routingu to zgadywanie.
- Narzędzi jest 7, więc limit 30–50 nas nie dotyczy. Claude Code ładuje je przez tool search (odroczone), więc
  główną dźwignią zostają instrukcje serwera — trzymać je krótkie (`instructionsStayCompact`).

## Etapy

| Etap | Zakres | Gotowe, gdy |
|---|---|---|
| R0. Region gatewayów ✅ | `PrivacyRegion.inferred`: dostawca `openai` na localhost nie jest automatycznie `local` ani darmowy; wyjątek dla presetów Ollama i LM Studio; jawne `privacy` wygrywa | test: custom provider na `localhost:20128` nie dostaje `sensitivity = private` i liczy się do budżetu |
| R1. Pomiar oszczędności | zestaw ok. 10 typowych zadań (tłumaczenie locale, README, fixture, review długiego pliku, analiza repo agentem…), każde przez `claude -p --output-format json` z serwerem `delegate` i bez, po 2 przebiegi; tokeny i koszt Claude'a + ocena wyniku wg rubryki | tabela: które rodzaje zadań oszczędzają, które nie; wnioski wpisane do instrukcji serwera |
| R2. Raporty agentów z dowodami | `delegate_agent` read: stały format raportu (tezy z `plik:linia`, osobno pewne i do sprawdzenia), żeby Claude weryfikował wyrywkowo | w R1 Claude czyta po raporcie mniej plików niż bez agenta |
| R3. Odmowy z instrukcją | gdy routing odrzuci wszystkich dostawców (region, budżet, przerwy), odpowiedź mówi Claude'owi, co zrobić: zrób sam / inna `sensitivity` / inny model | każda ścieżka odmowy w `DelegateService` ma test z treścią wskazówki |
| R4. Preset gatewaya | „Gateway (OmniRoute / LiteLLM)” w `ProviderPreset`: OpenAI-compatible, model `auto/cheap`, obowiązkowy wybór regionu przy dodawaniu | dodanie w apce bez edycji TOML; region nie jest zgadywany |
| R5. Niezawodność dostawców | przyjrzeć się Gemini: w logu 10 z 13 wywołań nieudanych (m.in. „network: cancelled” po 60 s) | przyczyna znana, przerwy i limity czasu dopasowane |
| R6. Ranking agentów | patrz niżej | `delegate_agent` bez pola `agent` trafia do pierwszego dozwolonego agenta wg priorytetu; większość analiz idzie do szybkiego agenta zamiast do Codexa/Antigravity |
| Później | tylko jeśli R1 pokaże zysk: wagi routingu zamiast samej kolejności (jak „mode packs” w OmniRoute); panel tanich modeli + sędzia do review | osobny plan |

## R6. Ranking agentów

Problem: dostawcy mają kolejność (`[[provider]]`), notatki i wskazówki, a agentów Claude wybiera sam z listy
w kolejności `agents/installed.json` (alfabetycznej), bez żadnych danych. Pole `agent` jest wymagane. Skutek: Claude
często bierze Antigravity (pierwszy na liście, dużo błędów) i Codexa (darmowy plan z limitami, długo myśli),
a prawie nigdy Mistral Vibe (GLM, Mistral Large), który zwykle wystarcza i jest najszybszy.

Zadania z `jobs/` (mała próbka, głównie 2026-10-27):

| Agent | Udane | Czas (read) | Czas (write) | Uwagi |
|---|---|---|---|---|
| mistral-vibe (glm-5-3) | 3/3 | 19–29 s | 278 s | raporty trafne |
| claude-acp (haiku, low) | 7/7 | 7–122 s | — | ta sama subskrypcja co dyrygent |
| codex-acp (gpt-6-luna, medium) | 6/7 | 332 s | 160–280 s | 1× limit 600 s, 38–66 kroków |
| antigravity-acp | 2/3 | 78–394 s | — | 1× limit 600 s: uruchomił zadanie w tle i czekał na nie do końca |
| github-copilot-cli | 1/2 | 30 s | — | 1× niezalogowany |

Krok 1 (tani, największy efekt):
- Kolejność `[[agent]]` w `delegate.toml` = priorytet, przeciąganie w apce jak u dostawców. Instrukcje serwera
  i opis pola `agent` wymieniają agentów w tej kolejności: pierwszy jest domyślny, innego wybierać tylko z powodu.
- `guidance` per agent (jedna linia, jak u dostawców), np. Vibe: domyślny do analiz i dobrze opisanych zmian, szybki;
  Codex: darmowy plan z limitami, wolny, tylko trudne zmiany w wielu plikach; Antigravity: niestabilny, w ostateczności.
- Pole `agent` opcjonalne: bez niego serwer wybiera pierwszego dozwolonego wg priorytetu (region, `[[repo]]`, przerwy).

Krok 2 (dane zamiast opinii):
- Przerwy dla agentów (jak `ModelCooldowns`): limit planu → do resetu, „not signed in” → do zalogowania, dwa limity
  czasu z rzędu → godzina. Wstrzymany agent odpada z wyboru; fallback na następnego tylko, gdy agent niczego nie zapisał.
- Wykrywanie zawieszenia: brak aktualizacji ACP przez N sekund → koniec zadania zamiast czekania 600 s.
- Statystyki z `JobStore` (odsetek udanych, mediana czasu) w `list_models`, nie w opisie narzędzia: opis jest w
  cache'owanym prefiksie i odświeża się przy `tools/list_changed`, więc zmieniające się liczby psułyby prompt cache
  Claude'a. W opisie co najwyżej zgrubne etykiety (szybki/wolny), zmieniane rzadko.

Krok 3: w R1 te same ok. 5 zadań przez każdego agenta; domyślną kolejność ustawić z wyników.

## Czego nie robimy

- Własnego proxy pod `ANTHROPIC_BASE_URL` ani łączenia kont subskrypcyjnych (regulaminy, inny produkt).
- Hierarchii subagentów i kolejnych narzędzi MCP bez pomiaru, że pomagają.
- Gonienia OmniRoute liczbą dostawców: kto potrzebuje setek modeli, podpina gateway jako dostawcę (R4).

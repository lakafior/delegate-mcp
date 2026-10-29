# Pomiar oszczędności (R1)

Czy delegowanie oszczędza limit dyrygenta przy tej samej jakości? Każde zadanie idzie przez `claude -p` w dwóch
wariantach: z samym serwerem `delegate` (z `/Applications/Delegate.app`, `--strict-mcp-config`) i bez żadnego
serwera MCP. Oba warianty mają te same dozwolone narzędzia, startują ze świeżej kopii `input/` jako repo gita
i nie widzą tego repo (katalogi robocze są w `/tmp/delegate-eval`, bo Claude Code czyta każdy `CLAUDE.md` w górę
drzewa katalogów).

```bash
python3 -I eval/run.py --runs 2 --model opus                  # pełny pomiar
python3 -I eval/run.py --tasks review-billing --runs 1 --model sonnet
python3 -I eval/run.py --tasks summarize-log --variants delegate --model haiku --no-judge   # test zadania
python3 -I eval/run.py --summary eval/results/<katalog>       # odbuduj summary.md
```

Wynik: `eval/results/<data>/` (poza gitem): `results.jsonl` (wiersz na przebieg), `summary.md` (mediany na zadanie
i wariant, oszczędność kosztu dyrygenta) i `work` z plikami i surowym strumieniem każdego przebiegu.

Liczymy koszt i tokeny samego dyrygenta z `modelUsage` (cache read, zapis do cache, wyjście), tury, czas i wywołania
narzędzi. Jakość: automatyczne `check.py` (0–1) i sędzia (domyślnie Sonnet, 1–5 według `rubric`; widzi wejście,
wynik i `judge_reference`, którego dyrygent nie widzi).

## Zadania (`tasks/<id>/`)

| Zadanie | Co robi dyrygent | Sprawdzenie |
|---|---|---|
| `translate-locale` | tłumaczy 199 tekstów UI na polski | klucze, placeholdery, nic po angielsku |
| `write-usage-docs` | dokumentacja CLI z kodu `tidy.py` | każda opcja i podkomenda opisana |
| `generate-fixtures` | 25 zamówień zgodnych ze schematem | schemat, unikalne ID, pokrycie enumów i przypadków brzegowych, jedna cena na SKU |
| `review-billing` | review 422 linii z 4 wstawionymi błędami | ile z 4 znalezionych |
| `write-unit-tests` | testy `unittest` do `textutils.py` | przechodzą na oryginale i wyłapują 5 mutantów |
| `summarize-log` | incydenty z 2400 linii logu | 3 incydenty i powtarzalność OOM |
| `write-changelog` | sekcja 1.3.0 z historii gita od `v1.2.0` | zmiany dla użytkownika są, techniczne i starsze nie |
| `analyze-repo` | co zmienić, żeby dodać nowy rodzaj wykluczenia, na kopii tego repo z `8989842` | wskazane właściwe pliki, kod nietknięty |

Nowe zadanie: `task.json` (`prompt`, `artifacts`, `rubric`, opcjonalnie `judge_inputs`, `judge_reference`), `input/`
i `check.py` z `check(workdir) -> {"score", "notes"}`; opcjonalne `setup(workdir)` zastępuje domyślne „git init +
jeden commit”. Pliki wejściowe generowały tanie modele (przez `delegate`); `billing.py` i log mają ręcznie
wstawione błędy i incydenty (`summarize-log/make_log.py`).

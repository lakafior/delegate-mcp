# Roadmap projektu delegate

Plan rozwoju serwera MCP `delegate` oraz aplikacji menu bar na macOS.

---

## 🎯 Wizja
Zapewnienie deweloperom pracującym z Claude (Desktop & Code) najwygodniejszego, bezpiecznego i opłacalnego mechanizmu delegowania zadań do tańszych, szybszych lub lokalnych modeli, przy pełnej kontroli nad prywatnością, kosztami i niezawodnością (fallback).

---

## Faza 1: Bezpieczeństwo i fundamenty (Security & Core Stability)
*Cel: Wyeliminowanie długu technologicznego, wzmocnienie ochrony danych i stabilności zapisu.*

- [x] **1.1. Nowoczesne API Keychain (Usunięcie deprecations)**
  - Oczyszczenie ścieżek dostępu bez zaufanych binariów (bezpośredni `SecItemAdd` / `SecItemUpdate`).
  - Wyizolowanie starszego modelu ACL (`SecAccessCreate`) w dedykowanej metodzie `createLegacyAccess`.
- [x] **1.2. Pre-flight detektor wycieku sekretów (Data Leak Prevention)**
  - Wdrożony `SecretLeakDetector` weryfikujący prompt przed wysłaniem do dostawców zewnętrznych (OpenAI, Anthropic, Google, AWS, GitHub, klucze prywatne, tokeny Bearer).
  - Ochrona przed przypadkowym wyciekiem danych z opcją wymuszenia wysłania (`allow_secrets = true`).
- [x] **1.3. Współbieżność i rotacja logów (`UsageLog`)**
  - Wprowadzona systemowa blokada plikowa (`flock`) w `UsageLog.append`, chroniąca przed uszkodzeniem JSONL przy równoległych zapytaniach.
  - Dodana funkcja rotacji wpisów `prune(olderThan:)` do usuwania przestarzałych logów.
- [x] **1.4. Czytelne parsowanie błędów dostawców HTTP**
  - Zaimplementowana metoda `ProviderClient.parseErrorBody` wyciągająca pole `error.message` z odpowiedzi JSON dostawców (OpenAI, Mistral, Gemini) zamiast surowego obcinania tekstu.

---

## Faza 2: Rozszerzenie silników i protokołów (Providers & Capabilities)
*Cel: Obsługa wszystkich wiodących platform, modeli lokalnych i formatów danych.*

- [ ] **2.1. Wsparcie dla modeli lokalnych bez klucza (Ollama, LM Studio, vLLM)**
  - Obsługa dostawców OpenAI-compatible bez wymogu ustawiania zmiennej środowiskowej czy wpisu w Keychain (`needsKey = false`).
  - Dedykowane szablony konfiguracji dla lokalnych endpointów (np. `http://localhost:11434/v1`).
- [ ] **2.2. Bezpośrednia integracja z Anthropic Messages API (`type = "anthropic"`)**
  - Dodanie natywnej obsługi protokołu Anthropic (`/v1/messages` z nagłówkami `x-api-key` i `anthropic-version`).
  - Umożliwienie delegowania do Claude 3.5 Haiku bezpośrednio na własnym kluczu Anthropic, bez konieczności używania OpenRoutera.
- [ ] **2.3. Format strukturyzowany (Structured Output / JSON Mode)**
  - Opcjonalny parametr `json: true` (lub schemat JSON) w narzędziu `delegate`.
  - Przekazywanie `response_format: {"type": "json_object"}` dla OpenAI/Mistral oraz `responseMimeType: "application/json"` dla Gemini.
- [ ] **2.4. Granularne timeouty i polityka ponawiania prób**
  - Możliwość zdefiniowania parametru `timeout_seconds` per dostawca w `delegate.toml`.
  - Wprowadzenie krótkiego connect timeoutu (10–15s), zapobiegającego blokowaniu łańcucha fallbacków przy niedostępnych serwerach.

---

## Faza 3: Koszty, analityka i zwrot z inwestycji (Cost & ROI Tracking)
*Cel: Namacalne pokazanie użytkownikowi, ile zaoszczędził delegując zadania.*

- [ ] **3.1. Wyliczanie faktycznych kosztów zapytań (USD)**
  - Rozszerzenie wpisu `UsageEntry` lub kalkulatora o koszt obliczany na podstawie `priceIn` / `priceOut` z konfiguracji modelu.
  - Wyświetlanie sumy wydatków w `UsageView` i narzędziu `usage_summary`.
- [ ] **3.2. Licznik zaoszczędzonych środków (ROI Ticker)**
  - Porównanie faktycznego kosztu wykonanego zapytania z hipotetycznym kosztem przetworzenia tych samych tokenów przez Claude 3.5 Sonnet / Opus.
  - Kafelek w interfejsie: *„Zaoszczędzono w tym miesiącu: ~$14.20”*.
- [ ] **3.3. Eksport historii użycia**
  - Opcja eksportu danych użycia do formatu CSV / JSON z poziomu widoku „Użycie”.

---

## Faza 4: Narzędzia CLI i diagnostyka (Developer Experience)
*Cel: Wygodna praca z poziomu konsoli, automatyzacja i utrzymanie konfiguracji.*

- [ ] **4.1. Komenda diagnostyczna `delegate-mcp doctor`**
  - Jedno polecenie sprawdzające:
    - Poprawność składni `delegate.toml`.
    - Dostępność kluczy w Keychain i `.env`.
    - Ping/test łączności do każdego aktywnego dostawcy.
    - Stan integracji z Claude Desktop i Claude Code.
- [ ] **4.2. Bezpieczna edycja `delegate.toml` z zachowaniem komentarzy**
  - Opcja bezpośredniej edycji surowego pliku TOML w aplikacji z walidacją składni przed zapisem lub zastosowanie bezstratnego parsera/formatera.
- [ ] **4.3. Pipeline testów CI/CD (GitHub Actions)**
  - Dodanie `.github/workflows/ci.yml` kompilującego i testującego projekt (`swift test`) pod macOS.

---

## Faza 5: UI/UX, Menu Bar i Dystrybucja (Polish & Ecosystem)
*Cel: Dostępność dla społeczności globalnej i wygoda codziennego użytkowania.*

- [ ] **5.1. Skróty i status w Menu Bar**
  - Pokazywanie bieżącego statusu (lub dzisiejszego kosztu) w nagłówku menu bar.
  - Przycisk szybkiego testu wszystkich połączeń bezpośrednio z menu podręcznego.
- [ ] **5.2. Międzynarodowa lokalizacja (i18n)**
  - Dodanie wsparcia dla języka angielskiego (domyślny) oraz polskiego za pomocą Xcode String Catalogs (`.xcstrings`).
- [ ] **5.3. Publiczne repozytorium i dokumentacja open-source**
  - Dokumentacja w języku angielskim (`README.md`), szablony Issues i instrukcje kontrybucji.

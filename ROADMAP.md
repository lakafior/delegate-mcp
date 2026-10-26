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

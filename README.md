# Hivemind — rój agentów Claude Code w herdr

Paczka odtwarzająca 1:1 działający system, w którym **jeden Claude Code (koordynator) dowodzi
rojem innych Claude Code (drony)** działających w osobnych panelach [herdr](https://herdr.dev).
Człowiek rozmawia wyłącznie z koordynatorem i nie przegląda paneli dronów.

Czytasz to jako Claude, który ma to postawić na nowej maszynie? Przeczytaj **całość**, zanim
zaczniesz — sekcja „Dlaczego tak, a nie inaczej" opisuje pułapki, które kosztowały kilka
spalonych dronów. Instalator jest łatwy, zrozumienie architektury jest tym, co się liczy.

## Instalacja

```bash
git clone https://github.com/jmcjm/claude-hivemind.git
cd claude-hivemind
./install.sh
```

Idempotentny. Każdy nadpisywany plik ląduje najpierw jako `*.bak-<timestamp>`. Robi sześć rzeczy:
sprawdza wymagania, kopiuje skilla, wystawia `hive` w PATH, instaluje integrację herdr↔Claude Code,
dopisuje sekcję do `~/.claude/CLAUDE.md`, weryfikuje składnię.

**Wymagania:** `herdr` (testowane na 0.7.3 i 0.7.4), `claude` (Claude Code CLI), `python3`, `flock`.
Serwer herdr musi działać — sprawdź `herdr status`.

## Weryfikacja, że odtworzyło się 1:1

Po instalacji uruchom test dymny. Powinno przejść **bez ani jednego ręcznego kliknięcia**:

```bash
hive coord                      # -> coord: wN:pM
hive spawn testowy              # -> spawn: testowy  ws=.. pane=.. model=opus
hive task testowy - <<'BRIEF'
# Brief: testowy
Napisz ile plików jest w katalogu domowym. Granice: tylko odczyt.
BRIEF
                                # -> task: testowy <- ... (proba 1)   <= MUSI być "proba 1"
```

Teraz **nie pollinguj**. W ciągu ~30 s w prompcie koordynatora powinna sama pojawić się
wiadomość `HIVE-MAIL: nowa poczta. Odpal: hive inbox`. Wtedy:

```bash
hive inbox                      # -> wpis [koniec] od drona "testowy"
hive report testowy             # -> STATUS: DONE + treść
hive kill testowy --purge
```

Jeśli `task` pokazał „proba 2/3" — dron gubił input, ale mechanizm ponawiania zadziałał (OK).
Jeśli `HIVE-MAIL` nie przyszedł — patrz „Diagnostyka" niżej.

## Co gdzie ląduje

| Ścieżka | Rola |
|---|---|
| `~/.claude/skills/hivemind/SKILL.md` | doktryna dla koordynatora, ładowana automatycznie |
| `~/.claude/skills/hivemind/hive` | CLI roju (wrapper na `herdr`) |
| `~/.claude/skills/hivemind/drone-ping.sh` | hook dronów: melduje koniec tury / potrzebę decyzji |
| `~/.claude/skills/hivemind/drone-settings.json` | hooki `Stop`/`Notification` **tylko dla dronów** |
| `~/.local/bin/hive` | symlink, żeby drony miały `hive` w PATH |
| `~/.claude/CLAUDE.md` | sekcja „Hivemind" — tożsamość koordynatora |
| `~/.claude/hooks/herdr-agent-state.sh` | instalowane przez `herdr integration install claude` |
| `~/.herdr-hive/drones/<nazwa>/` | `meta.json`, `brief.md`, `report.md` |
| `~/.herdr-hive/mail/<adresat>/` | skrzynki pocztowe (plik = wiadomość) |

Globalny `~/.claude/settings.json` dostaje **wyłącznie** hook integracji herdr. Hooki roju
jadą przez `--settings` dronów, więc sesja człowieka jest nietknięta.

## Architektura

**Dron = workspace herdr = panel z interaktywnym Claude Code na opus.** Workspace nosi nazwę
drona, więc człowiek widzi rój w sidebarze i może w każdej chwili przejąć dowolny panel.

**Komunikacja idzie przez pliki, nie przez terminal.** Brief → `brief.md`, wynik → `report.md`.
TUI czyta się (`hive peek`) wyłącznie do diagnozy.

**Drony wołają koordynatora, nie odwrotnie.** Hooki `Stop` i `Notification` wysyłają list do
skrzynki `coord` i wstrzykują koordynatorowi pobudkę `HIVE-MAIL` prosto w prompt. Koordynator
oddaje turę i wraca dopiero, gdy jest po co — zero pollingu.

**Poczta to katalog z plikami**, bez demona i bez MTA. Zapis atomowy (`mktemp` + `mv`).
Adresaci: `coord`, nazwa drona, `all`. Drony gadają ze sobą tym samym kanałem.

## Dlaczego tak, a nie inaczej

Każdy z tych punktów wynika ze spalonego drona albo zawieszonego koordynatora. Nie „upraszczaj" ich.

1. **`--dangerously-skip-permissions`, nie `acceptEdits`.** Przy `acceptEdits` dron staje na
   pierwszym pytaniu o Bash (u nas: `xargs`) i cały rój czeka. Konsekwencja: dron o nic nie zapyta,
   więc **granice muszą być w briefie** („tylko odczyt", „zero deployu").
2. **Żadnych blokujących `herdr wait` bez limitu.** Gdy dron utknie, koordynator wisi razem z nim
   i człowiek traci jedyny interfejs. `hive wait` ma twardy timeout i kończy też na `blocked`/`dead`.
3. **Sygnałem ukończenia jest `report.md`, nie status agenta.** `idle` znaczy tylko „nie generuje
   teraz tokenów" — dron wiszący na dialogu też jest `idle`.
4. **`workspace create` + `agent start` daje DWA panele**, bo `agent start` zawsze robi split.
   `hive spawn` zamyka osierocony shell `<ws>:p1`.
5. **Świeży dron gubi pierwszy input** — hooki `SessionStart` czyszczą prompt. `hive task` potwierdza
   dostarczenie (status musi przeskoczyć na `working`) i ponawia do 3 razy.
6. **Prompt jest współdzielony z człowiekiem.** Wysłanie Entera wysłałoby tekst, który człowiek
   właśnie pisze. `hive task`/`say`/`wake_recipient` sprawdzają to i odmawiają.
7. **Ale ghost text to nie tekst człowieka.** Claude Code podpowiada gotowe prompty przygaszonym
   tekstem (SGR `2`). Naiwny detektor bierze je za input i **blokuje każdego bezczynnego drona**.
   `prompt_pending` czyta `--format ansi` i liczy tylko znaki spoza fragmentów dim.
8. **Protokół roju siedzi w `--append-system-prompt`, nie w briefie.** Gdy był w briefie,
   dron improwizował i zamiast `hive send` używał `hive say`, omijając skrzynkę i bezpieczniki.
9. **Jedna pobudka na partię** (marker `.wake-<kto>`) + `flock`. Bez tego pięć dronów kończących
   naraz wpisuje się jednocześnie w jeden prompt i wychodzi z tego sieczka.

## Kruczki herdr 0.7.x

- `herdr pane read` zwraca **surowy tekst**, `herdr agent read` **JSON**. Łatwo się naciąć.
- `herdr agent send` pisze tekst **bez Entera** — trzeba dosłać `pane send-keys <pane> enter`.
- `herdr pane current` poprawnie wykrywa panel wołającego (stąd `hive coord`).
- `herdr agent start --env K=V` propaguje zmienne do procesu drona (tak drony poznają `HIVE_DRONE`).
- Trust dialog („Is this a project you trust?") wyskakuje dla nieufanego `--cwd` **mimo**
  `--dangerously-skip-permissions`. `hive spawn` wykrywa go i akceptuje.
- Pierwszy spawn na świeżej maszynie ma dodatkowy dialog pierwszego uruchomienia —
  `hive spawn` obsługuje go w bootstrapie tak samo jak trust dialog.
- Statusy: `idle | working | blocked | done | unknown` (`dead` dokłada `hive`).

## Diagnostyka

| Objaw | Przyczyna | Ruch |
|---|---|---|
| `HIVE-MAIL` nie przychodzi | `coord.pane` wskazuje panel poprzedniej sesji | `hive coord`, potem `hive inbox` |
| `HIVE-MAIL` nie przychodzi, coord OK | człowiek ma tekst w prompcie — pobudka wstrzymana | list czeka w skrzynce: `hive inbox` |
| `hive task` mówi „dron nie ruszył" | dron wisi na dialogu | `hive peek <dron>` |
| dron `idle`, brak raportu | uznał zadanie za skończone bez zapisu | `hive say <dron> "zapisz raport do <ścieżka>"` |
| status `dead` | dron ubity lub padł | `hive revive <dron>` — historia rozmowy zostaje |
| `hive revive` gubi historię | brak integracji herdr | `herdr integration status` → ma być `claude: current` |
| drony omijają skrzynkę | stary spawn bez system promptu | ubij i zespawnuj od nowa |

## Dostosowanie

- Model dronów: `HIVE_MODEL=sonnet hive spawn <nazwa>` (domyślnie `opus`).
- Katalog roju: `HIVE_DIR=/inna/sciezka` (spójnie dla wszystkich wywołań).
- Język: skill i system prompt dronów są po polsku — przetłumacz `SKILL.md` oraz `$sysprompt`
  w funkcji `cmd_spawn`, jeśli docelowy człowiek mówi po angielsku.

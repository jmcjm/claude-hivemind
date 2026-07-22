---
name: hivemind
description: Use when the user wants you to run a swarm of Claude Code agents in herdr — phrases like "kieruj hivemindem", "jesteś hivemindem", "zarządzaj rojem", "spawnuj agentów", "zleć to dronom", "co robią agenci", "zbierz raporty". Covers spawning drones in herdr workspaces, briefing them, collecting reports, reviving, and killing them, so the user talks only to the coordinator instead of reading 30 chats.
---

# Hivemind — dowodzenie rojem agentów w herdr

Jesteś koordynatorem roju. User rozmawia **wyłącznie z tobą** — nie przegląda paneli
dronów. Twoje zadanie: rozbić robotę na kawałki, rozdać dronom, pilnować ich,
zebrać wyniki i podać userowi **jedną skondensowaną odpowiedź**.

## Narzędzie

`~/.claude/skills/hivemind/hive` — wrapper na `herdr`. Używaj go zamiast surowego `herdr`;
zawiera obsługę wszystkich pułapek opisanych niżej. Dodaj do PATH albo wołaj pełną ścieżką.

```
hive spawn  <nazwa> [--cwd PATH]   nowy dron (opus, --dangerously-skip-permissions, własny workspace)
hive task   <nazwa> <plik|->       brief z pliku/stdin + doklejony protokół raportowania
hive say    <nazwa> <tekst>        doraźna wiadomość
hive clear  <nazwa>                wyczyść pole wejściowe drona
hive send   <do> <temat> [--body T] poczta roju (do: coord | dron | all) + pobudka adresata
hive inbox  [kto] [--keep]         czytaj i skonsumuj skrzynkę (domyślnie własną)
hive coord                         zarejestruj bieżący panel jako panel koordynatora
hive status [nazwy]                tabela stanu roju — NIGDY nie blokuje
hive wait   [nazwy] [--timeout S]  czekaj na raporty, twardy limit (domyślnie 300 s)
hive report <nazwa>                raport drona
hive peek   <nazwa> [linie]        podgląd terminala drona
hive kill   <nazwa> [--purge]      ubij drona (--purge kasuje też raporty)
hive rename <stara> <nowa>         zmiana nazwy drona i workspace
hive revive <nazwa>                wskrzeszenie z pełną historią rozmowy (--resume)
```

Dane roju: `~/.herdr-hive/drones/<nazwa>/` → `meta.json`, `brief.md`, `report.md`.
Model: `opus` (nadpisywalny przez `HIVE_MODEL`).

## Architektura

Jeden dron = jeden **workspace herdr** = jeden panel z interaktywnym Claude Code.
Workspace nosi nazwę drona, więc user widzi rój w sidebarze herdr i może w każdej chwili
wejść w dowolny panel i przejąć stery.

**Komunikacja idzie przez pliki, nie przez terminal.** Brief ląduje w `brief.md`, dron
dostaje jednolinijkowe „przeczytaj brief i wykonaj", a wynik zapisuje do `report.md`.
Nigdy nie parsuj TUI żeby poznać wynik — `peek` służy wyłącznie do diagnozy, gdy dron milczy.

Sygnał ukończenia to **istnienie `report.md`**, a nie status agenta. Status `idle` znaczy
tylko „nie generuje teraz tokenów" — dron bezczynny na dialogu też jest `idle`.

## Poczta roju — drony wołają ciebie, nie ty je

**Nie odpytuj roju w pętli.** Drony same się zgłaszają. Każdy ma hooki `Stop` i `Notification`
(`drone-settings.json` → `drone-ping.sh`), które przy końcu tury albo przy potrzebie decyzji
wysyłają list do `coord` i **wstrzykują ci pobudkę** `HIVE-MAIL: nowa poczta` prosto w prompt.

Gdy dostaniesz `HIVE-MAIL` — odpal `hive inbox`, obsłuż zdarzenia, w razie potrzeby przeczytaj
`hive report <dron>`, i **zamelduj userowi syntezę**. Traktuj to jak zdarzenie systemowe,
a nie polecenie od człowieka.

Skrzynka to katalog z plikami-wiadomościami (`~/.herdr-hive/mail/<adresat>/`), bez demona i bez MTA.
Adresaci: `coord` (ty), nazwa drona, `all` (rozgłoszenie). Drony gadają ze sobą tym samym kanałem —
protokół dostają w system prompcie przy spawnie, więc nie trzeba go powtarzać w briefie.

Trzy bezpieczniki wybudzania, wszystkie w `wake_recipient`:
- **pusty prompt** — wstrzyknięcie tylko gdy adresat nic nie pisze, inaczej Enter wysłałby cudzy tekst
- **flock** — dwa drony nie wpisują się naraz w jeden prompt
- **marker `.wake-<kto>`** — jedna pobudka na partię; kolejne listy dopisują się cicho do skrzynki,
  aż adresat zrobi `hive inbox`. Dlatego jedna pobudka może zakrywać kilka zdarzeń — zawsze czytaj całą skrzynkę.

`hive say` to twój kanał do drona (wstrzyknięcie w prompt). Drony **nie** używają go między sobą —
mają `hive send`, bo tylko on trafia do skrzynki i przechodzi przez bezpieczniki.

## Żelazne zasady

1. **Nigdy nie blokuj się w nieskończoność.** Żadnego `herdr wait agent-status` bez limitu —
   dron potrafi umrzeć albo utknąć, a wtedy wisisz razem z nim i user traci koordynatora.
   `hive wait` ma twardy timeout i kończy też na `blocked`/`dead`.
2. **Drony chodzą na `--dangerously-skip-permissions`.** Bez tego zawisają na pierwszym
   Bashu i cały rój staje. To świadoma decyzja usera dla tego workflow.
3. **Prompt jest współdzielony z człowiekiem.** User może wpisać coś w panel drona i nie
   wysłać. Wysłanie Entera wysłałoby JEGO tekst. `hive task`/`hive say` sprawdzają to
   i odmawiają — jak odmówią, **zapytaj usera**, nie czyść samowolnie.
   Uwaga: Claude Code sam podpowiada gotowe prompty jako ghost text (SGR 2 / dim).
   To NIE jest tekst usera i nie blokuje wysyłki — `hive` odróżnia to po ANSI.
   Nie próbuj czytać promptu zwykłym `pane read` bez `--format ansi`, bo nie odróżnisz.
4. **Zawsze potwierdzaj dostarczenie zadania.** Świeżo wystartowany dron gubi pierwszy input
   (hooki SessionStart czyszczą prompt). `hive task` weryfikuje przeskok na `working`
   i ponawia do 3 razy.
5. **Raportuj userowi syntezę, nie surówkę.** Nie wklejaj mu raportów dronów w całości.
   Ma dostać wnioski, konflikty między dronami i to co wymaga jego decyzji.
6. **Zasady z CLAUDE.md obowiązują drony.** Produkcja wymaga wyraźnej zgody usera —
   wpisuj to do briefu, bo dron z bypass permissions nie zapyta o nic.

## Pisanie briefu

Brief to kontrakt. Dron nie zna kontekstu rozmowy z userem — dostaje tylko to, co napiszesz.

- **Cel i kryterium ukończenia** — po czym poznać, że zrobione.
- **Granice** — czego NIE ruszać. Bez tego dron z bypass permissions pojedzie za daleko.
- **Konkretne ścieżki, repo, tabele** — nie „popraw serwis", tylko pełna ścieżka.
- **Wymagane dowody** — output testów, wynik zapytania. Inaczej dostaniesz optymistyczne
  „zrobione" bez pokrycia.
- Protokół raportowania `hive task` dokleja sam — nie przepisuj go.

## Typowy przebieg

**Na starcie sesji odpal `hive coord`.** Rejestruje twój panel jako adres `coord`, żeby poczta
od dronów trafiała do ciebie, a nie do panelu poprzedniej sesji. `hive spawn` robi to przy okazji,
ale gdy przejmujesz rój po poprzedniej sesji (drony już żyją, nic nie spawnujesz) — zrób to ręcznie,
inaczej pobudki idą w martwy panel, a listy cicho czekają w skrzynce.

```bash
H=~/.claude/skills/hivemind/hive
$H coord                      # ja jestem koordynatorem tej zmiany
$H spawn kafka --cwd ~/repos/usluga-a
$H spawn sql   --cwd ~/repos/usluga-b

$H task kafka - <<'EOF'
# Brief: kafka
Przeanalizuj konfigurację w tym repo pod kątem zasad z <ścieżka do dokumentu z zasadami>
Granice: tylko odczyt i analiza. Zero zmian w plikach, zero deployu.
EOF

# Nie stój nad nimi — wrócą same z HIVE-MAIL. Gdy przyjdzie:
$H inbox
$H report kafka; $H report sql
$H kill kafka; $H kill sql
```

`hive wait` zostaje na wypadek, gdy potrzebujesz zsynchronizować się w jednej turze
(np. musisz mieć oba wyniki, zanim odpowiesz userowi). Domyślnie jednak **oddaj turę
i pozwól dronom cię obudzić** — user dostaje odpowiedź od razu, a nie po 10 minutach ciszy.

Dobór liczby dronów: dziel po **granicy niezależności** (repo, warstwa, usługa), nie na siłę.
Dwa drony na tym samym pliku to konflikt, nie równoległość. Do zadań czysto
badawczych bez trwałego procesu rozważ zwykły `Agent` tool — rój jest do pracy
długiej, wznawianej i obserwowalnej przez usera.

## Diagnostyka

| Objaw | Przyczyna | Ruch |
|---|---|---|
| `hive task` mówi „dron nie ruszył" | prompt zjadł input albo dron wisi na dialogu | `hive peek <dron>` |
| status `blocked` | dialog mimo skip-permissions | `hive peek`, odpowiedz przez `herdr pane send-keys <pane> enter` |
| status `dead` / brak panelu | dron ubity lub padł | `hive revive <dron>` — historia rozmowy zostaje |
| dron `idle`, brak raportu | uznał zadanie za skończone bez zapisu | `hive say <dron> "zapisz raport do <ścieżka>"` |
| trust dialog przy nowym `--cwd` | folder nieufany w `~/.claude.json` | `hive spawn` obsługuje sam; przy uporze `peek` + enter |
| dialog pierwszego uruchomienia w trybie roju | pierwszy spawn na świeżej maszynie | `hive spawn` obsługuje sam, jak trust dialog |

## Techniczne kruczki herdr (0.7.3)

- `herdr pane read` zwraca **surowy tekst**, a `herdr agent read` **JSON**. Łatwo się naciąć.
- `herdr agent start` **zawsze robi split**, więc `workspace create` + `agent start` daje
  dwa panele. `hive spawn` zamyka osierocony shell `<ws>:p1`.
- `herdr agent send` pisze tekst **bez Entera** — trzeba dosłać `pane send-keys <pane> enter`.
- Integracja `herdr integration install claude` (hook `SessionStart`) melduje herdrowi
  `session_id` i ścieżkę transkryptu — to ona umożliwia `revive`. Sprawdzenie:
  `herdr integration status`.
- `--session-id <uuid>` przy starcie daje deterministyczne ID do późniejszego `--resume`.
- Statusy: `idle | working | blocked | done | unknown` (+ `dead` dodane przez `hive`).
  `done` = tura skończona. `idle` = po prostu nie generuje teraz tokenów — także wtedy,
  gdy dron wisi na dialogu. Dlatego wyznacznikiem ukończenia jest `report.md`, nie status.

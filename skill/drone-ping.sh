#!/usr/bin/env bash
# drone-ping.sh — hook dronow roju. Melduje koordynatorowi koniec pracy lub potrzebe decyzji.
# Wolany z drone-settings.json (Stop / Notification). Argument: done|decision
#
# Bezpieczniki:
#  - dziala TYLKO gdy $HIVE_DRONE jest ustawione (spawn wstrzykuje) -> sesja koordynatora go nie odpala
#  - cala robota (skrzynka, blokady, pusty prompt) siedzi w `hive send` — tu tylko meldunek
set -uo pipefail

[ -n "${HIVE_DRONE:-}" ] || exit 0          # nie dron -> cisza

KIND_ARG="${1:-done}"
HIVE_DIR="${HIVE_DIR:-$HOME/.herdr-hive}"
HIVE_BIN="$HOME/.claude/skills/hivemind/hive"
[ -x "$HIVE_BIN" ] || exit 0

payload=$(cat 2>/dev/null || true)          # JSON hooka na stdin (Notification ma .message)

# Status z raportu drona, jesli zdazyl go zapisac
report="$HIVE_DIR/drones/$HIVE_DRONE/report.md"
status="brak raportu"
[ -f "$report" ] && status=$(grep -m1 -oE 'DONE|BLOCKED|FAILED' "$report" 2>/dev/null || echo "zapisany")

note=$(python3 -c "
import json,sys
try: print((json.loads(sys.argv[1] or '{}') or {}).get('message','') or '')
except Exception: print('')
" "$payload" 2>/dev/null)

if [ "$KIND_ARG" = decision ]; then
  subject="potrzebuje decyzji"
  herdr notification show "Dron $HIVE_DRONE czeka na decyzje" --sound request >/dev/null 2>&1
else
  subject="skonczyl ture (raport: $status)"
  herdr notification show "Dron $HIVE_DRONE skonczyl ($status)" --sound done >/dev/null 2>&1
fi

body="${note:-}"
[ -f "$report" ] && body="${body}${body:+
}raport: $report"

KIND="$KIND_ARG" HIVE_DRONE="$HIVE_DRONE" HIVE_DIR="$HIVE_DIR" \
  "$HIVE_BIN" send coord "$subject" --body "$body" >/dev/null 2>&1

exit 0

#!/usr/bin/env bash
# coord-scope.sh — shared scoping for the coordinator hooks. Sourced, never run on its own.
#
# The coordinator hooks are installed into the user's GLOBAL Claude Code settings, so they fire in
# every session on the machine: drones, unrelated projects, subagents. Everything that is not the
# one registered coordinator session must exit instantly and print nothing — a hook that injects
# swarm text into unrelated work is worse than no hook at all.

# hive_is_coordinator_session <session_id> — true only for the registered coordinator.
# Silence is the deliberate failure mode: when the registration cannot be confirmed, the answer
# is "no", never a guess.
hive_is_coordinator_session() {
  local sid="${1:-}"
  [ -n "$sid" ] && [ "$sid" != "-" ] || return 1
  [ -n "${HIVE_DRONE:-}" ] && return 1            # drones have their own protocol
  [ -n "${HIVE_DIR:-}" ] || HIVE_DIR="$HOME/.herdr-hive"

  # A coordinator living on another machine has no session here (hive coord --remote).
  [ -s "$HIVE_DIR/coord.remote" ] && return 1

  # Preferred: the session id recorded at registration. Costs nothing and works while the herdr
  # server is down. Optional — older installs only have coord.pane.
  local registered
  registered=$(cat "$HIVE_DIR/coord.session" 2>/dev/null)
  if [ -n "$registered" ]; then
    [ "$sid" = "$registered" ] && return 0
    return 1
  fi

  # Fallback: ask herdr which session owns the registered pane, the way coord-mail-check.sh does.
  local pane; pane=$(cat "$HIVE_DIR/coord.pane" 2>/dev/null)
  [ -n "$pane" ] || return 1
  command -v herdr >/dev/null 2>&1 || return 1
  local pane_sid
  pane_sid=$(herdr pane get "$pane" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
p=d.get('result',d).get('pane') or {}
print(((p.get('agent_session') or {}).get('value')) or '')" 2>/dev/null)
  [ -n "$pane_sid" ] && [ "$sid" = "$pane_sid" ]
}

# hive_hook_field <payload-json> <key>... — prints one value per line, empty when absent.
hive_hook_field() {
  local payload="$1"; shift
  python3 -c "
import json,sys
try: d=json.loads(sys.argv[1] or '{}')
except Exception: d={}
for k in sys.argv[2:]:
    v=d.get(k)
    print(v if isinstance(v,str) else ('' if v is None else str(v)))
" "$payload" "$@" 2>/dev/null
}

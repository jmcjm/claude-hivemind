#!/usr/bin/env bash
# install.sh — installs hivemind (a swarm of Claude Code agents in herdr) on this machine.
# Idempotent: safe to run repeatedly. Never overwrites anything without a backup.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DST="$HOME/.claude/skills/hivemind"
BIN_DST="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"

ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

echo "== 1/7 Requirements =="
command -v herdr  >/dev/null || die "herdr missing — install from https://herdr.dev and rerun"
command -v claude >/dev/null || die "claude missing (Claude Code CLI)"
command -v python3 >/dev/null || die "python3 missing"
command -v flock  >/dev/null || die "flock missing (util-linux package)"
ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"
ok "claude $(claude --version 2>/dev/null | awk '{print $1}')"
HERDR_MAJOR_MINOR=$(herdr --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
case "$HERDR_MAJOR_MINOR" in
  0.8) : ;;
  0.7) die "herdr 0.7.x will not work with this version (no agent prompt / agent start into an existing pane) — update herdr or use commit 604848c" ;;
  *)   warn "tested on herdr 0.8.x — on another version check the 'herdr technicalities' section in SKILL.md" ;;
esac

echo "== 2/7 Skill files =="
mkdir -p "$SKILL_DST"
for f in hive drone-ping.sh coord-mail-check.sh drone-settings.json SKILL.md; do
  if [ -e "$SKILL_DST/$f" ] && ! cmp -s "$SRC/skill/$f" "$SKILL_DST/$f"; then
    cp "$SKILL_DST/$f" "$SKILL_DST/$f.bak-$STAMP"
    warn "existing $f archived as $f.bak-$STAMP"
  fi
  cp "$SRC/skill/$f" "$SKILL_DST/$f"
done
chmod +x "$SKILL_DST/hive" "$SKILL_DST/drone-ping.sh" "$SKILL_DST/coord-mail-check.sh"
ok "skill in $SKILL_DST"

echo "== 3/7 hive in PATH =="
mkdir -p "$BIN_DST"
ln -sf "$SKILL_DST/hive" "$BIN_DST/hive"
ok "symlink $BIN_DST/hive"
case ":$PATH:" in
  *":$BIN_DST:"*) ok "$BIN_DST is in PATH" ;;
  *) warn "$BIN_DST is NOT in PATH — add to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "== 4/7 herdr ↔ Claude Code integration =="
# The SessionStart hook reports session_id and transcript to herdr — without it `hive revive` does not work.
[ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak-$STAMP"
herdr integration install claude >/dev/null 2>&1 || die "herdr integration install claude failed"
herdr integration status 2>/dev/null | grep -q '^claude: current' \
  && ok "claude integration active (settings.json backup: settings.json.bak-$STAMP)" \
  || die "claude integration does not report as active"

echo "== 5/7 Coordinator Stop hook =="
# The level-triggered backstop for lost wake-ups: the registered coordinator session
# cannot end a turn while unread mail sits in mail/coord. The hook self-scopes to the
# coord.pane session (drones and unrelated sessions exit instantly), so it is safe
# to install into the user's global settings.
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-hook-$STAMP"
HOOK_RESULT=$(python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd = 'bash "$HOME/.claude/skills/hivemind/coord-mail-check.sh"'
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
stop = data.setdefault("hooks", {}).setdefault("Stop", [])
present = any(h.get("command") == cmd
              for grp in stop for h in grp.get("hooks", []))
if present:
    print("present")
else:
    stop.append({"matcher": "*",
                 "hooks": [{"type": "command", "timeout": 15, "command": cmd}]})
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("added")
PY
) || die "failed to update $SETTINGS (backup: $SETTINGS.bak-hook-$STAMP)"
case "$HOOK_RESULT" in
  added)   ok "Stop hook added to $SETTINGS (backup: settings.json.bak-hook-$STAMP)" ;;
  present) ok "Stop hook already present — skipping" ;;
esac

echo "== 6/7 CLAUDE.md entry =="
CMD_FILE="$HOME/.claude/CLAUDE.md"
MARKER="## Hivemind — commanding a swarm of agents in herdr"
MARKER_PL="## Hivemind — dowodzenie rojem agentów w herdr"   # pre-translation installs
if [ -f "$CMD_FILE" ] && { grep -qF "$MARKER" "$CMD_FILE" || grep -qF "$MARKER_PL" "$CMD_FILE"; }; then
  ok "Hivemind section already present — skipping"
else
  [ -f "$CMD_FILE" ] && cp "$CMD_FILE" "$CMD_FILE.bak-$STAMP"
  { [ -f "$CMD_FILE" ] && echo; cat "$SRC/CLAUDE-md-snippet.md"; } >> "$CMD_FILE"
  ok "Hivemind section appended to $CMD_FILE"
fi

echo "== 7/7 Verification =="
bash -n "$SKILL_DST/hive"                || die "hive: syntax error"
bash -n "$SKILL_DST/drone-ping.sh"       || die "drone-ping.sh: syntax error"
bash -n "$SKILL_DST/coord-mail-check.sh" || die "coord-mail-check.sh: syntax error"
python3 -c "import json;json.load(open('$SKILL_DST/drone-settings.json'))" || die "drone-settings.json: invalid JSON"
"$SKILL_DST/hive" >/dev/null        || die "hive does not start"
ok "syntax and JSON valid"
mkdir -p "$HOME/.herdr-hive/drones" "$HOME/.herdr-hive/mail"
ok "swarm directories ready"

cat <<EOF

Installed. Smoke test (requires a running herdr server):

  hive coord
  hive spawn testdrone
  hive task testdrone - <<'BRIEF'
  # Brief: testdrone
  Count the files in the home directory and report the number. Boundaries: read-only.
  BRIEF
  # do not poll — wait until the drone sends HIVE-MAIL on its own, then:
  hive inbox && hive report testdrone && hive kill testdrone --purge

Full manual and traps: $SKILL_DST/SKILL.md
EOF

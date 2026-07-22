#!/usr/bin/env bash
# install.sh — instaluje hivemind (rój agentów Claude Code w herdr) na tej maszynie.
# Idempotentny: można puszczać wielokrotnie. Nic nie nadpisuje bez backupu.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DST="$HOME/.claude/skills/hivemind"
BIN_DST="$HOME/.local/bin"
STAMP="$(date +%Y%m%d-%H%M%S)"

ok()   { echo "  ✓ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "BŁĄD: $*" >&2; exit 1; }

echo "== 1/6 Wymagania =="
command -v herdr  >/dev/null || die "brak herdr — zainstaluj z https://herdr.dev i uruchom ponownie"
command -v claude >/dev/null || die "brak claude (Claude Code CLI)"
command -v python3 >/dev/null || die "brak python3"
command -v flock  >/dev/null || die "brak flock (pakiet util-linux)"
ok "herdr $(herdr --version 2>/dev/null | awk '{print $2}')"
ok "claude $(claude --version 2>/dev/null | awk '{print $1}')"
HERDR_MAJOR_MINOR=$(herdr --version 2>/dev/null | awk '{print $2}' | cut -d. -f1,2)
[ "$HERDR_MAJOR_MINOR" = "0.7" ] || warn "testowane na herdr 0.7.x — przy innej wersji sprawdź sekcję 'Kruczki herdr' w SKILL.md"

echo "== 2/6 Pliki skilla =="
mkdir -p "$SKILL_DST"
for f in hive drone-ping.sh drone-settings.json SKILL.md; do
  if [ -e "$SKILL_DST/$f" ] && ! cmp -s "$SRC/skill/$f" "$SKILL_DST/$f"; then
    cp "$SKILL_DST/$f" "$SKILL_DST/$f.bak-$STAMP"
    warn "istniejący $f zarchiwizowany jako $f.bak-$STAMP"
  fi
  cp "$SRC/skill/$f" "$SKILL_DST/$f"
done
chmod +x "$SKILL_DST/hive" "$SKILL_DST/drone-ping.sh"
ok "skill w $SKILL_DST"

echo "== 3/6 hive w PATH =="
mkdir -p "$BIN_DST"
ln -sf "$SKILL_DST/hive" "$BIN_DST/hive"
ok "symlink $BIN_DST/hive"
case ":$PATH:" in
  *":$BIN_DST:"*) ok "$BIN_DST jest w PATH" ;;
  *) warn "$BIN_DST NIE jest w PATH — dodaj do ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "== 4/6 Integracja herdr ↔ Claude Code =="
# Hook SessionStart melduje herdrowi session_id i transkrypt — bez tego nie działa `hive revive`.
[ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak-$STAMP"
herdr integration install claude >/dev/null 2>&1 || die "herdr integration install claude nie przeszło"
herdr integration status 2>/dev/null | grep -q '^claude: current' \
  && ok "integracja claude aktywna (backup settings.json: settings.json.bak-$STAMP)" \
  || die "integracja claude nie zgłasza się jako aktywna"

echo "== 5/6 Wpis w CLAUDE.md =="
CMD_FILE="$HOME/.claude/CLAUDE.md"
MARKER="## Hivemind — dowodzenie rojem agentów w herdr"
if [ -f "$CMD_FILE" ] && grep -qF "$MARKER" "$CMD_FILE"; then
  ok "sekcja Hivemind już obecna — pomijam"
else
  [ -f "$CMD_FILE" ] && cp "$CMD_FILE" "$CMD_FILE.bak-$STAMP"
  { [ -f "$CMD_FILE" ] && echo; cat "$SRC/CLAUDE-md-snippet.md"; } >> "$CMD_FILE"
  ok "sekcja Hivemind dopisana do $CMD_FILE"
fi

echo "== 6/6 Weryfikacja =="
bash -n "$SKILL_DST/hive"           || die "hive: błąd składni"
bash -n "$SKILL_DST/drone-ping.sh"  || die "drone-ping.sh: błąd składni"
python3 -c "import json;json.load(open('$SKILL_DST/drone-settings.json'))" || die "drone-settings.json: niepoprawny JSON"
"$SKILL_DST/hive" >/dev/null        || die "hive nie startuje"
ok "składnia i JSON poprawne"
mkdir -p "$HOME/.herdr-hive/drones" "$HOME/.herdr-hive/mail"
ok "katalogi roju gotowe"

cat <<EOF

Zainstalowane. Test dymny (wymaga działającego serwera herdr):

  hive coord
  hive spawn testowy
  hive task testowy - <<'BRIEF'
  # Brief: testowy
  Napisz ile plików jest w katalogu domowym. Granice: tylko odczyt.
  BRIEF
  # nie pollinguj — poczekaj aż dron sam przyśle HIVE-MAIL, potem:
  hive inbox && hive report testowy && hive kill testowy --purge

Pełna instrukcja i pułapki: $SKILL_DST/SKILL.md
EOF

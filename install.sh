#!/bin/zsh
# Sets up git-drive-backup on this Mac. Safe to run again: it replaces its own
# scheduled jobs and creates folders, and it never deletes anything you made.
#
#   zsh install.sh            install and start
#   zsh install.sh --check    check the machine is ready, change nothing
set -u
ROOT="${0:A:h}"
CONF="${GDB_CONFIG:-$ROOT/config.env}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

ok()   { print -P "  %F{green}OK%f    $1"; }
bad()  { print -P "  %F{red}STOP%f  $1"; FAIL=1; }
warn() { print -P "  %F{yellow}NOTE%f  $1"; }
FAIL=0

echo "Checking this machine"
[ "$(uname)" = "Darwin" ] && ok "macOS" || bad "This installer is macOS only. The scripts themselves are plain git and python."
command -v git  >/dev/null && ok "git $(git --version | awk '{print $3}')" || bad "git is missing. Install Xcode command line tools: xcode-select --install"
command -v python3 >/dev/null && ok "python3 $(python3 -V | awk '{print $2}')" || bad "python3 is missing."
if command -v gh >/dev/null; then
  if gh auth status >/dev/null 2>&1; then ok "GitHub CLI signed in as $(gh api user -q .login 2>/dev/null)"
  else bad "GitHub CLI is installed but not signed in. Run: gh auth login"; fi
else
  bad "GitHub CLI is missing. Install it: brew install gh"
fi

if [ ! -f "$CONF" ]; then
  bad "No settings file at $CONF. Copy config.env.example to config.env and edit it first."
else
  source "$ROOT/bin/config.sh"
  if [ -d "$(dirname "$CLOUD_DIR")" ]; then ok "cloud folder's parent exists: $(dirname "$CLOUD_DIR")"
  else bad "CLOUD_DIR points somewhere that is not there: $CLOUD_DIR"; fi
  FREE=$(df -g "$HOME" | awk 'NR==2{print $4}')
  [ "$FREE" -ge "$MIN_FREE_GB" ] && ok "${FREE}GB free on this disk" || warn "only ${FREE}GB free, MIN_FREE_GB is ${MIN_FREE_GB}"
  if lsof -nP -iTCP:"$DASH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "port $DASH_PORT is already in use. Change DASH_PORT in config.env, or stop the other program."
  else ok "port $DASH_PORT is free"; fi
fi

[ "$FAIL" -eq 1 ] && { echo; echo "Fix the STOP lines above, then run this again."; exit 1; }
[ "$CHECK" -eq 1 ] && { echo; echo "Ready. Run: zsh install.sh"; exit 0; }

echo
echo "Making folders"
mkdir -p "$MIRRORS" "$STATE" "$LOGDIR" "$PROOFS" "$TESTDIR" "$CLOUD_DIR"
ok "$DATA_DIR"
ok "$CLOUD_DIR"

if [ ! -f "$STATE/restore-rotation.txt" ]; then
  cp "$ROOT/examples/restore-rotation.txt" "$STATE/restore-rotation.txt"
  echo 0 > "$STATE/restore-rotation.pos"
  warn "wrote an example rotation list to $STATE/restore-rotation.txt. Put your own repos in it."
else
  ok "rotation list already there, left alone"
fi

echo
echo "Installing the scheduled jobs"
LA="$HOME/Library/LaunchAgents"
mkdir -p "$LA"
for pair in backup-daily:daily backup-weekly:weekly restore-test:restore-test dashboard:dashboard; do
  TMPL="${pair%%:*}"; SUF="${pair##*:}"
  OUT="$LA/$LABEL_PREFIX.$SUF.plist"
  sed -e "s|@@LABEL@@|$LABEL_PREFIX|g" -e "s|@@ROOT@@|$ROOT|g" -e "s|@@LOGDIR@@|$LOGDIR|g" \
      "$ROOT/launchd/$TMPL.plist.tmpl" > "$OUT"
  launchctl bootout "gui/$UID/$LABEL_PREFIX.$SUF" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$OUT" 2>/dev/null && ok "$LABEL_PREFIX.$SUF" || bad "could not load $OUT"
done

echo
echo "Done. What happens next:"
echo "  Dashboard      http://localhost:$DASH_PORT   (starts now, stays running)"
echo "  First backup   tonight at 02:30, or start one yourself:  zsh $ROOT/bin/backup.sh"
echo "  Restore test   Sunday 05:00, one repo a week from $STATE/restore-rotation.txt"
echo
echo "Nothing is ever deleted from $CLOUD_DIR by this tool."

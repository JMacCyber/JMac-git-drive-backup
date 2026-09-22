#!/usr/bin/env zsh
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
case "$(uname)" in
  Darwin) ok "macOS, jobs will run on launchd" ;;
  Linux)  if command -v systemctl >/dev/null; then ok "Linux, jobs will run on systemd user timers"
          else warn "Linux without systemctl. The scripts run by hand, but nothing will be scheduled."; fi ;;
  *)      warn "$(uname) is not a platform this installer schedules. The scripts may still run by hand." ;;
esac
command -v zsh >/dev/null && ok "zsh $(zsh --version | awk '{print $2}')" || bad "zsh is missing. On Debian or Ubuntu: sudo apt-get install zsh"
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
  FREE=$(gdb_free_gb "$HOME")
  [ "$FREE" -ge "$MIN_FREE_GB" ] && ok "${FREE}GB free on this disk" || warn "only ${FREE}GB free, MIN_FREE_GB is ${MIN_FREE_GB}"
  if gdb_port_busy "$DASH_PORT"; then
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
if [ "$GDB_OS" = "Darwin" ]; then
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
elif [ "$GDB_OS" = "Linux" ]; then
  # systemd user units, not system units. Nothing here needs root, and nothing
  # here runs as another user.
  UD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UD"
  PY3=$(command -v python3)
  for f in "$ROOT"/systemd/*.tmpl; do
    base="${f##*/}"; base="${base%.tmpl}"          # e.g. daily.service
    OUT="$UD/$LABEL_PREFIX.$base"
    sed -e "s|@@ROOT@@|$ROOT|g" -e "s|@@LOGDIR@@|$LOGDIR|g" -e "s|@@PYTHON@@|$PY3|g" "$f" > "$OUT"
  done
  systemctl --user daemon-reload 2>/dev/null || true
  for u in daily.timer weekly.timer restore-test.timer dashboard.service; do
    systemctl --user enable --now "$LABEL_PREFIX.$u" >/dev/null 2>&1 \
      && ok "$LABEL_PREFIX.$u" || bad "could not enable $LABEL_PREFIX.$u"
  done
  warn "timers only run while you are logged in. To keep them running after logout: loginctl enable-linger $USER"
else
  warn "no scheduler for $GDB_OS. The scripts still run by hand:"
  warn "  zsh $ROOT/bin/backup.sh        and        zsh $ROOT/bin/restore-test.sh"
fi

echo "Done. What happens next:"
echo "  Dashboard      http://localhost:$DASH_PORT   (starts now, stays running)"
echo "  First backup   tonight at 02:30, or start one yourself:  zsh $ROOT/bin/backup.sh"
echo "  Restore test   Sunday 05:00, one repo a week from $STATE/restore-rotation.txt"
echo
echo "Nothing is ever deleted from $CLOUD_DIR by this tool."

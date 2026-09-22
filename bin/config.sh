#!/usr/bin/env zsh
# Loads config.env and exports every path the other scripts use.
# Every script sources this one. Nothing else reads config.env, so there is one
# place a setting can be wrong, not four.
#
#   source bin/config.sh          in a script
#   zsh bin/config.sh --json      prints the resolved settings, used by dashboard.py
set -u
GDB_ROOT="${GDB_ROOT:-${0:A:h:h}}"
CONF="${GDB_CONFIG:-$GDB_ROOT/config.env}"
if [ ! -f "$CONF" ]; then
  echo "No config.env. Copy config.env.example to config.env and edit it." >&2
  exit 78   # EX_CONFIG
fi
source "$CONF"

: "${CLOUD_DIR:?CLOUD_DIR is not set in config.env}"
: "${DATA_DIR:=$HOME/.git-drive-backup}"
: "${GH_AFFILIATION:=owner}"
: "${MIN_FREE_GB:=8}"
: "${DASH_PORT:=3070}"
: "${PREVIEW_PORT_FROM:=3071}"
: "${PREVIEW_PORT_TO:=3080}"
: "${LABEL_PREFIX:=com.gitdrivebackup}"

export GDB_ROOT CLOUD_DIR DATA_DIR GH_AFFILIATION MIN_FREE_GB
export DASH_PORT PREVIEW_PORT_FROM PREVIEW_PORT_TO LABEL_PREFIX
export MIRRORS="$DATA_DIR/mirrors"
export STATE="$DATA_DIR/state"
export LOGDIR="$DATA_DIR/logs"
export PROOFS="$DATA_DIR/proofs"
export DASHDIR="$DATA_DIR/dashboard"
export TESTDIR="$DASHDIR/tests"

# --- portable helpers -------------------------------------------------------
# macOS ships BSD tools, Linux ships GNU ones, and the two disagree on the flags
# for exactly the four things this tool needs. Each helper tries the BSD form and
# falls back to the GNU form, so every other script can stop caring which Mac or
# Linux it is on.
export GDB_OS="$(uname)"

gdb_size()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }          # bytes
gdb_mtime() { stat -f '%Sm' "$1" 2>/dev/null || stat -c '%y' "$1" | cut -d. -f1; }
gdb_free_gb() { df -Pk "$1" | awk 'NR==2{printf "%d", $4/1048576}'; }    # -Pk is POSIX
gdb_port_busy() {   # exit 0 when something is already listening on the port
  python3 -c "import socket,sys
s=socket.socket(); s.settimeout(0.3)
r=s.connect_ex(('127.0.0.1', int(sys.argv[1]))); s.close()
sys.exit(0 if r == 0 else 1)" "$1"
}

if [ "${1:-}" = "--json" ]; then
  python3 -c "
import json, os
k = '''GDB_OS GDB_ROOT CLOUD_DIR DATA_DIR GH_AFFILIATION MIN_FREE_GB DASH_PORT
PREVIEW_PORT_FROM PREVIEW_PORT_TO LABEL_PREFIX MIRRORS STATE LOGDIR PROOFS
DASHDIR TESTDIR'''.split()
print(json.dumps({x: os.environ.get(x, '') for x in k}))"
fi

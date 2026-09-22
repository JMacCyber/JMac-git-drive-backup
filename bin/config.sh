#!/bin/zsh
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

if [ "${1:-}" = "--json" ]; then
  python3 -c "
import json, os
k = '''GDB_ROOT CLOUD_DIR DATA_DIR GH_AFFILIATION MIN_FREE_GB DASH_PORT
PREVIEW_PORT_FROM PREVIEW_PORT_TO LABEL_PREFIX MIRRORS STATE LOGDIR PROOFS
DASHDIR TESTDIR'''.split()
print(json.dumps({x: os.environ.get(x, '') for x in k}))"
fi

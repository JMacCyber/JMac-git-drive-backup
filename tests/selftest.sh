#!/usr/bin/env zsh
# Proves the whole chain on this machine, start to finish, without touching
# GitHub or any real backup. Exits 0 only if every step passed.
#
#   zsh tests/selftest.sh
#
# It builds a throwaway repo, bundles it, rebuilds it from that bundle alone,
# serves the rebuilt copy, opens the dashboard, approves the test, and checks
# the preview stopped and the temporary copy was removed.
#
# It never deletes its scratch folder. A failed run is worth reading, and the
# folder sits under the system temp directory, which the machine clears itself.
set -u
ROOT="${0:A:h:h}"
T=$(mktemp -d "${TMPDIR:-/tmp}/gdb-selftest.XXXXXX")
PASS=0; FAIL=0
say()  { printf '  %-34s %s  %s\n' "$1" "$2" "${3:-}" }
ok()   { PASS=$((PASS+1)); say "$1" "PASS" "${2:-}" }
bad()  { FAIL=$((FAIL+1)); say "$1" "FAIL" "${2:-}" }
want() { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "expected $3, got $2" }

stop_all() {
  [ -n "${DASH_PID:-}" ] && kill "$DASH_PID" 2>/dev/null
  [ -n "${PREV_PID:-}" ] && kill "$PREV_PID" 2>/dev/null
  return 0
}
trap stop_all EXIT

echo "git-drive-backup self test"
echo "  repo      $ROOT"
echo "  scratch   $T"
echo "  platform  $(uname) $(uname -m), zsh $(zsh --version | awk '{print $2}'), python $(python3 -V | awk '{print $2}')"
echo

# --- 1. settings load, and the helpers agree with the platform
mkdir -p "$T"/cloud/full "$T"/cloud/inc "$T"/data/state
DP=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
PP=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
cat > "$T/config.env" <<EOF
CLOUD_DIR="$T/cloud"
DATA_DIR="$T/data"
GH_AFFILIATION="owner"
MIN_FREE_GB=1
DASH_PORT=$DP
PREVIEW_PORT_FROM=$PP
PREVIEW_PORT_TO=$((PP + 8))
LABEL_PREFIX="com.gitdrivebackup.selftest"
EOF
export GDB_CONFIG="$T/config.env"
source "$ROOT/bin/config.sh"
[ "$CLOUD_DIR" = "$T/cloud" ] && ok "Settings Load" "$CLOUD_DIR" || bad "Settings Load" "$CLOUD_DIR"

echo "hello" > "$T/probe"
want "Helper gdb_size" "$(gdb_size "$T/probe")" "6"
[ -n "$(gdb_mtime "$T/probe")" ] && ok "Helper gdb_mtime" || bad "Helper gdb_mtime" "empty"
[ "$(gdb_free_gb "$HOME")" -ge 0 ] 2>/dev/null && ok "Helper gdb_free_gb" "$(gdb_free_gb "$HOME")GB" || bad "Helper gdb_free_gb"
gdb_port_busy 1 && bad "Helper gdb_port_busy" "said port 1 is busy" || ok "Helper gdb_port_busy"

# --- 2. a throwaway repo, bundled the way the backup writes them
S="$T/src"; mkdir -p "$S/out"
git init -q -b main "$S"
printf '<!doctype html><h1>Rebuilt</h1><p>one</p>\n' > "$S/out/index.html"
printf '# demo\n' > "$S/README.md"
git -C "$S" add -A
git -C "$S" -c user.email=t@e.x -c user.name=t commit -qm first
printf '<!doctype html><h1>Rebuilt</h1><p>two</p>\n' > "$S/out/index.html"
git -C "$S" add -A
git -C "$S" -c user.email=t@e.x -c user.name=t commit -qm second
git -C "$S" tag -a v1 -m v1
git -C "$S" bundle create -q "$T/cloud/full/acme__demo.bundle" --all
git clone -q --mirror "$S" "$MIRRORS/acme__demo.git"
echo "acme/demo" > "$STATE/restore-rotation.txt"
[ -s "$T/cloud/full/acme__demo.bundle" ] && ok "Bundle Written" || bad "Bundle Written"

# --- 3. the restore test itself
zsh "$ROOT/bin/restore-test.sh" > "$T/restore.log" 2>&1
want "Restore Test Exit" "$?" "0"
TID=$(ls "$TESTDIR" 2>/dev/null | head -1 | sed 's/\.json$//')
[ -n "$TID" ] && ok "Test Record Written" "$TID" || { bad "Test Record Written"; tail -20 "$T/restore.log"; echo; echo "  $PASS passed, $FAIL failed"; exit 1; }

python3 - "$TESTDIR/$TID.json" <<'PY' > "$T/facts"
import json, sys
d = json.load(open(sys.argv[1]))
ck = {c["name"]: c["result"] for c in d["checks"]}
print(d["verdict"])
print(ck.get("Recursive Diff"))
print(ck.get("Branches And Tags"))
print(ck.get("Preview Served"))
print((d.get("preview") or {}).get("port") or "")
PY
want "Verdict"           "$(sed -n 1p "$T/facts")" "Passed"
want "Recursive Diff"    "$(sed -n 2p "$T/facts")" "Passed"
want "Branches And Tags" "$(sed -n 3p "$T/facts")" "Passed"
want "Preview Served"    "$(sed -n 4p "$T/facts")" "Passed"
PREV_PORT=$(sed -n 5p "$T/facts")

WS="/tmp/restore-test-$TID"
[ -d "$WS" ] && ok "Restored Copy Kept" "$WS" || bad "Restored Copy Kept" "already gone"
PREV_PID=$(cat "$WS/preview.pid" 2>/dev/null || echo "")

# --- 4. the preview really serves the rebuilt files
BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PREV_PORT/" 2>/dev/null)
case "$BODY" in (*"<p>two</p>"*) ok "Preview Serves Rebuilt File" ;;
                (*)              bad "Preview Serves Rebuilt File" "got: ${BODY:0:40}" ;; esac

# --- 5. the dashboard
python3 "$ROOT/bin/dashboard.py" > "$T/dash.log" 2>&1 &
DASH_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$DASH_PORT/" && break
  sleep 0.5
done
for p in / /tests "/test/$TID" /repos /runs /logs /about; do
  want "Page $p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$DASH_PORT$p")" "200"
done
curl -s --max-time 5 "http://127.0.0.1:$DASH_PORT/test/$TID" | grep -q "Open The Rebuilt Site" \
  && ok "Preview Link On Page" || bad "Preview Link On Page"

# --- 6. approval stops the preview and removes that one folder
curl -s -o /dev/null -X POST -d "id=$TID" --max-time 10 "http://127.0.0.1:$DASH_PORT/approve"
sleep 1
[ -d "$WS" ] && bad "Approval Removed The Copy" "still there" || ok "Approval Removed The Copy"
if [ -n "$PREV_PID" ] && kill -0 "$PREV_PID" 2>/dev/null; then
  bad "Approval Stopped The Preview" "pid $PREV_PID alive"
else
  ok "Approval Stopped The Preview"
fi
python3 - "$TESTDIR/$TID.json" <<'PY' > "$T/after"
import json, sys
d = json.load(open(sys.argv[1]))
print((d.get("approval") or {}).get("state"))
print((d.get("cleanup") or {}).get("state"))
print((d.get("preview") or {}).get("state"))
PY
want "Recorded Approval" "$(sed -n 1p "$T/after")" "Approved"
want "Recorded Cleanup"  "$(sed -n 2p "$T/after")" "Done"
want "Recorded Preview"  "$(sed -n 3p "$T/after")" "Stopped"

# --- 7. nothing in the cloud folder was removed
want "Cloud Folder Untouched" "$(ls "$T/cloud/full" | wc -l | tr -d ' ')" "1"

echo
echo "  $PASS passed, $FAIL failed"
echo "  scratch kept at $T"
[ "$FAIL" -eq 0 ] || exit 1

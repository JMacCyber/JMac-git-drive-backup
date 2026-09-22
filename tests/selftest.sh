#!/usr/bin/env bash
# Proves the whole chain on this machine, start to finish, without touching
# GitHub or any real backup. Exits 0 only if every step passed.
#
#   bash tests/selftest.sh
#
# It builds a throwaway repo, bundles it, rebuilds it from that bundle alone,
# serves the rebuilt copy, opens the dashboard, approves the test, and checks
# the preview stopped and the temporary copy was removed.
#
# It never deletes its scratch folder. A failed run is worth reading, and the
# folder sits under the system temp directory, which the machine clears itself.
set -u
: "${GDB_PYTHON:=$(command -v python3 || command -v python)}"   # before config.sh is sourced
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/gdb-selftest.XXXXXX")
PASS=0; FAIL=0
say()  { printf '  %-34s %s  %s\n' "$1" "$2" "${3:-}"; }
ok()   { PASS=$((PASS+1)); say "$1" "PASS" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); say "$1" "FAIL" "${2:-}"; }
want() { [ "$2" = "$3" ] && ok "$1" "$2" || bad "$1" "expected $3, got $2"; }

stop_all() {
  [ -n "${DASH_PID:-}" ] && kill "$DASH_PID" 2>/dev/null
  [ -n "${PREV_PID:-}" ] && kill "$PREV_PID" 2>/dev/null
  return 0
}
trap stop_all EXIT

echo "git-drive-backup self test"
echo "  repo      $ROOT"
echo "  scratch   $T"
echo "  platform  $(uname) $(uname -m), bash $BASH_VERSION, python $("$GDB_PYTHON" -V | awk '{print $2}')"
echo

# --- 1. settings load, and the helpers agree with the platform
mkdir -p "$T"/cloud/full "$T"/cloud/inc "$T"/data/state
DP=$("$GDB_PYTHON" -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
PP=$("$GDB_PYTHON" -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
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
bash "$ROOT/bin/restore-test.sh" > "$T/restore.log" 2>&1
want "Restore Test Exit" "$?" "0"
TID=$(ls "$TESTDIR" 2>/dev/null | head -1 | sed 's/\.json$//')
[ -n "$TID" ] && ok "Test Record Written" "$TID" || { bad "Test Record Written"; tail -20 "$T/restore.log"; echo; echo "  $PASS passed, $FAIL failed"; exit 1; }

"$GDB_PYTHON" - "$TESTDIR/$TID.json" <<'PY' > "$T/facts"
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

# Read it from the record, which is the path the dashboard will act on. The temp
# directory is /tmp on Linux, /var/folders/... on macOS and under AppData on Windows.
WS=$("$GDB_PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))['workspace'])" "$TESTDIR/$TID.json")
[ -d "$WS" ] && ok "Restored Copy Kept" "$WS" || bad "Restored Copy Kept" "already gone"
PREV_PID=$(cat "$WS/preview.pid" 2>/dev/null || echo "")   # windows process id on Windows

# --- 4. the preview really serves the rebuilt files
BODY=""
for i in $(seq 1 20); do   # a cold CI machine can take a few seconds to answer
  BODY=$(curl -s --max-time 5 "http://127.0.0.1:$PREV_PORT/" 2>/dev/null)
  [ -n "$BODY" ] && break
  sleep 1
done
case "$BODY" in
  *"<p>two</p>"*) ok  "Preview Serves Rebuilt File" ;;
  *)              bad "Preview Serves Rebuilt File" "got: ${BODY:0:40}" ;;
esac

# --- 5. the dashboard
"$GDB_PYTHON" "$ROOT/bin/dashboard.py" > "$T/dash.log" 2>&1 &
DASH_PID=$!
for i in $(seq 1 60); do
  curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$DASH_PORT/" && break
  sleep 1
done
for p in / /tests "/test/$TID" /repos /runs /logs /about; do
  want "Page $p" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$DASH_PORT$p")" "200"
done
curl -s --max-time 5 "http://127.0.0.1:$DASH_PORT/test/$TID" | grep -q "Open The Rebuilt Site" \
  && ok "Preview Link On Page" || bad "Preview Link On Page"

# --- 5b. the approval endpoint refuses what it should refuse, and the copy survives it
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "id=$TID" --max-time 5 \
  -H "Origin: http://evil.example" "http://127.0.0.1:$DASH_PORT/approve")
want "Cross Site Post Refused" "$CODE" "403"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "id=$TID" --max-time 5 \
  -H "Sec-Fetch-Site: cross-site" "http://127.0.0.1:$DASH_PORT/approve")
want "Cross Site Fetch Refused" "$CODE" "403"
[ -d "$WS" ] && ok "Refused Post Kept The Copy" || bad "Refused Post Kept The Copy" "copy was removed"
SENTINEL="$T/traversal-target.json"
echo '{"keep":"me"}' > "$SENTINEL"
curl -s -o /dev/null -X POST --max-time 5 \
  --data-urlencode "id=../../../..$T/traversal-target" "http://127.0.0.1:$DASH_PORT/approve"
grep -q '"keep"' "$SENTINEL" && ok "Traversal Id Refused" || bad "Traversal Id Refused" "file was rewritten"

# --- 6. approval stops the preview and removes that one folder
curl -s -o /dev/null -X POST -d "id=$TID" --max-time 10 "http://127.0.0.1:$DASH_PORT/approve"
sleep 1
[ -d "$WS" ] && bad "Approval Removed The Copy" "still there" || ok "Approval Removed The Copy"
# Ask the port, not the process table. The recorded id is a Windows one under Git Bash,
# which this shell cannot signal, and a dead port is the thing that actually matters.
if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PREV_PORT/" 2>/dev/null; then
  bad "Approval Stopped The Preview" "port $PREV_PORT still answers"
else
  ok "Approval Stopped The Preview"
fi
"$GDB_PYTHON" - "$TESTDIR/$TID.json" <<'PY' > "$T/after"
import json, sys
d = json.load(open(sys.argv[1]))
print((d.get("approval") or {}).get("state"))
print((d.get("cleanup") or {}).get("state"))
print((d.get("cleanup") or {}).get("why") or "")
print((d.get("preview") or {}).get("state"))
PY
want "Recorded Approval" "$(sed -n 1p "$T/after")" "Approved"
CLEAN=$(sed -n 2p "$T/after")
if [ "$CLEAN" = "Done" ]; then ok "Recorded Cleanup" "Done"
else bad "Recorded Cleanup" "expected Done, got $CLEAN: $(sed -n 3p "$T/after")"; fi
want "Recorded Preview"  "$(sed -n 4p "$T/after")" "Stopped"

# --- 7. nothing in the cloud folder was removed
want "Cloud Folder Untouched" "$(ls "$T/cloud/full" | wc -l | tr -d ' ')" "1"

echo
echo "  $PASS passed, $FAIL failed"
echo "  scratch kept at $T"
[ "$FAIL" -eq 0 ] || exit 1

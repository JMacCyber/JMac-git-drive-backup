#!/usr/bin/env bash
# Weekly restore test. Rebuilds ONE repo from its Google Drive bundle alone, then
# proves the rebuild against GitHub, and registers the result for a human to approve
# in the dashboard.
#
# It never writes to GitHub: it clones and nothing else.
# It never deletes the restored copy. Only an approval in the dashboard does that.
#
# Rotation: one repo per week, in order, from $STATE/restore-rotation.txt.
set -u
shopt -s nullglob

GDB_ROOT="${GDB_ROOT:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"}"
source "$GDB_ROOT/bin/config.sh"
DRIVE="$CLOUD_DIR"
ROT="$STATE/restore-rotation.txt"
POS="$STATE/restore-rotation.pos"
mkdir -p "$PROOFS" "$TESTDIR"

[ -s "$ROT" ] || { echo "no rotation list at $ROT, nothing to test"; exit 0; }

# --- pick this week's repo, then advance the position, so a crash never repeats one
LIST=()
while IFS= read -r line; do
  case "$line" in ''|\#*|' '*\#*) continue ;; esac
  LIST[${#LIST[@]}]="$line"
done < <(grep -v '^[[:space:]]*#' "$ROT" | grep -v '^[[:space:]]*$')
N=${#LIST[@]}
[ "$N" -gt 0 ] || { echo "rotation list is empty"; exit 0; }
P=$( [ -f "$POS" ] && cat "$POS" || echo 0 )
IDX=$(( P % N ))   # bash arrays start at 0
NWO="${LIST[$IDX]}"
echo $(( (P + 1) % N )) > "$POS"

SAFE="${NWO//\//__}"
NAME="${NWO##*/}"
STAMP=$(date +%Y%m%d-%H%M%S)
ID="$STAMP-$NAME"
GDB_TMP="${TMPDIR:-/tmp}"; GDB_TMP="${GDB_TMP%/}"   # macOS sets TMPDIR with a trailing /
WS="$GDB_TMP/restore-test-$ID"
LOG="$WS/test.log"
mkdir -p "$WS"
# The dashboard is native Python. Under Git Bash it cannot open a /tmp path, so the
# record carries the path in the form the dashboard's own OS understands.
WS_REC="$WS"
[ "$GDB_OS" = "Windows" ] && WS_REC=$(cygpath -w "$WS" 2>/dev/null || echo "$WS")
exec > >(tee -a "$LOG") 2>&1

echo "== restore test $ID =="
echo "repo:     $NWO"
echo "week:     position $P of $N, this is entry $IDX"
echo "bundle:   $DRIVE/full/$SAFE.bundle"

CHECKS="$WS/checks.tsv"   # name<TAB>result<TAB>detail
: > "$CHECKS"
ck() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CHECKS"; printf '  %-26s %-8s %s\n' "$1" "$2" "$3"; }

BUN="$DRIVE/full/$SAFE.bundle"
if [ ! -f "$BUN" ]; then
  ck "Bundle Present" "Failed" "no file at $BUN"
  BSIZE=0
else
  BSIZE=$(gdb_size "$BUN")
  ck "Bundle Present" "Passed" "$BSIZE bytes, written $(gdb_mtime "$BUN")"
fi

# --- 1. verify the bundle before trusting a single object in it
git init -q --bare "$WS/verify.git"
if git -C "$WS/verify.git" bundle verify "$BUN" > "$WS/verify.txt" 2>&1; then
  ck "Bundle Verify" "Passed" "$(grep -E 'contains [0-9]+ ref' "$WS/verify.txt" | head -1 | cut -c1-90)"
else
  ck "Bundle Verify" "Failed" "$(tail -1 "$WS/verify.txt" | cut -c1-90)"
fi

# --- 2. rebuild a bare repo from the bundle, then a working copy from that.
# A diff bundle cannot be fetched into a checked-out tree, so the bare clone comes first.
if git clone -q --mirror "$BUN" "$WS/$NAME.git" 2>"$WS/clone.err"; then
  ck "Rebuild From Bundle" "Passed" "$(git -C "$WS/$NAME.git" count-objects -v | tr '\n' ' ' | cut -c1-90)"
else
  ck "Rebuild From Bundle" "Failed" "$(tail -1 "$WS/clone.err" | cut -c1-90)"
fi

NINC=0
for b in "$DRIVE/inc/$SAFE"/*.bundle; do
  git -C "$WS/$NAME.git" fetch -q "$b" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' && NINC=$((NINC+1))
done
ck "Diff Bundles Applied" "Passed" "$NINC applied"

git clone -q "$WS/$NAME.git" "$WS/$NAME" 2>"$WS/co.err" \
  && ck "Working Copy" "Passed" "checked out $(git -C "$WS/$NAME" rev-parse --abbrev-ref HEAD)" \
  || ck "Working Copy" "Failed" "$(tail -1 "$WS/co.err" | cut -c1-90)"

# --- 3. a fresh clone straight from GitHub, to compare the rebuild against.
# If the token is not reachable from a launchd job, fall back to the local mirror and
# SAY SO in the check detail. A mirror comparison is weaker evidence than GitHub and
# must never be reported as if it were the same thing.
SRC=""
# The token is passed to this one git command and to nothing else. It used to be
# exported, which left it in the environment when npm ran the restored project's own
# install scripts. Restored code is not trusted code.
TOKEN=$(gh auth token 2>/dev/null)
if [ -n "$TOKEN" ]; then
  if GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper \
     GIT_CONFIG_VALUE_0="!f(){ echo username=x-access-token; echo password=$TOKEN; };f" \
     git clone -q "https://github.com/$NWO.git" "$WS/$NAME-source" 2>"$WS/src.err"; then
    SRC="GitHub"
    ck "Comparison Source" "Passed" "fresh clone from github.com/$NWO"
  fi
fi
if [ -z "$SRC" ] && [ -d "$MIRRORS/$SAFE.git" ]; then
  git clone -q "$MIRRORS/$SAFE.git" "$WS/$NAME-source" 2>>"$WS/src.err" && SRC="Local Mirror"
  ck "Comparison Source" "Amber" "GitHub unreachable from this job, compared against the local mirror instead, which is weaker evidence"
fi
[ -n "$SRC" ] || ck "Comparison Source" "Failed" "$(tail -1 "$WS/src.err" | cut -c1-90)"

cmp_ck() { # name  restored  source
  [ "$2" = "$3" ] && ck "$1" "Passed" "$2" || ck "$1" "Failed" "restored $2 vs $SRC $3"
}
if [ -n "$SRC" ]; then
  cmp_ck "HEAD Commit"  "$(git -C "$WS/$NAME" rev-parse HEAD)"         "$(git -C "$WS/$NAME-source" rev-parse HEAD)"
  cmp_ck "Root Tree"    "$(git -C "$WS/$NAME" rev-parse 'HEAD^{tree}')" "$(git -C "$WS/$NAME-source" rev-parse 'HEAD^{tree}')"
  cmp_ck "Commit Count" "$(git -C "$WS/$NAME" rev-list --count HEAD)"  "$(git -C "$WS/$NAME-source" rev-list --count HEAD)"

  man() { ( cd "$1" && find . -type f -not -path './.git/*' | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1 ); }
  cmp_ck "File Manifest sha256" "$(man "$WS/$NAME")" "$(man "$WS/$NAME-source")"

  FILES=$( cd "$WS/$NAME" && find . -type f -not -path './.git/*' | wc -l | tr -d ' ' )
  # python walks the tree the same way on every platform. find -exec stat differs
  # between BSD and GNU, and a wrong byte count here would be reported as evidence.
  BYTES=$( "$GDB_PYTHON" -c "
import os, sys
t = 0
for r, d, f in os.walk(sys.argv[1]):
    d[:] = [x for x in d if x != '.git']
    for n in f:
        p = os.path.join(r, n)
        if not os.path.islink(p): t += os.path.getsize(p)
print(t)" "$WS/$NAME" )
  ck "Working Tree Size" "Passed" "$FILES files, $BYTES bytes"

  if diff -r --exclude=.git "$WS/$NAME" "$WS/$NAME-source" > "$WS/tree.diff" 2>&1; then
    ck "Recursive Diff" "Passed" "every file byte for byte identical"
  else
    ck "Recursive Diff" "Failed" "$(wc -l < "$WS/tree.diff" | tr -d ' ') lines of difference, see tree.diff"
  fi

  # Refs. git ls-remote prints an extra refs/tags/X^{} line naming the commit an
  # annotated tag points at; show-ref does not. Strip those before counting, or a
  # repo with annotated tags looks short when nothing is missing.
  git -C "$WS/$NAME.git" show-ref | sort > "$WS/refs.restored"
  git -C "$WS/$NAME-source" ls-remote origin 2>/dev/null | grep -v 'HEAD$' | grep -v '\^{}$' \
    | awk '{print $1" "$2}' | sort > "$WS/refs.source"
  RR=$(grep -c . "$WS/refs.restored"); RS=$(grep -c . "$WS/refs.source")
  if diff -q "$WS/refs.restored" "$WS/refs.source" >/dev/null 2>&1; then
    ck "Branches And Tags" "Passed" "$RR refs, identical"
  else
    ck "Branches And Tags" "Amber" "restored $RR refs, $SRC $RS, see refs.diff"
    diff "$WS/refs.restored" "$WS/refs.source" > "$WS/refs.diff" 2>&1
  fi
fi

# --- 4. does the restored copy actually run? Identical files are not a working repo.
# macOS has no timeout command, so perl's alarm caps each step.
cap() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# Everything below runs code that came out of the bundle. Drop every credential this
# shell can see first. gh keeps its token in the login keychain, which any process
# running as this user can still ask for; that limit is stated in docs/HOW-IT-WORKS.md.
unset TOKEN GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_ASKPASS SSH_AUTH_SOCK
export GIT_TERMINAL_PROMPT=0 npm_config_audit=false npm_config_fund=false

R="$WS/$NAME"
if [ -f "$R/package.json" ]; then
  if cap 900 npm --prefix "$R" install --silent --no-audit --no-fund > "$WS/npm.log" 2>&1; then
    ck "Dependencies Install" "Passed" "$(grep -oE '[0-9]+ packages' "$WS/npm.log" | head -1)"
    if "$GDB_PYTHON" -c "import json,sys;sys.exit(0 if 'build' in (json.load(open('$R/package.json')).get('scripts') or {}) else 1)"; then
      cap 1800 npm --prefix "$R" run build > "$WS/build.log" 2>&1 \
        && ck "Project Builds" "Passed" "npm run build exit 0" \
        || ck "Project Builds" "Failed" "npm run build exit $?, see build.log"
    else
      ck "Project Builds" "Passed" "no build script, nothing to build"
    fi
  else
    ck "Dependencies Install" "Failed" "npm install exit $?, see npm.log"
  fi
elif [ -f "$R/pyproject.toml" ] || [ -f "$R/requirements.txt" ]; then
  if cap 600 "$GDB_PYTHON" -m compileall -q "$R" > "$WS/py.log" 2>&1; then
    ck "Python Compiles" "Passed" "every .py compiled"
  else
    ck "Python Compiles" "Failed" "see py.log"
  fi
else
  ck "Runnable Check" "Passed" "no package.json or python project, nothing to run"
fi

# --- 4b. serve the rebuilt project on localhost, so a human can click through it
# A checklist says the files match. A page you can open says the work came back.
#
# Static by default: "$GDB_PYTHON" -m http.server never executes the restored project's
# own code, so opening the preview cannot start anything on this machine. Set
# PREVIEW_RUN_CMD in config.env to run the project's own server instead, and read
# docs/HOW-IT-WORKS.md first: that choice runs code out of the backup.
PREV_PORT=""; PREV_PID=""; PREV_DIR=""; PREV_MODE=""
# The dashboard is the thing that later stops this server, and on Windows it is a
# native program while this script runs under Git Bash. The two number processes
# differently, so what gets recorded there is the Windows process id, which both can
# act on. Everywhere else the two are the same number.
gdb_write_pid() {
  local shell_pid="$1" file="$2" out="$1"
  if [ "$GDB_OS" = "Windows" ] && [ -r "/proc/$shell_pid/winpid" ]; then
    out=$(cat "/proc/$shell_pid/winpid")
  fi
  echo "$out" > "$file"
  echo "$shell_pid" > "$file.shell"
}
free_port() {
  local p
  for p in $(seq "$PREVIEW_PORT_FROM" "$PREVIEW_PORT_TO"); do
    gdb_port_busy "$p" || { echo "$p"; return 0; }
  done
  return 1
}
if [ "$(awk -F'\t' '$2=="Failed"' "$CHECKS" | wc -l | tr -d ' ')" -eq 0 ]; then
  PREV_PORT=$(free_port) || PREV_PORT=""
fi
if [ -n "$PREV_PORT" ]; then
  for d in out dist build public _site site; do
    [ -d "$R/$d" ] && { PREV_DIR="$R/$d"; break; }
  done
  [ -n "$PREV_DIR" ] || PREV_DIR="$R"
  if [ -n "${PREVIEW_RUN_CMD:-}" ]; then
    PREV_MODE="project server: $PREVIEW_RUN_CMD"
    GDB_NOHUP=nohup; [ "$GDB_OS" = "Windows" ] && GDB_NOHUP=""
    ( cd "$R" && PORT="$PREV_PORT" $GDB_NOHUP bash -lc "$PREVIEW_RUN_CMD" > "$WS/preview.log" 2>&1 & gdb_write_pid $! "$WS/preview.pid" )
  else
    PREV_MODE="static files from ${PREV_DIR##*/}"
    # Same stdlib server as "$GDB_PYTHON" -m http.server, minus one thing: its bind calls
    # socket.getfqdn() for a hostname it only prints in error pages, and that lookup
    # can stall the start for tens of seconds where reverse DNS is slow.
    # No nohup on Windows. There is no exec there, so nohup stays alive as the parent
    # and the recorded id would name nohup.exe rather than the server it started.
    GDB_NOHUP=nohup; [ "$GDB_OS" = "Windows" ] && GDB_NOHUP=""
    $GDB_NOHUP "$GDB_PYTHON" -c '
import sys, socketserver
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
class S(ThreadingHTTPServer):
    allow_reuse_address = True
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
S(("127.0.0.1", int(sys.argv[1])),
  partial(SimpleHTTPRequestHandler, directory=sys.argv[2])).serve_forever()
' "$PREV_PORT" "$PREV_DIR" > "$WS/preview.log" 2>&1 &
    gdb_write_pid $! "$WS/preview.pid"
  fi
  sleep 2
  PREV_PID=$(cat "$WS/preview.pid" 2>/dev/null || echo "")
  PREV_SHELL_PID=$(cat "$WS/preview.pid.shell" 2>/dev/null || echo "$PREV_PID")
  if [ -n "$PREV_SHELL_PID" ] && kill -0 "$PREV_SHELL_PID" 2>/dev/null; then
    ck "Preview Served" "Passed" "http://localhost:$PREV_PORT  ($PREV_MODE)"
  else
    ck "Preview Served" "Amber" "preview did not stay up, see preview.log"
    PREV_PORT=""; PREV_PID=""
  fi
else
  ck "Preview Served" "Amber" "not served: a check failed, or no free port in $PREVIEW_PORT_FROM-$PREVIEW_PORT_TO"
fi

# --- 5. verdict, evidence, and the record the dashboard reads
FAILED=$(awk -F'\t' '$2=="Failed"' "$CHECKS" | wc -l | tr -d ' ')
VERDICT=$( [ "$FAILED" -eq 0 ] && echo Passed || echo Failed )
WSB=$(du -sk "$WS" | awk '{print $1*1024}')
echo "verdict: $VERDICT ($FAILED failed checks), workspace $WSB bytes"

"$GDB_PYTHON" - "$ID" "$NWO" "$WS_REC" "$CHECKS" "$VERDICT" "$WSB" "$BUN" "$BSIZE" "$SRC" "$LOG" "$PREV_PORT" "$PREV_PID" "$PREV_MODE" <<'PY'
import json, os, sys, datetime, html
tid, nwo, ws, ckf, verdict, wsb, bun, bsize, src, logp = sys.argv[1:11]
pport, ppid, pmode = (sys.argv[11:14] + ["", "", ""])[:3]
checks = []
for line in open(ckf):
    p = line.rstrip("\n").split("\t")
    if len(p) == 3:
        checks.append({"name": p[0], "result": p[1], "detail": p[2]})
now = datetime.datetime.now().isoformat(timespec="seconds")
ev = "restore-test-%s.html" % tid
e = html.escape
rows = "".join(
    '<tr><td>%s</td><td class="%s">%s</td><td class="m">%s</td></tr>'
    % (e(c["name"]), c["result"], c["result"], e(c["detail"])) for c in checks)
open(os.path.join(os.environ["PROOFS"], ev), "w").write("""<!doctype html><meta charset="utf-8">
<title>Restore Test %s</title><style>
body{font:14px/1.6 -apple-system,system-ui,sans-serif;margin:34px;max-width:980px;color:#1a1d21}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:26px 0 8px}
.sub{color:#666;font-size:13px}table{border-collapse:collapse;width:100%%;margin-top:6px}
th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:#666;
border-bottom:2px solid #ddd;padding:7px 9px}td{border-bottom:1px solid #eee;padding:7px 9px;font-size:13px}
.m{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:#444}
.Passed{color:#15803d;font-weight:600}.Failed{color:#b91c1c;font-weight:600}.Amber{color:#a16207;font-weight:600}
.box{background:#f6f7f9;border:1px solid #e3e6ea;border-radius:8px;padding:12px 16px;margin-top:10px}
</style>
<h1>Restore Test &mdash; %s</h1>
<div class="sub">%s &middot; verdict <span class="%s">%s</span> &middot; compared against %s</div>
<div class="box"><b>What this proves.</b> The repo below was rebuilt from its cloud-folder bundle alone,
with no access to the original checkout, then compared against %s file by file and ref by ref.<br>
<b>What it does not prove.</b> It says this one bundle rebuilt this one repo on this machine today.
It says nothing about the other bundles, and nothing about a machine without git and node.</div>
<h2>Source</h2><table>
<tr><th>Item</th><th>Value</th></tr>
<tr><td>Repo</td><td class="m">%s</td></tr>
<tr><td>Bundle</td><td class="m">%s</td></tr>
<tr><td>Bundle size</td><td class="m">%s bytes</td></tr>
<tr><td>Restored to</td><td class="m">%s</td></tr>
<tr><td>Finished</td><td class="m">%s</td></tr></table>
<h2>Checks</h2><table><tr><th>Check</th><th>Result</th><th>What Was Measured</th></tr>%s</table>
<h2>How To Repeat This By Hand</h2>
<pre class="m">V=$(mktemp -d)
git init --bare "$V/v.git" &amp;&amp; git -C "$V/v.git" bundle verify '%s'
git clone --mirror '%s' "$V/r.git" &amp;&amp; git clone "$V/r.git" "$V/r"
echo "the rebuilt copy is in $V/r"</pre>
<p class="muted">A fresh folder each time, so running this twice never collides with the run before.</p>
""" % (e(tid), e(nwo), e(now), verdict, verdict, e(src or "nothing"), e(src or "nothing"),
       e(nwo), e(bun), e(bsize), e(ws), e(now), rows, e(bun), e(bun)))

try:
    log = open(logp, errors="replace").read()
except OSError:
    log = ""
rec = {"id": tid, "repo": nwo, "finished": now, "bundle": bun, "bundleBytes": int(bsize or 0),
       "comparedAgainst": src, "checks": checks, "verdict": verdict,
       "workspace": ws, "workspaceBytes": int(wsb), "evidence": ev,
       "preview": {"port": int(pport) if pport else None,
                   "pid": int(ppid) if ppid else None,
                   "mode": pmode,
                   "url": ("http://localhost:%s/" % pport) if pport else None,
                   "state": "Running" if pport else "Not Served"},
       "approval": {"state": "Pending", "at": None, "by": None},
       "cleanup": {"state": "Pending", "at": None, "freedBytes": 0}, "log": log[-20000:]}
json.dump(rec, open(os.path.join(os.environ["TESTDIR"], "%s.json" % tid), "w"), indent=1)
print("record written, evidence at " + os.path.join(os.environ["PROOFS"], ev))
print("approve or reject at http://localhost:%s/test/%s" % (os.environ.get("DASH_PORT","3070"), tid))
PY

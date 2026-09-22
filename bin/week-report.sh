#!/usr/bin/env bash
# Reads the last 7 days of backup state and prints a plain-text report.
# Safe to run any time. It reads files and prints; it changes nothing.
# Deterministic on purpose: the Monday routine runs THIS and relays it, so the
# numbers come from the files, never from a model reading a dashboard page.
# Local files only. A launchd job cannot list the cloud folder, so nothing here
# touches it; see docs/WHY.md.
set -u
GDB_ROOT="${GDB_ROOT:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"}"
source "$GDB_ROOT/bin/config.sh"
export BK="$DATA_DIR"
"$GDB_PYTHON" - <<'PY'
import json, os, glob, datetime, subprocess

BK = os.environ["BK"]
LBL = os.environ.get("LABEL_PREFIX", "com.gitdrivebackup")
PORT = os.environ.get("DASH_PORT", "3070")
now = datetime.datetime.now()
out = []
def p(s=""): out.append(s)

def gb(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.2f} {u}" if u not in ("B", "KB") else f"{n:.0f} {u}"
        n /= 1024.0

def ago(iso):
    try:
        d = datetime.datetime.fromisoformat(iso)
    except Exception:
        return "unknown"
    h = (now - d).total_seconds() / 3600.0
    if h < 1:   return f"{int(h*60)} min ago"
    if h < 48:  return f"{h:.0f} h ago"
    return f"{h/24:.0f} days ago"

# --- runs in the last 7 days
runs = []
try:
    runs = json.load(open(os.path.join(BK, "dashboard", "history.json")))
except Exception as ex:
    p(f"HISTORY UNREADABLE: {ex}")

cut = now - datetime.timedelta(days=7)
recent = [r for r in runs if r.get("finished", "") >= cut.isoformat()]

p("BACKUP WEEK REPORT  " + now.strftime("%a %d %b %Y %H:%M"))
p("=" * 52)
p()
p(f"Runs in the last 7 days: {len(recent)}")
if not recent:
    p("  NONE. The daily 02:30 job has not completed in 7 days. This is Red.")
for r in recent:
    state = "Passed" if r.get("failed", 0) == 0 else "FAILED"
    p(f"  {r.get('finished','?')}  {state}  "
      f"{r.get('handled','?')} of {r.get('repos','?')} repos, "
      f"{r.get('failed','?')} failed, {gb(r.get('folderBytes',0))} on Drive")

last = runs[-1] if runs else None
if last:
    p()
    p(f"Last run: {ago(last.get('finished',''))}, "
      f"{last.get('fullBundles',0)} full bundles, {last.get('diffBundles',0)} diff bundles")
    if (now - datetime.datetime.fromisoformat(last["finished"])).total_seconds() > 48*3600:
        p("  OVERDUE: more than 48 h since the last completed run.")

# --- restore tests
p()
p("Restore tests")
tests = []
for f in sorted(glob.glob(os.path.join(BK, "dashboard", "tests", "*.json"))):
    try:
        tests.append(json.load(open(f)))
    except Exception:
        pass
if not tests:
    p("  No test records.")
pending = [t for t in tests if t.get("approval", {}).get("state") == "Pending"]
for t in tests[-4:]:
    p(f"  {t.get('id','?')}  {t.get('verdict','?')}  "
      f"approval {t.get('approval',{}).get('state','?')}  "
      f"copy {t.get('cleanup',{}).get('state','?')}")
p()
if pending:
    p(f"WAITING ON A HUMAN: {len(pending)} test(s) Pending approval.")
    for t in pending:
        ws = t.get("workspace") or ""
        sz = 0
        if ws and os.path.isdir(ws):
            for root, _, fs in os.walk(ws):
                for fn in fs:
                    try: sz += os.lstat(os.path.join(root, fn)).st_size
                    except OSError: pass
        p(f"  http://localhost:{PORT}/test/{t.get('id')}  "
          f"({gb(sz)} held in /tmp)" if sz else
          f"  http://localhost:{PORT}/test/{t.get('id')}")
else:
    p("Nothing waiting on a human.")

# --- next repo in the rotation
p()
try:
    rot = [l.strip() for l in open(os.path.join(BK, "state", "restore-rotation.txt"))
           if l.strip() and not l.startswith("#")]
    pos = int(open(os.path.join(BK, "state", "restore-rotation.pos")).read().strip() or 0)
    p(f"Next Sunday's restore test: {rot[pos % len(rot)]}  "
      f"(position {pos} of {len(rot)})")
except Exception as ex:
    p(f"Rotation unreadable: {ex}")

# --- launchd jobs
p()
p("Scheduled jobs")
try:
    ll = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout
except Exception as ex:
    ll = ""
    p(f"  launchctl unreadable: {ex}")
for label, what in ((LBL + ".daily", "daily 02:30"),
                    (LBL + ".weekly", "Sunday 03:30 full"),
                    (LBL + ".restore-test", "Sunday 05:00 test"),
                    (LBL + ".dashboard", f"dashboard :{PORT}")):
    row = [l for l in ll.splitlines() if l.endswith("\t" + label) or l.endswith(" " + label)]
    if not row:
        p(f"  {label:38s} NOT LOADED  ({what})")
        continue
    pid, ex, _ = row[0].split("\t", 2)
    # launchd prints "-" for a job that is not running right now, which is normal
    # for a timed job and must not be reported as a failure.
    if pid != "-":
        p(f"  {label:38s} running pid {pid}  ({what})")
    elif ex in ("0", "-"):
        p(f"  {label:38s} loaded, last exit 0  ({what})")
    else:
        p(f"  {label:38s} LAST EXIT {ex}  ({what})")

print("\n".join(out))
PY

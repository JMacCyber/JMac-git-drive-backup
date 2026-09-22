#!/usr/bin/env python3
"""Backup Control: the dashboard for git-drive-backup.

Reads ONLY local files under DATA_DIR. That is deliberate. A launchd job cannot
list a Google Drive folder at all, so anything that asked Drive "what is in here"
would render an empty page and look like a clean result. Every number here comes
from a file the backup job wrote on local disk.

Approvals are the point: a restored test copy is never deleted until it is
approved here, and the record of what was approved and when outlives the copy.
"""
import html, json, os, re, platform, shutil, subprocess, tempfile, time, urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load_config():
    """One source of settings for every part of this tool: config.env, read through
    bin/config.sh so the shell scripts and this server can never disagree."""
    # bash sits in a different place on each platform, and on Windows it comes from
    # Git for Windows, which is not always on PATH. Look in the usual places too.
    sh = shutil.which("bash") or next(
        (c for c in (r"C:\Program Files\Git\bin\bash.exe",
                     r"C:\Program Files (x86)\Git\bin\bash.exe",
                     "/bin/bash", "/usr/bin/bash") if os.path.exists(c)), "bash")
    out = subprocess.run([sh, os.path.join(ROOT, "bin", "config.sh"), "--json"],
                         capture_output=True, text=True, env={**os.environ, "GDB_ROOT": ROOT})
    if out.returncode != 0:
        raise SystemExit(out.stderr.strip() or "config.sh failed")
    return json.loads(out.stdout)

CFG = load_config()
OS = CFG.get("GDB_OS") or platform.system()
PORT = int(CFG["DASH_PORT"])
LABEL = CFG["LABEL_PREFIX"]
BK = CFG["DATA_DIR"]
STATE, LOGS, PROOFS = CFG["STATE"], CFG["LOGDIR"], CFG["PROOFS"]
MIRRORS = CFG["MIRRORS"]
DASH = CFG["DASHDIR"]
TESTS = CFG["TESTDIR"]
HISTORY = os.path.join(DASH, "history.json")
SIZES = os.path.join(STATE, "drive-sizes.tsv")
for d in (TESTS, PROOFS):
    os.makedirs(d, exist_ok=True)

def rj(p, d):
    try:
        return json.load(open(p))
    except Exception:
        return d

def runs():
    h = rj(HISTORY, [])
    return list(reversed(h)) if isinstance(h, list) else []

def sizes():
    out = {}
    try:
        for line in open(SIZES):
            p = line.strip()
            if p:
                try:
                    out[p] = os.path.getsize(p)
                except OSError:
                    out[p] = None
    except OSError:
        pass
    return out

def repos():
    by = {}
    for p, s in sizes().items():
        if not p.endswith(".bundle"):
            continue
        if "/full/" in p:
            by.setdefault(os.path.basename(p)[:-7], {})["full"] = (p, s)
        elif "/inc/" in p:
            by.setdefault(os.path.basename(os.path.dirname(p)), {}).setdefault("inc", []).append((p, s))
    try:
        names = sorted(f[:-5] for f in os.listdir(STATE) if f.endswith(".tips"))
    except OSError:
        names = []
    out = []
    for safe in names:
        d = by.get(safe, {})
        fp, fs = d.get("full", (None, None))
        inc = d.get("inc", [])
        tips = []
        try:
            tips = [l.split() for l in open(os.path.join(STATE, safe + ".tips")).read().split("\n") if l.strip()]
        except OSError:
            pass
        m = os.path.join(MIRRORS, safe + ".git")
        out.append({"safe": safe, "nwo": safe.replace("__", "/", 1), "full": fp, "fullBytes": fs,
                    "incCount": len(inc), "incBytes": sum(s for _, s in inc if s),
                    "refs": len(tips), "tips": tips, "mirror": m if os.path.isdir(m) else None})
    return out

def unbundled():
    """Repos GitHub lists that have no bundle, and why. A bare count that is short of
    the repo count reads like missing backups; a repo with no commits holds no objects,
    so there is nothing to bundle. Never let a gap sit on the page without its reason."""
    try:
        rl = sorted(f for f in os.listdir(LOGS) if f.startswith("repos-") and f.endswith(".json"))
    except OSError:
        return []
    if not rl:
        return []
    j = rj(os.path.join(LOGS, rl[-1]), [])
    try:
        have = {f[:-5] for f in os.listdir(STATE) if f.endswith(".tips")}
    except OSError:
        have = set()
    out = []
    for r in j:
        n = r.get("nameWithOwner", "")
        if n.replace("/", "__", 1) not in have:
            du = r.get("diskUsage") or 0
            out.append({"nwo": n, "kb": du,
                        "why": "No commits on GitHub, nothing to bundle" if du == 0
                               else "Has content but no bundle, investigate"})
    return out

def tests():
    try:
        return [t for t in (rj(os.path.join(TESTS, f), None)
                for f in sorted(os.listdir(TESTS), reverse=True) if f.endswith(".json")) if t]
    except OSError:
        return []

def logs():
    try:
        fs = [f for f in os.listdir(LOGS) if not f.startswith(".")]
    except OSError:
        return []
    fs.sort(key=lambda f: os.path.getmtime(os.path.join(LOGS, f)), reverse=True)
    return [{"name": f, "bytes": os.path.getsize(os.path.join(LOGS, f)),
             "when": os.path.getmtime(os.path.join(LOGS, f))} for f in fs]

def agent(label):
    """Is the scheduled job loaded, and what did it exit with last time?

    macOS keeps this in launchd, Linux in systemd, Windows in Task Scheduler. All
    three are asked the same question and answer in the same shape, so the page does
    not care which machine it is on. Anything else reports Not Loaded, which is
    honest: this tool only installs jobs on those three."""
    if OS == "Darwin":
        return _launchd(label)
    if OS == "Windows":
        return _schtasks(label)
    if OS == "Linux":
        return _systemd(label)
    return {"loaded": False, "exit": None}

def _schtasks(label):
    """Task Scheduler prints one Field: value per line. Status says whether the task
    is ready to run, Last Result is the exit code of the run before, and 267011 is
    its code for "has never run", which is reported as no result rather than as 0."""
    try:
        out = subprocess.run(["schtasks", "/query", "/tn", label, "/fo", "list", "/v"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return {"loaded": False, "exit": None}
    if out.returncode != 0:
        return {"loaded": False, "exit": None}
    f = {}
    for line in out.stdout.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            f[k.strip().lower()] = v.strip()
    status = f.get("status", "")
    code = None
    raw = (f.get("last result") or "").strip()
    if raw:
        try:
            n = int(raw, 0)
            code = None if n == 267011 else n
        except ValueError:
            code = None
    return {"loaded": status.lower() in ("ready", "running"), "exit": code}

def _launchd(label):
    try:
        p = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), label)],
                           capture_output=True, text=True, timeout=5)
        if p.returncode:
            return {"loaded": False, "exit": None}
        ex = None
        for l in p.stdout.split("\n"):
            if "last exit code" in l:
                ex = l.split("=")[-1].strip()
                # launchd prints "(never exited)" for a job that has not run yet.
                # That is not a failure, and colouring it Red would cry wolf every week.
                if not ex.lstrip("-").isdigit():
                    ex = None
        return {"loaded": True, "exit": ex}
    except Exception:
        return {"loaded": False, "exit": None}

def _systemd(label):
    # The dashboard runs as a service, the others run on a timer. Ask about the
    # timer where there is one, because a timer that is not active is the thing
    # that would silently stop the backups.
    unit = label + (".service" if label.endswith(".dashboard") else ".timer")
    try:
        p = subprocess.run(["systemctl", "--user", "show", unit,
                            "-p", "LoadState", "-p", "ActiveState", "-p", "ExecMainStatus"],
                           capture_output=True, text=True, timeout=5)
        if p.returncode:
            return {"loaded": False, "exit": None}
        kv = dict(l.split("=", 1) for l in p.stdout.strip().split("\n") if "=" in l)
        if kv.get("LoadState") != "loaded":
            return {"loaded": False, "exit": None}
        ex = kv.get("ExecMainStatus")
        # systemd reports 0 for a unit that has never run. Only the service units
        # carry a meaningful exit code, so a timer reports none rather than a fake 0.
        if unit.endswith(".timer") or not (ex or "").lstrip("-").isdigit():
            ex = None
        return {"loaded": kv.get("ActiveState") in ("active", "activating"), "exit": ex}
    except Exception:
        return {"loaded": False, "exit": None}

def gb(n):
    if n is None:
        return "not measured"
    for u, d in (("GB", 2**30), ("MB", 2**20), ("KB", 2**10)):
        if n >= d:
            return "%.2f %s" % (n / d, u)
    return "%d B" % n

def ago(ts):
    d = time.time() - ts
    for n, u in ((86400, "day"), (3600, "hour"), (60, "minute")):
        if d >= n:
            v = int(d // n)
            return "%d %s%s ago" % (v, u, "" if v == 1 else "s")
    return "just now"

def when(s):
    try:
        return datetime.fromisoformat(s).strftime("%a %d %b %Y, %H:%M")
    except Exception:
        return s or "unknown"

def e(s):
    return html.escape(str("" if s is None else s))

CSS = """*{box-sizing:border-box}body{margin:0;font:14px/1.55 -apple-system,system-ui,sans-serif;background:#0e1013;color:#e8eaed}
a{color:inherit;text-decoration:none}header{padding:16px 26px;border-bottom:1px solid #23262c;background:#14171c;display:flex;align-items:baseline;gap:24px;position:sticky;top:0;z-index:9}
header h1{font-size:17px;margin:0}nav a{font-size:13px;color:#9aa3ad;padding:5px 11px;border-radius:6px}
nav a:hover{background:#1e222a;color:#fff}nav a.on{background:#2a3038;color:#fff}main{padding:24px 26px;max-width:1240px}
h2{font-size:15px;margin:30px 0 10px}h2:first-child{margin-top:0}
.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(196px,1fr));gap:12px}
.tile{background:#171a20;border:1px solid #23262c;border-radius:9px;padding:14px 16px;cursor:pointer;transition:.12s}
.tile:hover{border-color:#3d4550;background:#1c2027;transform:translateY(-1px)}
.tile .k{font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.7px}
.tile .v{font-size:23px;margin-top:5px;font-weight:600}.tile .s{font-size:12px;color:#7d858f;margin-top:3px}
table{width:100%;border-collapse:collapse;background:#171a20;border:1px solid #23262c;border-radius:9px;overflow:hidden}
th{text-align:left;font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.6px;padding:10px 14px;background:#1b1f26}
td{padding:10px 14px;border-top:1px solid #21252c;font-size:13px}
tr.row{cursor:pointer}tr.row:hover td{background:#1e232b}
.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:#9aa3ad}
.Passed,.Approved,.Green,.Active,.Done{color:#4ade80;font-weight:600}
.Failed,.Rejected,.Red,.Critical{color:#f87171;font-weight:600}
.Pending,.Amber,.High{color:#fbbf24;font-weight:600}.Low,.muted{color:#7d858f}
.pill{display:inline-block;padding:2px 9px;border-radius:99px;font-size:11px;border:1px solid #3d4550;background:#1e232b}
.banner{background:#2a2310;border:1px solid #6b5514;border-radius:9px;padding:14px 18px;margin-bottom:22px;display:flex;justify-content:space-between;align-items:center;gap:20px}
.btn{display:inline-block;padding:7px 16px;border-radius:7px;border:1px solid #3d4550;background:#232831;font-size:13px;cursor:pointer;color:#e8eaed}
.btn:hover{background:#2d333d}.btn.go{background:#14532d;border-color:#22c55e;color:#dcfce7}
.btn.no{background:#4c1d1d;border-color:#ef4444;color:#fee2e2}
pre{background:#0b0d10;border:1px solid #23262c;border-radius:8px;padding:14px;overflow-x:auto;font-size:12px;color:#c9d1d9}
.crumb{font-size:12px;color:#7d858f;margin-bottom:14px}.crumb a:hover{color:#fff;text-decoration:underline}
.note{color:#7d858f;font-size:12px;margin-top:8px}
.bar{display:flex;gap:10px;align-items:center;margin:0 0 10px;flex-wrap:wrap}
.bar input,.bar select{background:#171a20;border:1px solid #2e333b;color:#e8eaed;border-radius:7px;
padding:7px 11px;font:13px -apple-system,system-ui,sans-serif;outline:none}
.bar input:focus,.bar select:focus{border-color:#4b5563}
.bar input{min-width:230px}.bar .count{color:#7d858f;font-size:12px;margin-left:auto}
th.s{cursor:pointer;user-select:none}th.s:hover{color:#e8eaed}
th.s::after{content:"\2195";opacity:.25;margin-left:5px}
th.s.up::after{content:"\2191";opacity:1}th.s.dn::after{content:"\2193";opacity:1}
iframe{width:100%;height:740px;border:1px solid #23262c;border-radius:9px;background:#fff}"""

JS = """(function(){var k='s:'+location.pathname;addEventListener('beforeunload',function(){sessionStorage.setItem(k,scrollY)});
var y=sessionStorage.getItem(k);if(y)scrollTo(0,parseInt(y,10))})();
addEventListener('keydown',function(v){if(v.key==='Escape'&&document.referrer)history.back()});
function go(u){location.href=u}
// Sort on the value in data-v, never on the printed text. "1.91 GB" and "474.89 MB"
// sort wrong as strings, and size is exactly the column people want ordered.
function tsort(id,n){var t=document.getElementById(id),b=t.tBodies[0],
 hs=t.tHead.rows[0].cells,h=hs[n],up=!h.classList.contains('up');
 for(var i=0;i<hs.length;i++){hs[i].classList.remove('up','dn')}
 h.classList.add(up?'up':'dn');
 var r=[].slice.call(b.rows);
 r.sort(function(a,c){var x=a.cells[n].dataset.v,y=c.cells[n].dataset.v;
  var nx=parseFloat(x),ny=parseFloat(y);
  if(!isNaN(nx)&&!isNaN(ny)){return up?nx-ny:ny-nx}
  return up?String(x).localeCompare(y):String(y).localeCompare(x)});
 r.forEach(function(x){b.appendChild(x)});
 try{sessionStorage.setItem('sort:'+id,n+':'+(up?1:0))}catch(e){}}
function tfilter(id,q){var t=document.getElementById(id),b=t.tBodies[0],n=0;
 q=(q||'').toLowerCase();
 [].slice.call(b.rows).forEach(function(r){
  var hit=!q||r.textContent.toLowerCase().indexOf(q)>-1;
  r.style.display=hit?'':'none';if(hit)n++});
 var c=document.getElementById(id+'-count');
 if(c)c.textContent=n+' of '+b.rows.length+' shown'}
function trestore(id){try{var v=sessionStorage.getItem('sort:'+id);if(!v)return;
 var p=v.split(':');tsort(id,+p[0]);if(+p[1]===0)tsort(id,+p[0])}catch(e){}}"""

TABS = [("/", "Overview"), ("/runs", "Runs"), ("/repos", "Repos"), ("/tests", "Tests"),
        ("/logs", "Logs"), ("/about", "How It Works")]

def page(title, body, on=""):
    nav = "".join('<a href="%s" class="%s">%s</a>' % (u, "on" if n == on else "", n) for u, n in TABS)
    return ('<!doctype html><html><head><meta charset="utf-8"><title>%s &mdash; Backup Control</title>'
            "<style>%s</style></head><body><header><h1>Backup Control</h1><nav>%s</nav>"
            '<span class="muted" style="margin-left:auto;font-size:12px">GitHub &rarr; cloud folder, read only</span>'
            "</header><main>%s</main><script>%s</script></body></html>") % (e(title), CSS, nav, body, JS)

def tile(k, v, s, href, tip=""):
    return ('<div class="tile" onclick="go(\'%s\')" title="%s"><div class="k">%s</div>'
            '<div class="v">%s</div><div class="s">%s</div></div>') % (href, e(tip), e(k), v, e(s))

def crumb(*parts):
    b = ['<a href="%s">%s</a>' % (p[1], e(p[0])) for p in parts[:-1]]
    last = parts[-1]
    b.append("<span>%s</span>" % e(last[0] if isinstance(last, tuple) else last))
    return '<div class="crumb">' + " &rsaquo; ".join(b) + "</div>"

def runs_table(r):
    if not r:
        return '<p class="muted">No run recorded yet.</p>'
    h = "<table><tr><th>Finished</th><th>Repos</th><th>Full</th><th>Diff</th><th>Unchanged</th><th>Failed</th></tr>"
    for x in r:
        h += ('<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="%s">%s</td></tr>'
              % (e(when(x.get("finished"))), e(x.get("repos")), e(x.get("fullBundles")),
                 e(x.get("diffBundles")), e(x.get("unchanged")),
                 "Passed" if x.get("failed", 0) == 0 else "Failed", e(x.get("failed"))))
    return h + "</table>"

def p_overview():
    r, rs, ts = runs(), repos(), tests()
    last = r[0] if r else None
    total = sum(x["fullBytes"] or 0 for x in rs) + sum(x["incBytes"] for x in rs)
    pend = [t for t in ts if t.get("approval", {}).get("state") == "Pending"]
    b = ""
    if pend:
        t = pend[0]
        b += ('<div class="banner"><div><b>%d Restore Test Awaiting Your Approval</b><div class="note">'
              '%s, verdict <span class="%s">%s</span>. The restored copy stays on disk until you decide.'
              '</div></div><a class="btn go" href="/test/%s">Inspect And Approve</a></div>'
              % (len(pend), e(t["repo"]), e(t.get("verdict")), e(t.get("verdict")), e(t["id"])))
    b += '<h2>Right Now</h2><div class="tiles">'
    b += tile("Last Backup", e(when(last["finished"]).split(",")[0]) if last else "never",
              "%s of %s repos" % (last["handled"], last["repos"]) if last else "no run recorded", "/runs",
              "The most recent completed run of the routine.")
    ub = unbundled()
    b += tile("Repos Backed Up", len(rs),
              "%d empty, nothing to bundle" % len(ub) if ub else "one bundle each", "/repos",
              "Every repo with a full bundle recorded in Drive. Repos with no bundle are "
              "listed on the Repos page with the reason.")
    b += tile("Backup Size", gb(total), "bundles in the cloud folder", "/repos",
              "Summed from the paths the job recorded writing, never from a Drive listing.")
    b += tile("Failures Last Run", last["failed"] if last else "&mdash;", "0 is the only good number",
              "/runs", "Repos the last run could not bundle.")
    b += tile("Restore Tests", len(ts), "%d awaiting approval" % len(pend) if pend else "none pending",
              "/tests", "Weekly proof that a bundle rebuilds a working repo.")
    b += tile("Weeks Verified", sum(1 for t in ts if t.get("approval", {}).get("state") == "Approved"),
              "approved by you", "/tests", "Restore tests you inspected and approved.")
    b += "</div><h2>Scheduled Jobs</h2><table><tr><th>Job</th><th>When</th><th>Loaded</th><th>Last Exit</th></tr>"
    for label, name, sched in ((LABEL + ".daily", "Daily Backup", "Every day 02:30"),
                               (LABEL + ".weekly", "Weekly Full Backup", "Sunday 03:30"),
                               (LABEL + ".restore-test", "Weekly Restore Test", "Sunday 05:00")):
        a = agent(label)
        ex = a["exit"]
        b += ('<tr><td>%s<div class="mono">%s</div></td><td>%s</td><td class="%s">%s</td><td class="%s">%s</td></tr>'
              % (e(name), e(label), e(sched), "Active" if a["loaded"] else "Failed",
                 "Active" if a["loaded"] else "Not Loaded",
                 "Passed" if ex == "0" else ("Failed" if ex not in (None, "0") else "muted"),
                 e(ex if ex is not None else "not run yet")))
    b += "</table><h2>Latest Runs</h2>" + runs_table(r[:6])
    return page("Overview", b, "Overview")

def p_runs():
    return page("Runs", crumb(("Overview", "/"), "Runs") + "<h2>Every Backup Run</h2>" + runs_table(runs())
                + '<p class="note">Read from the routine\'s own history file. Any run with a failure is Red '
                  "and must be read in that day's log.</p>", "Runs")

def p_repos():
    rs = repos()
    b = crumb(("Overview", "/"), "Repos") + "<h2>%d Repos</h2>" % len(rs)
    b += ('<div class="bar">'
          '<input id="repo-q" placeholder="Filter by name, e.g. api" '
          'oninput="tfilter(\'repos\',this.value)" title="Type any part of a repo name. '
          'The count on the right says how many rows are still showing.">'
          '<select onchange="if(this.value!==\'\')tsort(\'repos\',+this.value)" '
          'title="Order the table. Clicking a column heading does the same thing.">'
          '<option value="">Order By</option>'
          '<option value="0">Repo Name</option>'
          '<option value="1">Bundle Size</option>'
          '<option value="2">Diff Bundles</option>'
          '<option value="3">Refs</option>'
          '<option value="4">Local Mirror</option></select>'
          '<span class="count" id="repos-count">%d of %d shown</span></div>' % (len(rs), len(rs)))
    heads = [("Repo", "The owner and name on GitHub. Click the row for its bundle and refs."),
             ("Bundle", "Size of the full bundle in the cloud folder, sorted on the real byte count, "
                        "not the printed text."),
             ("Diffs", "Diff bundles waiting to be collapsed into the full bundle."),
             ("Refs", "Branches and tags the last run recorded."),
             ("Local Mirror", "Whether the bare mirror is still on this disk. Drive holds the "
                              "bundle either way.")]
    b += '<table id="repos"><thead><tr>'
    for i, (h, tip) in enumerate(heads):
        b += '<th class="s" onclick="tsort(\'repos\',%d)" title="%s">%s</th>' % (i, e(tip), e(h))
    b += "</tr></thead><tbody>"
    for x in rs:
        b += ('<tr class="row" onclick="go(\'/repo/%s\')">'
              '<td data-v="%s">%s</td><td data-v="%d">%s</td><td data-v="%d">%s</td>'
              '<td data-v="%d">%s</td><td data-v="%d" class="%s">%s</td></tr>'
              % (e(x["safe"]), e(x["nwo"]), e(x["nwo"]),
                 x["fullBytes"] or 0, gb(x["fullBytes"]),
                 x["incCount"], x["incCount"] or "&mdash;",
                 x["refs"], x["refs"],
                 1 if x["mirror"] else 0,
                 "Green" if x["mirror"] else "Amber",
                 "Present" if x["mirror"] else "Missing"))
    b += ("</tbody></table><script>trestore('repos')</script><p class=\"note\">Bundle size comes from the paths the job recorded writing. "
          "\"not measured\" means Drive has uploaded the file and evicted the local copy, so its size "
          "cannot be read without downloading it again. The bundle is still there.</p>")
    ub = unbundled()
    if ub:
        b += "<h2>Repos With No Bundle</h2><table><tr><th>Repo</th><th>Size On GitHub</th><th>Why</th></tr>"
        for u in ub:
            b += ('<tr><td>%s</td><td>%s</td><td class="%s">%s</td></tr>'
                  % (e(u["nwo"]), gb(u["kb"] * 1024),
                     "muted" if u["kb"] == 0 else "Amber", e(u["why"])))
        b += ("</table><p class=\"note\">This list is why the repo count is lower than the count of "
              "repos found. A repo with no commits has no objects, so a bundle of it would be empty.</p>")
    return page("Repos", b, "Repos")

def p_repo(safe):
    x = next((r for r in repos() if r["safe"] == safe), None)
    if not x:
        return page("Unknown", crumb(("Repos", "/repos"), "Unknown") + "<h2>No Such Repo</h2>", "Repos")
    b = crumb(("Overview", "/"), ("Repos", "/repos"), x["nwo"]) + "<h2>%s</h2>" % e(x["nwo"])
    b += '<div class="tiles">'
    b += tile("Full Bundle", gb(x["fullBytes"]), "whole history", "/repos",
              "One file holding every object. git clone reads it like a remote.")
    b += tile("Diff Bundles", x["incCount"], gb(x["incBytes"]), "/repos",
              "Commits since the previous run, collapsed into the full bundle monthly.")
    b += tile("Refs Recorded", x["refs"], "branches and tags", "/repos",
              "The ref tips the last run saw. The next run bundles only what is newer.")
    b += "</div>"
    if x["tips"]:
        b += "<h2>Recorded Ref Tips</h2><table><tr><th>Ref</th><th>Commit</th></tr>"
        for t in x["tips"]:
            if len(t) >= 2:
                b += '<tr><td class="mono">%s</td><td class="mono">%s</td></tr>' % (e(t[1]), e(t[0][:12]))
        b += "</table>"
    b += "<h2>Restore This Repo</h2><pre>%s</pre>" % e(
        "git clone --mirror '%s' %s.git\ngit clone %s.git %s" % (x["full"] or "<bundle>", safe, safe, safe))
    b += ('<p class="note">Rebuild through a bare mirror clone first. A diff bundle cannot be fetched '
          "into a checked-out working copy.</p>")
    return page(x["nwo"], b, "Repos")

def p_tests():
    ts = tests()
    b = crumb(("Overview", "/"), "Tests") + "<h2>Weekly Restore Tests</h2>"
    if not ts:
        b += ('<p class="muted">No test has run yet. The first runs on Sunday at 05:00, after the '
              "weekly full backup.</p>")
    else:
        b += ("<table><tr><th>When</th><th>Repo</th><th>Checks</th><th>Verdict</th>"
              "<th>Your Approval</th><th>Test Copy</th></tr>")
        for t in ts:
            ap, cl = t.get("approval", {}), t.get("cleanup", {})
            ok = sum(1 for c in t.get("checks", []) if c.get("result") == "Passed")
            b += ('<tr class="row" onclick="go(\'/test/%s\')"><td>%s</td><td>%s</td><td>%d of %d Passed</td>'
                  '<td class="%s">%s</td><td class="%s">%s</td><td class="%s">%s</td></tr>'
                  % (e(t["id"]), e(when(t.get("finished"))), e(t.get("repo")), ok, len(t.get("checks", [])),
                     e(t.get("verdict")), e(t.get("verdict")), e(ap.get("state")), e(ap.get("state")),
                     e(cl.get("state")), e(cl.get("state"))))
        b += "</table>"
    rot, pos = [], 0
    try:
        rot = [l.strip() for l in open(os.path.join(STATE, "restore-rotation.txt"))
               if l.strip() and not l.startswith("#")]
        pos = int(open(os.path.join(STATE, "restore-rotation.pos")).read().strip() or 0)
    except Exception:
        pass
    if rot:
        nxt = pos % len(rot)
        done = {t.get("repo") for t in ts if t.get("approval", {}).get("state") == "Approved"}
        b += ("<h2>The Rotation, %d Weeks</h2>" % len(rot))
        b += ('<table><tr><th>Week</th><th>Repo</th><th>When</th><th>Approved Before</th></tr>')
        for i, r in enumerate(rot):
            wk = (i - nxt) % len(rot)
            b += ('<tr><td>%s</td><td>%s</td><td class="%s">%s</td><td class="%s">%s</td></tr>'
                  % (i + 1, e(r), "Amber" if wk == 0 else "muted",
                     "Next Sunday" if wk == 0 else "in %d weeks" % wk,
                     "Passed" if r in done else "muted", "Yes" if r in done else "not yet"))
        b += ("</table>")
    b += ('<p class="note">One repo is tested each Sunday, in the order above, wrapping at the end. '
          "Nothing is deleted until you approve it here. Why any of this exists is written up in "
          "WHY.md in the backup-routine repo.</p>")
    return page("Tests", b, "Tests")

def p_test(tid):
    t = next((x for x in tests() if x["id"] == tid), None)
    if not t:
        return page("Unknown", crumb(("Tests", "/tests"), "Unknown") + "<h2>No Such Test</h2>", "Tests")
    ap, cl = t.get("approval", {}), t.get("cleanup", {})
    b = crumb(("Overview", "/"), ("Tests", "/tests"), t["repo"])
    b += "<h2>%s &mdash; %s</h2>" % (e(t["repo"]), e(when(t.get("finished"))))
    pv = t.get("preview") or {}
    if pv.get("url") and pv.get("state") == "Running":
        b += ('<div class="banner"><div><b>Look At The Rebuilt Work</b><div class="note">'
              'This is the repo as it came back out of the backup, built and served from '
              '<span class="mono">%s</span>. Serving %s. Click through it before you approve: '
              'a checklist says the files match, a page you can open says the work came back.'
              '</div></div><div><a class="btn go" href="%s" target="_blank" rel="noopener">'
              'Open The Rebuilt Site</a></div></div>'
              % (e(t.get("workspace")), e(pv.get("mode") or "files"), e(pv["url"])))
    elif pv.get("state") and pv.get("state") != "Running":
        b += ('<p class="note">Preview: %s%s</p>'
              % (e(pv.get("state")), " on port %s" % e(pv.get("port")) if pv.get("port") else ""))
    if ap.get("state") == "Pending":
        b += ('<div class="banner"><div><b>Awaiting Your Approval</b><div class="note">The restored copy '
              'is still on disk at <span class="mono">%s</span> (%s). Approving stops the preview server, '
              'deletes that one folder, and nothing else. Rejecting keeps both for investigation.'
              "</div></div><div>"
              '<form method="post" action="/approve" style="display:inline"><input type="hidden" name="id" '
              'value="%s"><button class="btn go">Approve And Delete Copy</button></form> '
              '<form method="post" action="/reject" style="display:inline"><input type="hidden" name="id" '
              'value="%s"><button class="btn no">Reject And Keep Copy</button></form></div></div>'
              % (e(t.get("workspace")), gb(t.get("workspaceBytes")), e(tid), e(tid)))
    else:
        b += ('<p><span class="pill">Approval: <span class="%s">%s</span></span> '
              '<span class="pill">Decided %s</span> <span class="pill">Test copy: <span class="%s">%s</span>'
              "</span></p>" % (e(ap.get("state")), e(ap.get("state")), e(when(ap.get("at"))),
                               e(cl.get("state")), e(cl.get("state"))))
    b += "<h2>Checks</h2><table><tr><th>Check</th><th>Result</th><th>What Was Measured</th></tr>"
    for c in t.get("checks", []):
        b += ('<tr><td>%s</td><td class="%s">%s</td><td class="mono">%s</td></tr>'
              % (e(c.get("name")), e(c.get("result")), e(c.get("result")), e(c.get("detail"))))
    b += "</table>"
    ev = t.get("evidence")
    if ev and os.path.exists(os.path.join(PROOFS, ev)):
        b += ('<h2>Evidence</h2><p class="note">The full report as the test wrote it. '
              '<a href="/evidence/%s" target="_blank" style="text-decoration:underline">Open in its own tab.</a>'
              '</p><iframe src="/evidence/%s"></iframe>' % (e(ev), e(ev)))
    if t.get("log"):
        b += "<h2>Test Log</h2><pre>%s</pre>" % e(t["log"][-8000:])
    return page(t["repo"], b, "Tests")

def p_logs():
    b = crumb(("Overview", "/"), "Logs") + "<h2>Run Logs</h2>"
    ls = logs()
    b += ('<div class="bar"><input placeholder="Filter by file name, e.g. weekly" '
          'oninput="tfilter(\'logs\',this.value)" title="Type any part of a log file name.">'
          '<span class="count" id="logs-count">%d of %d shown</span></div>' % (len(ls), len(ls)))
    b += ('<table id="logs"><thead><tr>'
          '<th class="s" onclick="tsort(\'logs\',0)" title="The log file on disk.">File</th>'
          '<th class="s" onclick="tsort(\'logs\',1)" title="Sorted on the real byte count.">Size</th>'
          '<th class="s" onclick="tsort(\'logs\',2)" title="Newest first by default.">Written</th>'
          "</tr></thead><tbody>")
    for l in ls:
        b += ('<tr class="row" onclick="go(\'/log/%s\')"><td data-v="%s" class="mono">%s</td>'
              '<td data-v="%d">%s</td><td data-v="%d">%s</td></tr>'
              % (e(l["name"]), e(l["name"]), e(l["name"]), l["bytes"], gb(l["bytes"]),
                 int(l["when"]), e(ago(l["when"]))))
    return page("Logs", b + "</tbody></table><script>trestore('logs')</script>", "Logs")

def p_log(name):
    if "/" in name or ".." in name:
        return page("Refused", "<h2>Refused</h2>", "Logs")
    try:
        text = open(os.path.join(LOGS, name), errors="replace").read()[-200000:]
    except OSError:
        text = "(could not read)"
    return page(name, crumb(("Overview", "/"), ("Logs", "/logs"), name)
                + "<h2>%s</h2><pre>%s</pre>" % (e(name), e(text)), "Logs")

ABOUT = """<h2>What This Routine Does</h2>
<p>Every repo on the GitHub account is mirrored to a local bare clone, then written into the cloud folder as a
git bundle. A bundle is one file holding real git objects; <span class="mono">git clone</span> reads it like
a remote. The routine never deletes anything in the Drive folder: superseded diff bundles are moved into
<span class="mono">archive/</span>, never removed.</p>
<h2>It Never Writes To GitHub</h2>
<p>Every local mirror carries <span class="mono">remote.origin.pushurl = no_push</span>, so a push, a force
push or a branch delete fails before it reaches the network. The routine reads GitHub and nothing else.</p>
<h2>Why This Page Reads No Drive Folder</h2>
<p>A launchd job cannot list a Google Drive directory at all. It may write and stat a file by exact path, but
a listing is refused. Anything that asked Drive what was in a folder would render an empty page and look like
a clean result. So every figure here comes from a file the backup job wrote on local disk.</p>
<h2>What The Weekly Test Proves</h2>
<p>Identical files are not the same as a working repo. Each Sunday one repo is rebuilt from its bundle alone,
then compared against a fresh clone from GitHub: HEAD, root tree, commit count, a sha256 manifest of every
file, a full recursive diff, and every branch and tag. Where the repo has something to run, it is built and
run.</p>
<h2>Nothing Is Deleted Without You</h2>
<p>The restored copy stays on disk until you approve it on its test page. The approval, the time and the
evidence are kept, so the record of what was verified outlives the copy it describes.</p>
<h2>What This Does Not Prove</h2>
<p>A pass says the bundle rebuilt that repo on this machine, this week. It does not say Drive still holds a
readable copy of every other repo, and it does not say a repo restores on a machine without these tools. No
failure here is not an all-clear for the rest.</p>"""

def p_about():
    return page("How It Works", crumb(("Overview", "/"), "How It Works") + ABOUT, "How It Works")

def stop_preview(pid, ws):
    """Stop one preview server, and only one this routine started.

    The pid is checked against its own command line before any signal is sent. A pid
    is reused by the operating system, so a stale record could otherwise name a
    process that has nothing to do with this tool."""
    try:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
    except Exception:
        return "Stop Failed"
    if not cmd:
        return "Already Stopped"
    if ws and ws not in cmd and "http.server" not in cmd:
        return "Not Stopped, Pid Reused"
    try:
        os.kill(int(pid), 15)
        time.sleep(0.4)
        return "Stopped"
    except Exception:
        return "Stop Failed"


# The only folders this dashboard may ever remove: a folder named restore-test-<id>
# sitting directly inside a temp directory. A hardcoded "/tmp/" prefix was right on
# macOS and Linux and wrong on Windows, where the temp directory is under AppData.
TEMP_ROOTS = set()
for _c in (tempfile.gettempdir(), os.environ.get("TMPDIR"), os.environ.get("TEMP"),
           os.environ.get("TMP"), "/tmp"):
    if _c and os.path.isdir(_c):
        TEMP_ROOTS.add(os.path.realpath(_c))

def removable(ws):
    if not ws or not os.path.isdir(ws):
        return False
    real = os.path.realpath(ws)
    return (os.path.basename(real).startswith("restore-test-")
            and os.path.dirname(real) in TEMP_ROOTS)

TID_OK = re.compile(r"\A[0-9A-Za-z][0-9A-Za-z._-]{0,119}\Z")

def valid_tid(tid):
    """A test id names one file in one folder. Anything with a separator, a dot-dot
    or an odd character is refused before it can be joined onto a path."""
    return bool(TID_OK.match(tid or "")) and ".." not in tid

def decide(tid, state, delete_copy):
    """Record the decision. Only ever removes a path this routine created under /tmp."""
    if not valid_tid(tid):
        return False
    path = os.path.join(TESTS, tid + ".json")
    if os.path.dirname(os.path.realpath(path)) != os.path.realpath(TESTS):
        return False
    t = rj(path, None)
    if not t:
        return False
    t.setdefault("approval", {})
    t["approval"].update({"state": state, "at": datetime.now().isoformat(timespec="seconds"),
                          "by": "human, in the dashboard"})
    # Stop the preview server first. Deleting the folder out from under a running
    # server leaves a process serving nothing and holding the port all week.
    pv = t.get("preview") or {}
    if delete_copy and pv.get("pid"):
        t["preview"] = dict(pv, state=stop_preview(pv["pid"], t.get("workspace") or ""))
    if delete_copy:
        ws = t.get("workspace") or ""
        ok = False
        if removable(ws):
            shutil.rmtree(ws, ignore_errors=True)
            ok = not os.path.exists(ws)
        t["cleanup"] = {"state": "Done" if ok else "Nothing To Delete",
                        "at": datetime.now().isoformat(timespec="seconds"),
                        "freedBytes": (t.get("workspaceBytes") or 0) if ok else 0}
    else:
        t["cleanup"] = {"state": "Kept For Investigation", "at": None, "freedBytes": 0}
    json.dump(t, open(path, "w"), indent=1)
    return True

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, code=200, ctype="text/html; charset=utf-8"):
        d = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        for k, v in (("Content-Type", ctype), ("Content-Length", str(len(d))), ("Cache-Control", "no-store")):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        p = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        try:
            if p == "/":
                return self.send(p_overview())
            for route, fn in (("/runs", p_runs), ("/repos", p_repos), ("/tests", p_tests),
                              ("/logs", p_logs), ("/about", p_about)):
                if p == route:
                    return self.send(fn())
            for pre, fn in (("/repo/", p_repo), ("/test/", p_test), ("/log/", p_log)):
                if p.startswith(pre):
                    return self.send(fn(p[len(pre):]))
            if p.startswith("/evidence/"):
                n = p[10:]
                if "/" in n or ".." in n:
                    return self.send("refused", 403, "text/plain")
                fp = os.path.join(PROOFS, n)
                if not os.path.exists(fp):
                    return self.send("not found", 404, "text/plain")
                return self.send(open(fp, "rb").read())
            if p == "/health":
                return self.send("ok", 200, "text/plain")
            return self.send(page("Not Found", "<h2>Not Found</h2>"), 404)
        except Exception as ex:
            return self.send(page("Error", "<h2>Error</h2><pre>%s</pre>" % e(repr(ex))), 500)

    def do_POST(self):
        # Approving deletes a restored copy and signs a human's name to the record.
        # Any page in any tab can post a form to localhost, so a request that says it
        # came from somewhere else is refused. A request with no Origin at all is a
        # local tool, not a browser, and is allowed.
        origin = self.headers.get("Origin")
        mine = ("http://localhost:%d" % PORT, "http://127.0.0.1:%d" % PORT)
        if (origin and origin not in mine) or \
           self.headers.get("Sec-Fetch-Site", "same-origin") not in ("same-origin", "none"):
            return self.send("Refused: this request did not come from the dashboard.", 403,
                             "text/plain; charset=utf-8")
        p = urllib.parse.urlparse(self.path).path
        n = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(n).decode())
        tid = (form.get("id") or [""])[0]
        if p == "/approve":
            decide(tid, "Approved", True)
        elif p == "/reject":
            decide(tid, "Rejected", False)
        self.send_response(303)
        self.send_header("Location", "/test/" + urllib.parse.quote(tid) if valid_tid(tid) else "/tests")
        self.end_headers()

class Server(ThreadingHTTPServer):
    """http.server asks socket.getfqdn() for a name it only uses in error pages.
    On a machine with slow reverse DNS that call blocks the bind for tens of
    seconds, so the dashboard looks dead while it starts. We serve on 127.0.0.1
    and never need the name, so skip the lookup."""
    allow_reuse_address = True

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), H) as s:
        print("Backup Control on http://localhost:%d" % PORT, flush=True)
        s.serve_forever()

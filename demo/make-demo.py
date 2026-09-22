#!/usr/bin/env python3
"""Writes a fake but realistic dataset for the dashboard.

Everything here is invented: the company, the repo names, the sizes, the dates.
Nothing reads a real account. This is what the screenshots in docs/images are
made from, so a screenshot can never leak a real project name.
"""
import json, os, random, sys, datetime

D = sys.argv[1]
CLOUD = os.path.join(D, "cloud")
random.seed(7)                      # same demo every time, so screenshots are repeatable
now = datetime.datetime(2026, 5, 17, 2, 41, 6)

REPOS = [
    ("acme/website",          474_982_113, 6, 31),
    ("acme/api",              318_220_940, 4, 22),
    ("acme/mobile-app",       201_774_002, 3, 18),
    ("acme/data-pipeline",    142_009_337, 5, 14),
    ("acme/design-system",     61_338_210, 2, 26),
    ("acme/docs",              18_774_500, 1, 9),
    ("acme/infra",             12_440_818, 3, 11),
    ("acme/marketing-site",     9_221_004, 2, 7),
    ("acme/internal-tools",     6_009_442, 1, 5),
    ("acme/prototypes",         2_118_776, 0, 4),
    ("acme/scratch-notes",        118_930, 0, 2),
    ("acme/brand-assets",      88_411_226, 1, 3),
]
EMPTY = ["acme/placeholder", "acme/old-import"]

def sparse(path, size):
    """A file that reports its size but uses almost no disk."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        if size:
            f.seek(size - 1)
            f.write(b"\0")

sizes = []
for nwo, size, incs, refs in REPOS:
    safe = nwo.replace("/", "__", 1)
    full = os.path.join(CLOUD, "full", safe + ".bundle")
    sparse(full, size)
    sizes.append(full)
    for i in range(incs):
        d = now - datetime.timedelta(days=i + 1)
        p = os.path.join(CLOUD, "inc", safe, d.strftime("%Y%m%d-023006") + ".bundle")
        sparse(p, random.randint(9_000, 900_000))
        sizes.append(p)
    with open(os.path.join(D, "state", safe + ".tips"), "w") as f:
        for r in range(refs):
            f.write("%040x refs/heads/%s\n" % (random.getrandbits(160),
                                               "main" if r == 0 else "feature/branch-%d" % r))
    os.makedirs(os.path.join(D, "mirrors", safe + ".git"), exist_ok=True)

with open(os.path.join(D, "state", "drive-sizes.tsv"), "w") as f:
    f.write("\n".join(sizes) + "\n")

# the repo list the backup job saves, so the dashboard can explain the empty ones
repo_list = [{"nameWithOwner": n, "diskUsage": s // 1024} for n, s, _, _ in REPOS] + \
            [{"nameWithOwner": n, "diskUsage": 0} for n in EMPTY]
json.dump(repo_list, open(os.path.join(D, "logs", "repos-20260517-024106.json"), "w"))

# run history
hist = []
for i in range(9, -1, -1):
    d = now - datetime.timedelta(days=i)
    hist.append({"finished": d.replace(hour=2, minute=41).isoformat(timespec="seconds"),
                 "repos": 14, "handled": 14, "failed": 0,
                 "fullBundles": 12 if i % 7 == 0 else 0,
                 "diffBundles": 0 if i % 7 == 0 else random.randint(1, 5),
                 "unchanged": 14 - (12 if i % 7 == 0 else random.randint(1, 5)),
                 "folderBytes": 1_338_209_440 + i * 4_000_000})
json.dump(hist, open(os.path.join(D, "dashboard", "history.json"), "w"), indent=1)

for name, body in (("daily-20260517-024106.log", "mirroring acme/website\n   DIFF 412 KB\nmirroring acme/api\n   quiet, nothing new\n"),
                   ("weekly-20260510-033012.log", "FULL rebuild of 12 repos\n   FULL 452.9 MB  acme/website\n"),
                   ("restore-test.out.log", "restore test finished, verdict Passed\n")):
    open(os.path.join(D, "logs", name), "w").write(body * 40)

CHECKS = [
    ("Bundle Present", "Passed", "474982113 bytes, written May 17 02:41:22 2026"),
    ("Bundle Verify", "Passed", "the bundle records a complete history"),
    ("Rebuild From Bundle", "Passed", "in-pack: 8841 packs: 1 size-pack: 463851"),
    ("Diff Bundles Applied", "Passed", "6 applied"),
    ("Working Copy", "Passed", "checked out main"),
    ("Comparison Source", "Passed", "fresh clone from github.com/acme/website"),
    ("HEAD Commit", "Passed", "1f3c9ab77de41205b6a0c8e9d2f4471aa9c30b18"),
    ("Root Tree", "Passed", "8b2e4419cc7d03a5619ef2b70d18c4a5539e7742"),
    ("Commit Count", "Passed", "1284"),
    ("File Manifest sha256", "Passed", "a7f30c15d9e84b2260cc17ff5a3e91b0742dd6c8e1f0a93b4c25d7e6f8091a3b"),
    ("Working Tree Size", "Passed", "4117 files, 268331904 bytes"),
    ("Recursive Diff", "Passed", "every file byte for byte identical"),
    ("Branches And Tags", "Passed", "31 refs, identical"),
    ("Dependencies Install", "Passed", "1142 packages"),
    ("Project Builds", "Passed", "npm run build exit 0"),
    ("Preview Served", "Passed", "http://localhost:3071  (static files from out)"),
]

def test(tid, repo, fin, approval, cleanup, preview):
    return {"id": tid, "repo": repo, "finished": fin,
            "bundle": os.path.join(CLOUD, "full", repo.replace("/", "__") + ".bundle"),
            "bundleBytes": 474_982_113, "comparedAgainst": "GitHub",
            "checks": [{"name": n, "result": r, "detail": d} for n, r, d in CHECKS],
            "verdict": "Passed",
            "workspace": "/tmp/restore-test-" + tid, "workspaceBytes": 1_012_207_616,
            "evidence": "restore-test-%s.html" % tid,
            "preview": preview, "approval": approval, "cleanup": cleanup,
            "log": "== restore test %s ==\nrepo:     %s\nweek:     position 1 of 12\n"
                   "verdict: Passed (0 failed checks)\n" % (tid, repo)}

t1 = test("20260517-050112-website", "acme/website", "2026-05-17T05:11:48",
          {"state": "Pending", "at": None, "by": None},
          {"state": "Pending", "at": None, "freedBytes": 0},
          {"port": 3071, "pid": 91422, "mode": "static files from out",
           "url": "http://localhost:3071/", "state": "Running"})
t2 = test("20260510-050107-api", "acme/api", "2026-05-10T05:09:30",
          {"state": "Approved", "at": "2026-05-10T09:22:04", "by": "human, in the dashboard"},
          {"state": "Done", "at": "2026-05-10T09:22:04", "freedBytes": 844_113_408},
          {"port": 3071, "pid": 88190, "mode": "static files from dist",
           "url": "http://localhost:3071/", "state": "Stopped"})
for t in (t1, t2):
    json.dump(t, open(os.path.join(D, "dashboard", "tests", t["id"] + ".json"), "w"), indent=1)
    open(os.path.join(D, "proofs", t["evidence"]), "w").write(
        "<!doctype html><meta charset=utf-8><title>Restore Test</title>"
        "<body style='font:14px/1.6 -apple-system,sans-serif;margin:30px'>"
        "<h1>Restore Test &mdash; %s</h1><p>verdict <b style='color:#15803d'>Passed</b>, "
        "compared against GitHub</p><p>Demo evidence file.</p>" % t["repo"])

open(os.path.join(D, "state", "restore-rotation.txt"), "w").write(
    "# one repo per week, in this order\n" + "\n".join(n for n, _, _, _ in REPOS) + "\n")
open(os.path.join(D, "state", "restore-rotation.pos"), "w").write("2\n")
print("demo data written to", D)

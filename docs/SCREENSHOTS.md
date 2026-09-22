# Screenshots

Every picture here was taken from the real dashboard running against demo data. No
picture was drawn, edited or touched up. The repository names in them (`acme/website`,
`acme/api` and so on) are invented. You can make the same data yourself:

```bash
zsh demo/make-demo.sh
GDB_CONFIG=$PWD/demo/config.env python3 bin/dashboard.py
```

That serves the demo on http://localhost:3091. It does not read your real backups and
does not touch GitHub.

## One thing to know before you look

The demo does not install the scheduled jobs. Installing them is what `install.sh` does
on a real machine, and a demo should not add jobs to your Mac. So the **Scheduled Jobs**
panel in the first picture reads `Not Loaded` in Red for all three jobs. That is true and
correct for the demo. After a real install, those three rows read `Loaded` with the exit
code of the last run.

## The pictures

### 01-overview.png
The front page. Top banner says one restore test is waiting for a human. Below it, six
numbers: date of the last backup, repos backed up, total size, failures, restore tests,
weeks verified. Then the three scheduled jobs, then the last six runs with a column for
full bundles, diff bundles, unchanged repos and failures.

### 02-tests.png
Every restore test ever run, newest first. Each row shows the repo, the verdict, whether
the restored copy is still on disk, and how many bytes it is holding. Rows are clickable.

### 03-test-detail.png
One test in full. This is the page a human reads before approving.

- A green banner, **Look At The Rebuilt Work**, with a button that opens the rebuilt
  project on localhost. The test rebuilt the repo from the bundle and served it, so you
  can click through the thing itself, not just read about it.
- An amber banner, **Awaiting Your Approval**, with Approve and Reject.
- All 16 checks, each with its result and the evidence behind it: bundle size and date,
  the HEAD commit, the root tree hash, the commit count, a sha256 of the file list, a
  byte-for-byte diff against a fresh clone from GitHub, the ref count, and whether the
  project installed and built.
- The saved HTML evidence file and the full test log.

### 04-repos.png
Every repo being backed up, with its bundle size, when it was last written, and its
branch tip. Empty repos are listed and marked, not hidden.

### 05-runs.png
Run history. One row per run, with counts and a link to that run's log.

### 06-how-it-works.png
The built-in explanation page. Same words as `docs/HOW-IT-WORKS.md`, served next to the
data so you do not have to go looking for a file.

## What approving does

Approving on the detail page does three things and nothing else: it stops the preview
server, it deletes that one folder under `/tmp/restore-test-`, and it records who
approved and when. It never touches GitHub, your mirrors, your cloud folder, or any
other test.

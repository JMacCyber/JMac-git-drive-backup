# How It Works

## The files

| File | What it does |
|---|---|
| `bin/backup.sh` | Mirrors every repo, writes bundles into the cloud folder |
| `bin/restore-test.sh` | Rebuilds one repo from a bundle and proves it |
| `bin/dashboard.py` | The website on `localhost:3070` |
| `bin/week-report.sh` | Prints the last seven days as plain text |
| `bin/config.sh` | Reads `config.env`, hands the settings to everything else |
| `bin/config.sh` handles the platform | It reads `uname` once into `GDB_OS`, then `gdb_size`, `gdb_mtime`, `gdb_free_gb` and `gdb_port_busy` pick the right form of each command, so nothing else has to care |
| `launchd/*.plist.tmpl` | The four schedules on macOS. `install.sh` fills in your paths |
| `systemd/*.tmpl` | The same four schedules on Linux, as user timers. No root needed |
| Windows | The same four schedules, made by `install.sh` with `schtasks`. No files to template |
| `tests/selftest.sh` | Runs the whole chain against a throwaway repo. 32 checks |

## What lands in your cloud folder

```
GitHub Backup/
  full/owner__name.bundle          whole history. First run, then monthly
  inc/owner__name/<stamp>.bundle   only what changed since last time
  archive/owner__name/             older bundles. Kept, never deleted
  metadata/owner__name.issues.json issues and repo settings
  LAST-RUN.txt                     plain text summary of the last run
  RESTORE.md                       how to get your code back, written fresh each run
  history.json                     every run, for the dashboard
```

Full bundles are the safety net. Diff bundles keep the daily upload small. Once a month a
new full bundle is written and the diffs it replaced are moved to `archive/`, not removed.

## Getting your code back, by hand

You do not need this tool to restore. Three commands, any machine with git:

```bash
git clone --mirror "GitHub Backup/full/owner__name.bundle" name.git
cd name.git && git fetch "../GitHub Backup/inc/owner__name/20260101-020000.bundle" \
  "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
cd .. && git clone name.git name
```

The order matters. A diff bundle cannot be pulled into a normal working copy. Rebuild the
bare mirror first, apply the diffs to it, then clone a working copy out of that.

`RESTORE.md` in your cloud folder says the same thing, written fresh on every run, so the
instructions are sitting next to the backup when you need them.

## The fourteen checks

| Check | What it measures |
|---|---|
| Bundle Present | The file exists, and how big it is |
| Bundle Verify | git agrees the bundle is complete and not damaged |
| Rebuild From Bundle | A bare repo builds from it |
| Diff Bundles Applied | Every later bundle fetched cleanly |
| Working Copy | A real checkout comes out of it |
| Comparison Source | GitHub, or the local mirror if GitHub is not reachable |
| HEAD Commit | Same latest commit as GitHub |
| Root Tree | Same tree hash, so the whole file tree matches |
| Commit Count | Same number of commits |
| File Manifest | One checksum over every file, both sides |
| Working Tree Size | How many files and bytes came back |
| Recursive Diff | Every file compared byte for byte |
| Branches And Tags | Every ref, both sides |
| Runnable Check | It installs and builds |
| Preview Served | It is on a localhost port for you to look at |

If GitHub cannot be reached, the test falls back to comparing against the local mirror and
**says so** in that row. Weaker evidence is labelled as weaker evidence.

## The preview server

After a passing test, the tool serves the rebuilt project so you can look at it.

By default it uses `python3 -m http.server`, bound to `127.0.0.1`, pointed at the build
output if there is one (`out`, `dist`, `build`, `public`, `_site`, `site`) and at the repo
folder if there is not. **That server never runs the restored project's own code.** You
are looking at files, so opening the preview cannot start anything.

If your project only makes sense when its own server runs, set this in `config.env`:

```bash
PREVIEW_RUN_CMD="npm start"
```

Understand what that does. It runs code out of your backup, with your user account, on
every restore test. If you only ever back up your own repos, that is the same code you
wrote. If you back up repos other people can push to, it is not. Static is the default for
that reason.

Either way the preview is stopped when you approve the test, and the port goes back.

## Approving

The dashboard shows a Pending test with two buttons.

**Approve and delete copy** does exactly three things: stops the preview server, deletes
the one folder named `restore-test-<id>` in the system temp directory, and writes the
decision into the record.

Before it sends any signal it checks that the process id still belongs to that preview.
Process ids get reused, so a stale record could otherwise name something unrelated. It
reads the process table with `ps` on macOS and Linux and `tasklist` on Windows.

The folder is checked the same way. It has to be named `restore-test-` something, and its
parent has to be a real temp directory on this machine, compared as folders rather than as
text: on Windows `RUNNER~1` and `runneradmin` are one directory spelled two ways. Anything
else is refused, and the page says which of those two rules it broke.

**Reject and keep copy** keeps the folder and the preview so you can investigate.

Either way the HTML report in `proofs/` stays. It outlives the copy it describes, so a
year later there is still an answer to "was this tested, and what did it say".

## Reading the state yourself

Nothing is hidden in a database. Everything is a file:

```bash
bash bin/week-report.sh                              # plain text, last 7 days
cat ~/.git-drive-backup/dashboard/history.json      # every run
ls  ~/.git-drive-backup/dashboard/tests/            # one json per test
open ~/.git-drive-backup/proofs/                    # the HTML reports
```

## Hooking it to an assistant

`bin/week-report.sh` prints and changes nothing, so it is safe to put on a schedule and
have an assistant read out. Give the assistant the script, not the dashboard: the script's
numbers come from the files, so the same week always reports the same way.

## macOS, Linux and Windows

All three do the same work with different schedulers, and the dashboard asks whichever one
this machine has.

| | macOS | Linux | Windows |
|---|---|---|---|
| Schedule | `launchd` user agents in `~/Library/LaunchAgents` | systemd user timers in `~/.config/systemd/user` | Task Scheduler tasks, made by `schtasks` |
| Job names | `com.gitdrivebackup.daily` and so on | the same names, with `.timer` or `.service` | the same names |
| Keeps the dashboard up | `KeepAlive` | `Restart=always` | starts at logon |
| Runs when logged out | yes | only after `loginctl enable-linger $USER` | no, the tasks run as you |
| See the jobs | `launchctl list \| grep gitdrivebackup` | `systemctl --user list-timers` | `schtasks /query /tn com.gitdrivebackup.daily` |

Windows needs Git Bash, which [Git for Windows](https://gitforwindows.org) installs
alongside git. The scripts are bash, and Git Bash is bash, so there is one implementation
and not a second one in PowerShell that would drift from it. Two things are genuinely
different and are handled: Task Scheduler runs Windows programs, so `install.sh` translates
every path with `cygpath`; and Git Bash numbers processes differently from Windows, so the
preview's Windows process id is what gets recorded, because the dashboard is a native
program and that is the number it can act on.

A task that has never run reports `267011`, not `0`. The dashboard shows that as no result
yet rather than as a success.

## Proving it still works

```bash
bash tests/selftest.sh
```

It makes a throwaway repo, bundles it, rebuilds it from that bundle alone, serves the
rebuilt copy, opens the dashboard on a spare port, approves the test, then checks the
preview stopped and the temporary copy went. 32 checks, exit code 1 if any fail. It never
reads your real backups and never contacts GitHub. Everything it makes stays in one
folder under the system temp directory, and it tells you where that is.

The same script runs on every push against Ubuntu 24.04, Ubuntu 22.04, macOS 14, macOS 15,
Windows Server 2022 and Windows Server 2025.

## One limit worth stating plainly

The restore test needs to read GitHub to compare against, so it asks `gh` for a token. That
token is scoped to the one `git clone` that needs it and the environment is scrubbed before
any restored code is built. What it cannot undo is this: `gh` keeps your token in the login
keychain, and anything running as you can ask for it. That is true of `gh` itself, with or
without this tool. If that is not acceptable, do not set `PREVIEW_RUN_CMD`, which is the
only setting here that runs code out of a backup.

## What a bundle does not carry

- **Git LFS objects.** A bundle holds the pointer files, not the large files behind them.
  An LFS repo needs `git lfs fetch --all` alongside this.
- **Submodules.** The bundle records which commit of the submodule was used, not the
  submodule's own history. Back each submodule up as its own repo.
- **Everything GitHub keeps outside git.** Pull requests, reviews, actions history, wikis,
  packages and releases. Issues and repo settings are saved as JSON in `metadata/`; the
  rest is not saved at all.

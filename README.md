# JMac-git-drive-backup

**Copies every one of your GitHub repos into a folder your cloud drive syncs, then
proves once a week that a copy really comes back.**

GitHub holds your work. It is one company, one account, one password. If the account
locks, or a token leaks, or you delete the wrong thing, it can all go at once. This makes
a second copy somewhere else, and it checks that copy instead of hoping.

Free. It uses git, Python and the scheduler already on your Mac. It starts no paid
service. It never writes to GitHub, and it never deletes anything of yours.

![The dashboard overview](docs/images/01-overview.png)

---

## What You Get

1. **Every repo, with its history.** Not a zip of today's files. A git bundle, which holds
   every commit, branch and tag. You can `git clone` a bundle like it was GitHub.
2. **A page that tells you the truth.** A small website on your own machine at
   `localhost:3070`. Last run, how many repos, how big, what failed, and the file each
   number came from.
3. **A weekly proof.** Every Sunday it takes one repo, rebuilds it from the backup alone,
   and compares it against GitHub file by file.
4. **The rebuilt work, on screen.** After the test builds the repo it serves it on
   localhost so you can click through it. A checklist says the files match. A page you can
   open says the work came back.
5. **You decide when the test copy goes.** Nothing is deleted until you press Approve.

## What You Do

Four things, once:

1. Install the GitHub command line tool and sign in.
2. Copy `config.env.example` to `config.env` and put in your cloud folder's path.
3. Run `zsh install.sh`.
4. List the repos you want tested, one per line, in the rotation file it makes for you.

After that, once a week:

- Open the dashboard. If a test is waiting, click through the rebuilt site, then press
  **Approve** or **Reject**. That is the whole job.

## Install

```bash
git clone https://github.com/YOUR-NAME/JMac-git-drive-backup.git
cd JMac-git-drive-backup
cp config.env.example config.env
# open config.env and set CLOUD_DIR to your synced folder
zsh install.sh --check     # tells you what is missing, changes nothing
zsh install.sh             # sets it up and starts the dashboard
```

You need: macOS, git, Python 3, and the [GitHub CLI](https://cli.github.com) signed in
with `gh auth login`. The check step names anything you are missing.

Read [docs/SETUP.md](docs/SETUP.md) for the longer walk-through, including how to find
your cloud folder's real path.

## What Runs, And When

| When | What happens |
|---|---|
| Every day, 02:30 | Backs up anything that changed since the last run |
| Sunday, 03:30 | Writes a fresh full bundle for every repo |
| Sunday, 05:00 | Restore test: rebuilds one repo, checks it, serves it |
| Always | The dashboard, on `localhost:3070` |

Times are set in the four files in `launchd/`. Change them before you install, or edit the
installed copies in `~/Library/LaunchAgents` and reload.

## The Weekly Test, Step By Step

![A passing restore test](docs/images/03-test-detail.png)

1. Take the next repo on your list.
2. Check the bundle file is there and passes `git bundle verify`.
3. Rebuild the repo from that bundle **only**. The original checkout is not touched or
   read.
4. Clone the same repo fresh from GitHub to compare against.
5. Compare: the latest commit, the whole file tree, the number of commits, a checksum of
   every file, every branch and tag, and a full recursive diff.
6. Try to build it. `npm install` and `npm run build` for a Node project, compile every
   file for a Python one.
7. Serve the result on a spare port so you can look at it.
8. Write an HTML report and a record marked **Pending**.
9. Wait. It deletes nothing.

When you press Approve, it stops that one preview server and deletes that one folder under
`/tmp`. Nothing else, ever. Reject keeps both so you can dig into them.

## Safety Rules It Follows

- **Read-only against GitHub.** Every mirror has its push URL set to `no_push`, so a push
  fails before it reaches the network. No issue, branch or repo is ever changed.
- **Nothing in your cloud folder is deleted.** Replaced bundles move to `archive/` with a
  line in a README saying what moved, when, and why.
- **One delete, and you own it.** The only thing this tool ever removes is a test copy
  under `/tmp/restore-test-`, after you approve it on screen.
- **No paid services.** Nothing here signs you up for anything.
- **Previews do not run your code.** By default the preview is a plain static file server,
  so opening it cannot execute anything out of the backup. Turning that off is opt-in and
  explained in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Honest Limits

- macOS only, because it uses `launchd` for the schedule. The scripts themselves are plain
  git, zsh and Python, so a Linux port is mostly writing four systemd timers.
- A green week proves one repo rebuilt on one machine on one day. It says nothing about the
  repos it did not test that week. The dashboard says so on the page.
- A repo with no commits has nothing to bundle. Those are listed separately so an
  unexplained gap never sits on the page looking like a failure.
- The cloud provider is still one company. If you want a copy that survives them too, point
  `CLOUD_DIR` at an external disk and run a second copy of this.

## Documents

- [docs/SETUP.md](docs/SETUP.md) — install, in full, with the common mistakes
- [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) — what every file does, and how to restore by hand
- [docs/WHY.md](docs/WHY.md) — why it is built this way
- [docs/SCREENSHOTS.md](docs/SCREENSHOTS.md) — every screen, with what it shows

## Licence

MIT. Use it, change it, sell it. No warranty: test your own restores.

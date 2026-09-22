# Setup

Twenty minutes, most of it waiting for the first backup.

## 1. Get the tools

```bash
xcode-select --install          # git, if you do not have it
brew install gh                 # the GitHub command line tool
gh auth login                   # sign in, pick HTTPS
```

Check it worked:

```bash
gh api user -q .login           # should print your GitHub name
```

## 2. Find your cloud folder

You need the real path, not the name you see in Finder.

1. Open Finder and find the folder you want the backups to live in.
2. Right-click it. Hold the Option key. The menu changes to **Copy "name" as Pathname**.
3. Paste that into `config.env`.

A Google Drive path usually looks like this:

```
/Users/you/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/GitHub Backup
```

The folder does not have to exist yet. The installer makes it.

## 3. Write your config

```bash
cp config.env.example config.env
open -e config.env
```

Set `CLOUD_DIR`. Everything else has a working default.

How much room do you need? Roughly double the size of all your repos: one local mirror,
one set of bundles in the cloud folder. To see the number before you start:

```bash
gh repo list --limit 1000 --json diskUsage -q '[.[].diskUsage]|add'
```

That prints kilobytes.

## 4. Install

```bash
bash install.sh --check    # checks the machine, changes nothing
bash install.sh            # makes folders, loads the four jobs, starts the dashboard
```

Open http://localhost:3070. It will be empty until the first backup runs.

## 5. Run the first backup yourself

Do not wait for 02:30. The first run is the long one, because every repo needs a full
bundle.

```bash
bash bin/backup.sh
```

Watch it, or leave it. When it finishes the dashboard fills in.

## 6. Choose what gets tested

The installer put an example list here:

```
~/.git-drive-backup/state/restore-rotation.txt
```

Replace the examples with your own repos, one `owner/name` per line. Put the ones that
would hurt most to lose at the top. One is tested each Sunday, in order, wrapping round at
the end.

Try one now instead of waiting for Sunday:

```bash
bash bin/restore-test.sh
```

## Common Mistakes

**"No config.env"** — you skipped step 3, or you made it somewhere other than the repo
folder.

**"the cloud folder is not there"** — the path in `CLOUD_DIR` is wrong. Redo step 2 with
the Option-key trick. Typing the path by hand gets the spaces and the account name wrong.

**Port 3070 is busy** — something else is using it. Change `DASH_PORT` in `config.env` and
run the installer again.

**The dashboard is empty** — no backup has finished yet. Run step 5.

**A job shows `NOT LOADED`** — run the installer again. macOS drops user jobs if the plist
file is edited underneath them.

**Google Drive says "operation not permitted"** — macOS will not let a scheduled job touch
a file in your Drive folder that a different program created. This tool works around it by
only ever writing files it made itself. If you are moving in bundles made some other way,
move them out of the folder and let the tool write its own.

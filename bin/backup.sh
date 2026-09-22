#!/usr/bin/env zsh
# Every GitHub repo this account can see, mirrored locally, then copied to the cloud folder.
#
#   full/<owner>__<name>.bundle          the whole history. Written on the first run for a
#                                        repo and once a month after that.
#   inc/<owner>__<name>/<stamp>.bundle   only the commits since the run before. Written every
#                                        run that finds new commits. Nothing is written when
#                                        nothing changed.
#   archive/<owner>__<name>/             increments a monthly full bundle has collapsed.
#                                        Kept, never deleted.
#
# Additive only. No pruning. Nothing in the Drive folder is ever deleted by this script.

set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

GDB_ROOT="${GDB_ROOT:-${0:A:h:h}}"
source "$GDB_ROOT/bin/config.sh"
DRIVE="$CLOUD_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
MONTH=$(date +%Y-%m)
LOG="$LOGDIR/backup-$STAMP.log"

# A mirror must never be able to write back to GitHub. no_push is not a real URL, so any
# push, force-push or branch delete from a mirror fails before it reaches the network.
# logAllRefUpdates keeps a reflog in the bare mirror, so a forced local ref update is
# still recoverable.
# du reports 0 for a file Google Drive has uploaded and dropped from the local cache.
# The logical size survives that, so report it instead.
hsize() { python3 -c "import os,sys;b=os.path.getsize(sys.argv[1]);print('%.1f MB'%(b/1048576) if b>=1048576 else '%d KB'%(b//1024))" "$1"; }

SIZES="$STATE/drive-sizes.tsv"
note() {  # note <path it just wrote into Drive>
  printf '%s\n' "$1" >> "$SIZES"
}

guard_mirror() {
  git -C "$1" remote set-url --push origin no_push >/dev/null 2>&1
  git -C "$1" config core.logAllRefUpdates true >/dev/null 2>&1
  git -C "$1" config receive.denyDeletes true >/dev/null 2>&1
}

mkdir -p "$MIRRORS/.tmp" "$STATE" "$LOGDIR"
exec > >(tee -a "$LOG") 2>&1
echo "== github-drive-backup $STAMP =="

free_gb=$(gdb_free_gb "$HOME")
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  echo "STOP: only ${free_gb}GB free on the local disk, need ${MIN_FREE_GB}GB. Nothing was touched."
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "STOP: gh is not authenticated. Under launchd this usually means the login keychain is locked."
  exit 1
fi
if [ ! -d "$(dirname "$DRIVE")" ]; then
  echo "STOP: the cloud folder is not there: $(dirname "$DRIVE"). Nothing was touched."
  exit 1
fi
mkdir -p "$DRIVE/full" "$DRIVE/inc" "$DRIVE/archive" "$DRIVE/metadata"

TOKEN=$(gh auth token)
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0="!f(){ echo username=x-access-token; echo password=$TOKEN; };f"

# GH_AFFILIATION=owner backs up only the repos this account owns. Anything else also
# walks every org the account belongs to. It used to walk the orgs either way, so the
# setting was documented and ignored.
REPOLIST="$LOGDIR/repos-$STAMP.json"
{
  gh repo list --limit 1000 --json nameWithOwner,isPrivate,isArchived,pushedAt,diskUsage
  if [ "$GH_AFFILIATION" != "owner" ]; then
    for org in $(gh api /user/orgs --jq '.[].login' 2>/dev/null); do
      gh repo list "$org" --limit 1000 --json nameWithOwner,isPrivate,isArchived,pushedAt,diskUsage
    done
  fi
} | python3 -c "
import json,sys
seen={}
buf=sys.stdin.read(); dec=json.JSONDecoder(); i=0
while i<len(buf):
    while i<len(buf) and buf[i].isspace(): i+=1
    if i>=len(buf): break
    o,i=dec.raw_decode(buf,i)
    for r in o: seen[r['nameWithOwner']]=r
json.dump(sorted(seen.values(),key=lambda r:r['nameWithOwner']),open('$REPOLIST','w'),indent=1)
print(len(seen))
" > "$LOGDIR/count-$STAMP.txt"
TOTAL=$(cat "$LOGDIR/count-$STAMP.txt")
echo "repos found: $TOTAL"

# BACKUP_LIMIT=N runs only the first N repos. For testing the routine, not for real runs.
LIMIT=${BACKUP_LIMIT:-0}

# BACKUP_FULL=1 rebuilds every full bundle instead of writing diffs. The weekly agent sets it.
FORCE_FULL=${BACKUP_FULL:-0}

OK=0; FAIL=0; FULLS=0; INCS=0; QUIET=0
FAILED=()

for NWO in $(python3 -c "import json;[print(r['nameWithOwner']) for r in json.load(open('$REPOLIST'))]"); do
  if [ "$LIMIT" -gt 0 ] && [ "$OK" -ge "$LIMIT" ]; then break; fi
  SAFE="${NWO//\//__}"
  M="$MIRRORS/$SAFE.git"
  TIPS="$STATE/$SAFE.tips"
  FULLMONTH="$STATE/$SAFE.full-month"
  echo "-- $NWO"

  if [ -d "$M" ]; then
    git -C "$M" remote set-url origin "https://github.com/$NWO.git" >/dev/null 2>&1
    guard_mirror "$M"
    if ! git -C "$M" fetch --quiet --tags --force origin "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"; then
      echo "   FETCH FAILED"; FAILED+=("$NWO"); FAIL=$((FAIL+1)); continue
    fi
  else
    if ! git clone --quiet --mirror "https://github.com/$NWO.git" "$M"; then
      echo "   CLONE FAILED"; FAILED+=("$NWO"); FAIL=$((FAIL+1)); continue
    fi
    guard_mirror "$M"
  fi

  NOW_TIPS=$(git -C "$M" show-ref --heads --tags 2>/dev/null | awk '{print $1}' | sort -u)
  if [ -z "$NOW_TIPS" ]; then
    echo "   no refs, nothing to bundle"
    OK=$((OK+1)); continue
  fi

  LAST_FULL=""
  [ -f "$FULLMONTH" ] && LAST_FULL=$(cat "$FULLMONTH")
  NEED_FULL=0
  [ "$FORCE_FULL" = "1" ] && NEED_FULL=1
  [ ! -f "$DRIVE/full/$SAFE.bundle" ] && NEED_FULL=1
  [ ! -f "$TIPS" ] && NEED_FULL=1
  [ "$LAST_FULL" != "$MONTH" ] && NEED_FULL=1

  TMP="$MIRRORS/.tmp/$SAFE.bundle"

  if [ "$NEED_FULL" -eq 1 ]; then
    if git -C "$M" bundle create "$TMP" --all >/dev/null 2>&1; then
      # A new full bundle used to be moved straight over the old one, which is a
      # delete however it is worded. The old one is moved aside first. It costs one
      # bundle per repo per monthly full; it buys a readable copy if the new bundle
      # is written from a mirror that was already wrong.
      if [ -f "$DRIVE/full/$SAFE.bundle" ]; then
        mkdir -p "$DRIVE/archive/$SAFE"
        if mv "$DRIVE/full/$SAFE.bundle" "$DRIVE/archive/$SAFE/full-replaced-$STAMP.bundle" 2>/dev/null; then
          echo "$STAMP  $SAFE  previous full bundle moved here, replaced by a newer full" >> "$DRIVE/archive/README.md"
        fi
      fi
      mv -f "$TMP" "$DRIVE/full/$SAFE.bundle"
      note "$DRIVE/full/$SAFE.bundle"
      echo "$MONTH" > "$FULLMONTH"
      FULLS=$((FULLS+1))
      echo "   FULL $(hsize "$DRIVE/full/$SAFE.bundle")"
      # This full bundle contains everything the old increments held. Move them aside,
      # do not delete them.
      # Move aside the increments this script recorded writing. A glob is no use
      # here, because the job is not allowed to list a Drive folder.
      INCLIST="$STATE/$SAFE.incs"
      if [ -s "$INCLIST" ]; then
        DEST="$DRIVE/archive/$SAFE/collapsed-into-full-$STAMP"
        mkdir -p "$DEST"
        MOVED=0
        while IFS= read -r b; do
          [ -f "$b" ] || continue
          if mv "$b" "$DEST/$(basename "$b")" 2>/dev/null; then
            note "$DEST/$(basename "$b")"; note "$b"; MOVED=$((MOVED+1))
          fi
        done < "$INCLIST"
        : > "$INCLIST"
        if [ "$MOVED" -gt 0 ]; then
          echo "$STAMP  $SAFE  $MOVED increments collapsed into full/$SAFE.bundle, moved from inc/$SAFE" >> "$DRIVE/archive/README.md"
          echo "   $MOVED increments archived to archive/$SAFE/collapsed-into-full-$STAMP"
        fi
      fi
    else
      echo "   FULL BUNDLE FAILED"; FAILED+=("$NWO"); FAIL=$((FAIL+1)); continue
    fi
  else
    # Only what is new since the tips recorded at the end of the last run.
    PREV=$(cat "$TIPS")
    if [ "$PREV" = "$NOW_TIPS" ]; then
      echo "   unchanged"
      QUIET=$((QUIET+1)); OK=$((OK+1)); continue
    fi
    NOT_ARGS=()
    for sha in ${(f)PREV}; do
      git -C "$M" cat-file -e "$sha" 2>/dev/null && NOT_ARGS+=("--not" "$sha")
    done
    if git -C "$M" bundle create "$TMP" --all "${NOT_ARGS[@]}" >/dev/null 2>&1; then
      mkdir -p "$DRIVE/inc/$SAFE"
      mv -f "$TMP" "$DRIVE/inc/$SAFE/$STAMP.bundle"
      note "$DRIVE/inc/$SAFE/$STAMP.bundle"
      echo "$DRIVE/inc/$SAFE/$STAMP.bundle" >> "$STATE/$SAFE.incs"
      INCS=$((INCS+1))
      echo "   DIFF $(hsize "$DRIVE/inc/$SAFE/$STAMP.bundle")"
    else
      echo "   refs moved but no new commits, nothing written"
      QUIET=$((QUIET+1))
    fi
  fi

  echo "$NOW_TIPS" > "$TIPS"
  gh api "repos/$NWO/issues?state=all&per_page=100" --paginate > "$DRIVE/metadata/$SAFE.issues.json" 2>/dev/null || echo "[]" > "$DRIVE/metadata/$SAFE.issues.json"
  gh api "repos/$NWO" > "$DRIVE/metadata/$SAFE.repo.json" 2>/dev/null
  note "$DRIVE/metadata/$SAFE.issues.json"
  note "$DRIVE/metadata/$SAFE.repo.json"
  OK=$((OK+1))
done

cp "$REPOLIST" "$DRIVE/metadata/_repo-list.json"
note "$DRIVE/metadata/_repo-list.json"
note "$DRIVE/LAST-RUN.txt"
note "$DRIVE/RESTORE.md"
note "$DRIVE/history.json"
BYTES=$(python3 -c "
import os,sys
p=sys.argv[1]
seen=[]
if os.path.exists(p):
    seen=list(dict.fromkeys(l.strip() for l in open(p) if l.strip()))
t=0; keep=[]
for q in seen:
    try:
        t+=os.path.getsize(q); keep.append(q)
    except OSError: pass
open(p,'w').write(chr(10).join(keep)+chr(10) if keep else '')
print(t)" "$SIZES")

# These are written straight into Drive, not moved in. An in-place write keeps the
# file's inode and its com.apple.macl, so the scheduled job can keep rewriting a file
# it created. A moved-in file is a new inode, which a scheduled job may not put over a
# file another program made.
REPORTFAIL=0
cat > "$DRIVE/LAST-RUN.txt" <<TXT
GitHub -> Google Drive backup
Finished:        $(date '+%Y-%m-%d %H:%M:%S %Z')
Repos found:     $TOTAL
Handled:         $OK
Full bundles:    $FULLS
Diff bundles:    $INCS
Unchanged:       $QUIET
Failed:          $FAIL ${FAILED[*]:-}
Folder size:     $(python3 -c "print('%.2f GB'%($BYTES/1073741824))")
Local mirrors:   $MIRRORS
Log:             $LOG

Read RESTORE.md in this folder to get a repo back.
Nothing in this folder is ever deleted by the script.
TXT
if [ ! -s "$DRIVE/LAST-RUN.txt" ]; then echo "REPORT WRITE FAILED: LAST-RUN.txt"; REPORTFAIL=1; fi

cat > "$DRIVE/RESTORE.md" <<'TXT'
# Getting a repo back

Every file here is a git bundle. A bundle is one file holding real git objects, so git
reads it like a remote.

## The whole repo, as of the last monthly full

    git clone "full/OWNER__NAME.bundle" NAME

That is enough if there are no diff bundles for the repo.

## The repo as of the last backup, full plus every diff

Rebuild into a bare repo first, then check it out. Fetching a diff straight into a
working copy fails, because git will not fetch into the branch you have checked out.
The diff bundles sort into the right order by name, so `*` applies them oldest first.

    git clone --mirror "full/OWNER__NAME.bundle" NAME.git
    cd NAME.git
    for b in "../inc/OWNER__NAME"/*.bundle; do
      git fetch "$b" "+refs/heads/*:refs/heads/*" "+refs/tags/*:refs/tags/*"
    done
    cd ..
    git clone NAME.git NAME

## Check a bundle before you trust it

    git bundle verify full/OWNER__NAME.bundle

A diff bundle reports the commits it needs first. Those come from the full bundle, or
from an earlier diff.

## Where the rest is

- `metadata/OWNER__NAME.issues.json` - every issue and pull request, open and closed.
- `metadata/OWNER__NAME.repo.json` - description, topics, default branch, visibility.
- `metadata/_repo-list.json` - every repo seen on the last run.
- `archive/` - diff bundles a monthly full has already absorbed. Kept for safety.
- `history.json` - one line per run.
TXT
if [ ! -s "$DRIVE/RESTORE.md" ]; then echo "REPORT WRITE FAILED: RESTORE.md"; REPORTFAIL=1; fi

python3 - "$DRIVE" "$TOTAL" "$OK" "$FAIL" "$FULLS" "$INCS" "$QUIET" "$BYTES" <<'PY'
import sys, json, os, datetime
d, total, ok, fail, fulls, incs, quiet, b = sys.argv[1], *[int(x) for x in sys.argv[2:]]
hist = os.path.join(d, 'history.json')
tmp  = os.path.expanduser('~/backups/github-mirrors/.tmp/history.json')
try:
    h = json.load(open(hist)) if os.path.exists(hist) else []
except Exception:
    h = []
h.append({"finished": datetime.datetime.now().isoformat(timespec='seconds'), "repos": total,
          "handled": ok, "failed": fail, "fullBundles": fulls, "diffBundles": incs,
          "unchanged": quiet, "folderBytes": b})
json.dump(h, open(tmp, 'w'), indent=1)
open(hist, 'w').write(open(tmp).read())
# Local copy for the dashboard. The dashboard is a launchd job too, and a
# launchd job cannot list a Drive folder, so it reads this local file, never Drive.
dash = os.environ['DASHDIR']
os.makedirs(dash, exist_ok=True)
open(os.path.join(dash, 'history.json'), 'w').write(open(tmp).read())
PY
if ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$DRIVE/history.json" 2>/dev/null; then
  echo "REPORT WRITE FAILED: history.json"; REPORTFAIL=1
fi

echo "== done: $OK handled, $FULLS full, $INCS diff, $QUIET unchanged, $FAIL failed =="
if [ "$REPORTFAIL" -eq 1 ]; then
  echo "== WARNING: bundles are safe, but the report files could not be updated =="
fi
[ "$FAIL" -eq 0 ] && [ "$REPORTFAIL" -eq 0 ]

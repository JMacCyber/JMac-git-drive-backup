# Why This Exists

This file is the reasoning, not the instructions. The instructions are in the README.

## The thing being protected

Every repository on one GitHub account. Years of work, some of it in no other place.
GitHub is one company, one account, one set of credentials. An account lock, a billing
lapse, a mistaken delete or a stolen token takes all of it at once.

A second copy that lives somewhere else is the whole point.

## Why git bundles and not a zip

A zip of a checkout saves the files as they are today. A git bundle holds the objects:
every commit, every branch, every tag. `git clone` reads a bundle like a remote, so a
restore gives back the repository, not a snapshot of one moment of it. History is most of
what a repo is worth. A zip throws it away.

## Why a synced cloud folder

Most people already pay for one. Putting the bundles in it means the copy leaves the
laptop without a new bill. Nothing here starts a metered service: the dashboard is Python
from the standard library, the schedule is `launchd`, and both are already on a Mac.

Any synced folder works. So does a plugged-in external disk, though a disk in the same
room as the laptop protects you from fewer things.

## Why the routine never writes to GitHub

Every local mirror carries `remote.origin.pushurl = no_push`. A backup that can write to
the thing it is backing up is a backup that can destroy it. A bug in a loop, a bad
variable, a wrong branch name: with push disabled, the worst case is a failed read. This
is not caution about likelihood. It refuses the whole class of failure.

## Why nothing in the cloud folder is ever deleted

Superseded diff bundles are moved into `archive/`, never removed. The cost of keeping a
stale bundle is a few megabytes. The cost of removing the wrong one is the thing itself.
That trade is never close.

## Why there is a dashboard

The version this grew out of ran for weeks and nobody looked. When it was finally
checked, the scheduled job had never fired at all: three faults stacked behind each
other, and the report it wrote said `0.00 GB` against gigabytes of real data.

A backup nobody checks is a backup nobody has. The dashboard turns "it is probably fine"
into a number on a screen, next to the file that number came from.

It reads only local files. A `launchd` job on macOS cannot list a Google Drive folder at
all, so a page that asked the cloud folder what was inside it would render empty and look
clean. An empty page that means failure is worse than no page.

## Why there is a weekly restore test

Identical files are not the same as a working repo. A bundle can verify, clone, and still
produce something that will not install or build.

The only honest proof is to rebuild a repo from the bundle alone, compare it against
GitHub file by file and ref by ref, try to build it, and then serve it so a person can
click through it.

One repo a week is the balance: enough that every important repo is proven inside a few
months, little enough that a Sunday costs minutes and not hours.

If the GitHub token is not reachable from the scheduled job, the test compares against the
local mirror and says so in the check detail. Weaker evidence is reported as weaker
evidence, never passed off as the same thing.

## Why the restored copy waits for a person

The test never deletes what it restored. Only an approval in the dashboard does, and only
a path under `/tmp/restore-test-`, and only after the preview server for that path has
been stopped.

If a check fails, the evidence is still on disk to be opened, not already thrown away. The
approval record and its HTML report outlive the copy they describe, so next year there is
still an answer to "was this ever really tested, and what did it say".

## What this does not prove

A green week says one bundle rebuilt one repo on one machine that day. It does not say the
cloud folder still holds a readable copy of the others. It does not say a repo restores on
a machine without git, node and python. Repos with no commits have nothing to bundle, and
the dashboard lists them separately so the gap is never left unexplained.

No failure is not an all-clear. It is one repo, one week, one machine.

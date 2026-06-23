# Forgejo Restic Restore Bootstrap

Small public recovery helper for restoring a Forgejo bare repository from a
restic backup and checking out a branch locally.

This repository intentionally contains no private topology or secrets. Keep
repository URLs, snapshot paths, storage bucket names, host names, clone
destinations, and credentials in a private recovery profile stored outside this
public repository.

## Quick Start

Download the script:

```sh
curl -fsSLO https://raw.githubusercontent.com/nashspence/forgejo-restic-restore-bootstrap/main/restore-forgejo-main.sh
chmod +x restore-forgejo-main.sh
```

Load your private recovery profile and run it:

```sh
. ./private-recovery-profile.env
./restore-forgejo-main.sh
```

The private profile must export:

```sh
export RESTIC_REPOSITORY='...'
export FORGEJO_REPO_PATH='...'
export RESTIC_PASSWORD='...'
```

It must also export whatever credentials the restic repository backend needs.
For S3-compatible repositories, that usually means:

```sh
export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'
```

## Useful Options

```sh
FORGEJO_REPO_NAME=restored-repo        # friendly default checkout directory
BRANCH=main                            # branch to restore
SNAPSHOT=latest                        # restic snapshot selector
WORK_DIR=/tmp/forgejo-restic-restore   # restore workspace
CLONE_DIR="$PWD/restored-repo"          # checkout destination
VERIFY_ONLY=1                          # restore and verify bare repo only
FORCE_CHECKOUT=1                       # allow checkout into a non-empty target
INSTALL_DEPS=0                         # do not apt-install missing git/restic
```

## What It Does

1. Checks for `git` and `restic`, installing them with `apt-get` when available.
2. Requires a restic repository, Forgejo bare repo path, and restic password
   source.
3. Restores only the selected Forgejo bare repository from the selected snapshot.
4. Runs `git fsck --full` against the restored bare repo.
5. Clones or updates the requested branch.

It does not restore services, start Forgejo, deploy host-managed files, or
repair the recovered checkout. Use the recovered private repository's own
recovery docs for the rest of the rebuild.

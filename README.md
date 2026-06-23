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

Download your encrypted private recovery profile from wherever you store it,
then run:

```sh
./restore-forgejo-main.sh \
  --profile forgejo-recovery-profiles.yml.age \
  --profile-name primary
```

For files ending in `.age`, the script normally uses interactive `age -d`.
For noninteractive use, set `AGE_PASSPHRASE`; the script will then use
`age -d -j batchpass`. If `age`, `age-plugin-batchpass`, or `restic` are not
available, the script downloads pinned upstream release binaries into a rootless
tool cache before restore. Explicit environment variables override profile
values for emergency tweaks.

## Profile Format

A profile file may contain one profile directly or multiple named profiles under
`profiles`:

```yaml
profiles:
  primary:
    restic_repository: s3:https://example.invalid/bucket/prefix
    forgejo_repo_path: /path/in/snapshot/owner/example-repo.git
    forgejo_repo_name: example-repo
    clone_dir: ./example-repo
    force_checkout: true
    env:
      AWS_ACCESS_KEY_ID: ...
      AWS_SECRET_ACCESS_KEY: ...
      RESTIC_PASSWORD: ...
```

Supported profile keys:

```yaml
restic_repository: ...
forgejo_repo_path: ...
forgejo_repo_name: ...
branch: main
snapshot: latest
work_dir: /tmp/forgejo-restic-restore
restore_root: /tmp/forgejo-restic-restore/restic-restore
restic_cache_dir: /tmp/forgejo-restic-restore/restic-cache
clone_dir: ./restored-repo
verify_only: false
force_checkout: false
install_deps: true
env:
  AWS_ACCESS_KEY_ID: ...
  AWS_SECRET_ACCESS_KEY: ...
  RESTIC_PASSWORD: ...
```

Uppercase environment-style keys are also accepted, and `env`, `backend_env`,
and `restic_env` mappings are exported for the restore process.

## Environment-Only Use

You can still use the tool without a profile by exporting values yourself:

```sh
export RESTIC_REPOSITORY='...'
export FORGEJO_REPO_PATH='...'
export RESTIC_PASSWORD='...'
export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'

./restore-forgejo-main.sh
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
INSTALL_DEPS=0                         # do not apt-install missing OS packages
DOWNLOAD_BOOTSTRAP_TOOLS=0             # do not download pinned age/restic tools
BOOTSTRAP_TOOL_DIR=/tmp/restore-tools  # rootless tool cache
AGE_VERSION=v1.3.1                     # upstream age release with batchpass
RESTIC_VERSION=0.18.1                  # upstream restic release
```

## Bootstrap Tooling

The script does not require private host-managed files to start recovery. When
`DOWNLOAD_BOOTSTRAP_TOOLS=1` (the default), missing `age`,
`age-plugin-batchpass`, and `restic` are downloaded from official upstream
release artifacts into `BOOTSTRAP_TOOL_DIR`. This keeps encrypted profile
loading and restic restore usable on a fresh host before private config repos
have been restored.

`INSTALL_DEPS=0` disables apt-based OS package installation but still allows
rootless pinned tool downloads. Set `DOWNLOAD_BOOTSTRAP_TOOLS=0` as well when
you want a fully pre-provisioned/offline run that fails on missing tools.

## What It Does

1. Optionally decrypts and loads an age-encrypted YAML profile.
2. Checks for `git`, `restic`, and profile dependencies, installing missing
   packages with `apt-get` when available.
3. Requires a restic repository, Forgejo bare repo path, and restic password
   source.
4. Restores only the selected Forgejo bare repository from the selected snapshot.
5. Runs `git fsck --full` against the restored bare repo.
6. Clones or updates the requested branch.

It does not restore services, start Forgejo, deploy host-managed files, or
repair the recovered checkout. Use the recovered private repository's own
recovery docs for the rest of the rebuild.

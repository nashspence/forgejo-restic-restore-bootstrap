#!/usr/bin/env bash
set -euo pipefail

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
FORGEJO_REPO_PATH="${FORGEJO_REPO_PATH:-}"
FORGEJO_REPO_NAME="${FORGEJO_REPO_NAME:-}"
BRANCH="${BRANCH:-main}"
SNAPSHOT="${SNAPSHOT:-latest}"
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/forgejo-restic-restore}"
RESTORE_ROOT="${RESTORE_ROOT:-$WORK_DIR/restic-restore}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$WORK_DIR/restic-cache}"
CLONE_DIR="${CLONE_DIR:-}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
FORCE_CHECKOUT="${FORCE_CHECKOUT:-0}"

export RESTIC_REPOSITORY RESTIC_CACHE_DIR

log() {
  printf '==> %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  restore-forgejo-main.sh

Required environment:
  RESTIC_REPOSITORY       restic repository URL/path
  FORGEJO_REPO_PATH       absolute bare repository path inside the restic snapshot

Restic password environment, one required:
  RESTIC_PASSWORD
  RESTIC_PASSWORD_FILE
  RESTIC_PASSWORD_COMMAND

Backend credentials:
  Export whatever credentials your restic repository backend requires.
  For S3-compatible repositories, this usually includes AWS_ACCESS_KEY_ID and
  AWS_SECRET_ACCESS_KEY.

Useful optional environment:
  FORGEJO_REPO_NAME       friendly name used only for the default checkout path
  BRANCH                  branch to clone or update, default: main
  SNAPSHOT                restic snapshot to restore, default: latest
  WORK_DIR                restore workspace, default: /tmp/forgejo-restic-restore
  RESTORE_ROOT            restic restore target, default: $WORK_DIR/restic-restore
  CLONE_DIR               checkout destination, default: ./$FORGEJO_REPO_NAME or ./restored-repo
  VERIFY_ONLY=1           restore and verify the bare repo without checkout
  FORCE_CHECKOUT=1        allow forced checkout into a non-empty target
  INSTALL_DEPS=0          fail instead of apt-installing missing git/restic commands
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ -n "$RESTIC_REPOSITORY" ]] || die "missing required environment: RESTIC_REPOSITORY"
[[ -n "$FORGEJO_REPO_PATH" ]] || die "missing required environment: FORGEJO_REPO_PATH"

if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
  die "set one restic password source: RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND"
fi

if [[ -z "$CLONE_DIR" ]]; then
  if [[ -n "$FORGEJO_REPO_NAME" ]]; then
    CLONE_DIR="$PWD/$FORGEJO_REPO_NAME"
  else
    CLONE_DIR="$PWD/restored-repo"
  fi
fi

install_missing_commands() {
  local missing=()
  local cmd

  for cmd in git restic; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  [[ "${#missing[@]}" -gt 0 ]] || return 0

  if [[ "$INSTALL_DEPS" != "1" ]]; then
    die "missing required command(s): ${missing[*]}"
  fi

  command -v apt-get >/dev/null 2>&1 || die "missing required command(s): ${missing[*]}; apt-get is unavailable"

  log "installing missing dependencies: ${missing[*]}"
  if [[ "$EUID" -eq 0 ]]; then
    apt-get update
    apt-get install -y ca-certificates git restic
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y ca-certificates git restic
  fi
}

restore_bare_repo() {
  local bare_repo="$1"

  mkdir -p "$RESTORE_ROOT" "$RESTIC_CACHE_DIR"

  log "restoring Forgejo bare repo from restic snapshot: $SNAPSHOT"
  restic restore "$SNAPSHOT" \
    --target "$RESTORE_ROOT" \
    --include "$FORGEJO_REPO_PATH"

  [[ -d "$bare_repo" ]] || die "restored bare repo was not found at: $bare_repo"

  log "verifying restored bare repo"
  git --git-dir="$bare_repo" fsck --full
}

checkout_branch() {
  local bare_repo="$1"
  local empty

  if [[ "$VERIFY_ONLY" == "1" ]]; then
    return 0
  fi

  if [[ -d "$CLONE_DIR/.git" ]]; then
    log "updating existing checkout: $CLONE_DIR"
    git -C "$CLONE_DIR" remote remove restored-backup >/dev/null 2>&1 || true
    git -C "$CLONE_DIR" remote add restored-backup "$bare_repo"
    git -C "$CLONE_DIR" fetch restored-backup "$BRANCH"
    git -C "$CLONE_DIR" checkout -B "$BRANCH" "restored-backup/$BRANCH"
    return 0
  fi

  if [[ -e "$CLONE_DIR" && ! -d "$CLONE_DIR" ]]; then
    die "target exists and is not a directory: $CLONE_DIR"
  fi

  if [[ -e "$CLONE_DIR" ]]; then
    empty=1
    if find "$CLONE_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
      empty=0
    fi

    if [[ "$empty" -eq 0 && "$FORCE_CHECKOUT" != "1" ]]; then
      die "target exists and is not empty: $CLONE_DIR; set CLONE_DIR elsewhere or use FORCE_CHECKOUT=1"
    fi

    if [[ "$FORCE_CHECKOUT" == "1" ]]; then
      log "force-checking out $BRANCH into: $CLONE_DIR"
      git init "$CLONE_DIR"
      git -C "$CLONE_DIR" remote remove origin >/dev/null 2>&1 || true
      git -C "$CLONE_DIR" remote add origin "$bare_repo"
      git -C "$CLONE_DIR" fetch origin "$BRANCH"
      git -C "$CLONE_DIR" checkout -f -B "$BRANCH" "origin/$BRANCH"
      return 0
    fi
  fi

  log "cloning $BRANCH into: $CLONE_DIR"
  git clone --branch "$BRANCH" "$bare_repo" "$CLONE_DIR"
}

main() {
  local bare_repo="$RESTORE_ROOT$FORGEJO_REPO_PATH"
  local branch_sha
  local branch_subject

  install_missing_commands
  restore_bare_repo "$bare_repo"

  branch_sha="$(git --git-dir="$bare_repo" rev-parse "refs/heads/$BRANCH")"
  branch_subject="$(git --git-dir="$bare_repo" log -1 --pretty=%s "refs/heads/$BRANCH")"

  checkout_branch "$bare_repo"

  printf '\nRestored branch:\n'
  printf '  repository path: %s\n' "$FORGEJO_REPO_PATH"
  printf '  branch: %s\n' "$BRANCH"
  printf '  commit: %s\n' "$branch_sha"
  printf '  subject: %s\n' "$branch_subject"
  printf '  bare repo: %s\n' "$bare_repo"
  if [[ "$VERIFY_ONLY" != "1" ]]; then
    printf '  checkout: %s\n' "$CLONE_DIR"
  fi
}

main "$@"

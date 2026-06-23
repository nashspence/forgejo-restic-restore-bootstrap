#!/usr/bin/env bash
set -euo pipefail

PROFILE_PATH=""
PROFILE_NAME=""
INSTALL_DEPS="${INSTALL_DEPS:-1}"
DOWNLOAD_BOOTSTRAP_TOOLS="${DOWNLOAD_BOOTSTRAP_TOOLS:-1}"
BOOTSTRAP_TOOL_DIR="${BOOTSTRAP_TOOL_DIR:-${TMPDIR:-/tmp}/forgejo-restic-restore-tools}"
AGE_VERSION="${AGE_VERSION:-v1.3.1}"
RESTIC_VERSION="${RESTIC_VERSION:-0.18.1}"

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
FORGEJO_REPO_PATH="${FORGEJO_REPO_PATH:-}"
FORGEJO_REPO_NAME="${FORGEJO_REPO_NAME:-}"
BRANCH="${BRANCH:-}"
SNAPSHOT="${SNAPSHOT:-}"
WORK_DIR="${WORK_DIR:-}"
RESTORE_ROOT="${RESTORE_ROOT:-}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-}"
CLONE_DIR="${CLONE_DIR:-}"
VERIFY_ONLY="${VERIFY_ONLY:-}"
FORCE_CHECKOUT="${FORCE_CHECKOUT:-}"

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
  restore-forgejo-main.sh [--profile FILE.yml.age] [--profile-name NAME]

Profile files:
  --profile FILE          age-encrypted YAML profile file, or plaintext YAML
                          when the file is not suffixed .age
  --profile-name NAME     profile under profiles.NAME to load

Required environment or profile values:
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

Useful optional environment or profile values:
  FORGEJO_REPO_NAME       friendly name used only for the default checkout path
  BRANCH                  branch to clone or update, default: main
  SNAPSHOT                restic snapshot to restore, default: latest
  WORK_DIR                restore workspace, default: /tmp/forgejo-restic-restore
  RESTORE_ROOT            restic restore target, default: $WORK_DIR/restic-restore
  CLONE_DIR               checkout destination, default: ./$FORGEJO_REPO_NAME or ./restored-repo
  VERIFY_ONLY=1           restore and verify the bare repo without checkout
  FORCE_CHECKOUT=1        allow forced checkout into a non-empty target
  INSTALL_DEPS=0          fail instead of apt-installing missing OS packages
  DOWNLOAD_BOOTSTRAP_TOOLS=0
                          do not download pinned upstream age/restic tools
  BOOTSTRAP_TOOL_DIR      rootless tool cache, default: /tmp/forgejo-restic-restore-tools

Explicit environment variables override profile values.
EOF
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --profile)
        [[ "$#" -ge 2 ]] || die "--profile requires a path"
        PROFILE_PATH="$2"
        shift 2
        ;;
      --profile-name)
        [[ "$#" -ge 2 ]] || die "--profile-name requires a name"
        PROFILE_NAME="$2"
        shift 2
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

tool_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armhf) printf 'arm' ;;
    *) die "unsupported CPU architecture for bootstrap tool download: $machine" ;;
  esac
}

download_file() {
  local url="$1"
  local dest="$2"
  python3 - "$url" "$dest" <<'PYCODE'
from __future__ import annotations

import sys
import urllib.request

urllib.request.urlretrieve(sys.argv[1], sys.argv[2])
PYCODE
}

ensure_tool_dir_on_path() {
  local bin_dir="$BOOTSTRAP_TOOL_DIR/bin"
  mkdir -p "$bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) export PATH="$bin_dir:$PATH" ;;
  esac
}

install_upstream_age() {
  local arch
  local tmp
  local archive
  local age_dir
  [[ "$DOWNLOAD_BOOTSTRAP_TOOLS" == "1" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  command -v tar >/dev/null 2>&1 || return 1
  command -v gzip >/dev/null 2>&1 || return 1

  ensure_tool_dir_on_path
  if command -v age >/dev/null 2>&1 && command -v age-plugin-batchpass >/dev/null 2>&1; then
    return 0
  fi

  arch="$(tool_arch)"
  tmp="$(mktemp -d)"
  archive="$tmp/age.tar.gz"
  log "downloading upstream age $AGE_VERSION into $BOOTSTRAP_TOOL_DIR"
  download_file "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${arch}.tar.gz" "$archive"
  tar -xzf "$archive" -C "$tmp"
  age_dir="$(tar -tzf "$archive" | head -1 | cut -d/ -f1)"
  cp "$tmp/$age_dir/age" "$tmp/$age_dir/age-keygen" "$tmp/$age_dir/age-plugin-batchpass" "$BOOTSTRAP_TOOL_DIR/bin/"
  chmod 0755 "$BOOTSTRAP_TOOL_DIR/bin/age" "$BOOTSTRAP_TOOL_DIR/bin/age-keygen" "$BOOTSTRAP_TOOL_DIR/bin/age-plugin-batchpass"
  rm -rf "$tmp"
}

install_upstream_restic() {
  local arch
  local tmp
  local archive
  local dest
  [[ "$DOWNLOAD_BOOTSTRAP_TOOLS" == "1" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  ensure_tool_dir_on_path
  if command -v restic >/dev/null 2>&1; then
    return 0
  fi

  arch="$(tool_arch)"
  tmp="$(mktemp -d)"
  archive="$tmp/restic.bz2"
  dest="$BOOTSTRAP_TOOL_DIR/bin/restic"
  log "downloading upstream restic $RESTIC_VERSION into $BOOTSTRAP_TOOL_DIR"
  download_file "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${arch}.bz2" "$archive"
  python3 - "$archive" "$dest" <<'PYCODE'
from __future__ import annotations

import bz2
import sys
from pathlib import Path

Path(sys.argv[2]).write_bytes(bz2.decompress(Path(sys.argv[1]).read_bytes()))
PYCODE
  chmod 0755 "$dest"
  rm -rf "$tmp"
}

install_missing_commands() {
  local missing_packages=()
  local missing_labels=()
  local cmd
  local needs_batchpass=0

  if [[ -n "$PROFILE_PATH" && "$PROFILE_PATH" == *.age && -n "${AGE_PASSPHRASE:-}" ]]; then
    needs_batchpass=1
  fi

  if ! command -v restic >/dev/null 2>&1; then
    install_upstream_restic || true
  fi

  if [[ -n "$PROFILE_PATH" && "$PROFILE_PATH" == *.age ]]; then
    if ! command -v age >/dev/null 2>&1 || { [[ "$needs_batchpass" == "1" ]] && ! command -v age-plugin-batchpass >/dev/null 2>&1; }; then
      install_upstream_age || true
    fi
  fi

  for cmd in git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_packages+=("$cmd")
      missing_labels+=("$cmd")
    fi
  done

  if ! command -v restic >/dev/null 2>&1; then
    missing_labels+=("restic")
  fi

  if [[ -n "$PROFILE_PATH" ]]; then
    if [[ "$PROFILE_PATH" == *.age ]] && ! command -v age >/dev/null 2>&1; then
      missing_labels+=("age")
      missing_packages+=("age")
    fi
    if [[ "$needs_batchpass" == "1" ]] && ! command -v age-plugin-batchpass >/dev/null 2>&1; then
      missing_labels+=("age-plugin-batchpass")
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      missing_packages+=("python3")
      missing_labels+=("python3")
    fi
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
      missing_packages+=("python3-yaml")
      missing_labels+=("python3-yaml")
    fi
  fi

  [[ "${#missing_labels[@]}" -gt 0 ]] || return 0

  if [[ "${#missing_packages[@]}" -eq 0 || "$INSTALL_DEPS" != "1" ]]; then
    die "missing required command(s): ${missing_labels[*]}"
  fi

  command -v apt-get >/dev/null 2>&1 || die "missing required command(s): ${missing_labels[*]}; apt-get is unavailable"

  log "installing missing OS dependencies: ${missing_packages[*]}"
  if [[ "$EUID" -eq 0 ]]; then
    apt-get update
    apt-get install -y ca-certificates "${missing_packages[@]}"
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required to install: ${missing_packages[*]}"
    sudo apt-get update
    sudo apt-get install -y ca-certificates "${missing_packages[@]}"
  fi

  if ! command -v restic >/dev/null 2>&1; then
    install_upstream_restic || true
  fi
  if [[ -n "$PROFILE_PATH" && "$PROFILE_PATH" == *.age ]]; then
    if ! command -v age >/dev/null 2>&1 || { [[ "$needs_batchpass" == "1" ]] && ! command -v age-plugin-batchpass >/dev/null 2>&1; }; then
      install_upstream_age || true
    fi
  fi

  if ! command -v restic >/dev/null 2>&1; then
    die "missing required command(s): restic"
  fi
  if [[ -n "$PROFILE_PATH" && "$PROFILE_PATH" == *.age ]] && ! command -v age >/dev/null 2>&1; then
    die "missing required command(s): age"
  fi
  if [[ "$needs_batchpass" == "1" ]] && ! command -v age-plugin-batchpass >/dev/null 2>&1; then
    die "missing required command(s): age-plugin-batchpass"
  fi
}

profile_assignments() {
  local profile_file="$1"
  local profile_name="$2"

  python3 - "$profile_file" "$profile_name" <<'PYCODE'
from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
profile_name = sys.argv[2]
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
if not isinstance(data, dict):
    raise SystemExit("profile YAML must be a mapping")

profiles = data.get("profiles")
if isinstance(profiles, dict):
    if profile_name:
        if profile_name not in profiles:
            raise SystemExit(f"profile not found: {profile_name}")
        profile = profiles[profile_name]
    elif len(profiles) == 1:
        profile = next(iter(profiles.values()))
    else:
        raise SystemExit("--profile-name is required when profile file has multiple profiles")
else:
    profile = data

if not isinstance(profile, dict):
    raise SystemExit("selected profile must be a mapping")

mapping = {
    "restic_repository": "RESTIC_REPOSITORY",
    "forgejo_repo_path": "FORGEJO_REPO_PATH",
    "forgejo_repo_name": "FORGEJO_REPO_NAME",
    "branch": "BRANCH",
    "snapshot": "SNAPSHOT",
    "work_dir": "WORK_DIR",
    "restore_root": "RESTORE_ROOT",
    "restic_cache_dir": "RESTIC_CACHE_DIR",
    "clone_dir": "CLONE_DIR",
    "verify_only": "VERIFY_ONLY",
    "force_checkout": "FORCE_CHECKOUT",
    "install_deps": "INSTALL_DEPS",
}

env: dict[str, object] = {}
for source_key, env_key in mapping.items():
    if source_key in profile:
        env[env_key] = profile[source_key]
    if env_key in profile:
        env[env_key] = profile[env_key]

for env_block_name in ("env", "backend_env", "restic_env"):
    env_block = profile.get(env_block_name)
    if env_block is None:
        continue
    if not isinstance(env_block, dict):
        raise SystemExit(f"{env_block_name} must be a mapping")
    for key, value in env_block.items():
        env[str(key)] = value

key_pattern = re.compile(r"^[A-Z_][A-Z0-9_]*$")
for key, value in env.items():
    if not key_pattern.match(key):
        raise SystemExit(f"invalid environment key in profile: {key}")
    if isinstance(value, bool):
        value = "1" if value else "0"
    elif value is None:
        value = ""
    else:
        value = str(value)
    print(f"{key}={shlex.quote(value)}")
PYCODE
}

apply_profile_assignment() {
  local assignment="$1"
  local key="${assignment%%=*}"

  if [[ -z "${!key:-}" ]]; then
    eval "export $assignment"
  fi
}

load_profile() {
  local plaintext_profile="$PROFILE_PATH"
  local temp_profile=""
  local assignment

  [[ -n "$PROFILE_PATH" ]] || return 0
  [[ -f "$PROFILE_PATH" ]] || die "profile file not found: $PROFILE_PATH"

  if [[ "$PROFILE_PATH" == *.age ]]; then
    temp_profile="$(mktemp)"
    if [[ -n "${AGE_PASSPHRASE:-}" ]]; then
      command -v age-plugin-batchpass >/dev/null 2>&1 || die "AGE_PASSPHRASE requires age-plugin-batchpass on PATH"
      age -d -j batchpass "$PROFILE_PATH" >"$temp_profile"
    else
      age -d "$PROFILE_PATH" >"$temp_profile"
    fi
    plaintext_profile="$temp_profile"
  fi

  while IFS= read -r assignment; do
    [[ -n "$assignment" ]] || continue
    apply_profile_assignment "$assignment"
  done < <(profile_assignments "$plaintext_profile" "$PROFILE_NAME")

  if [[ -n "$temp_profile" ]]; then
    rm -f "$temp_profile"
  fi
}

finalize_defaults() {
  BRANCH="${BRANCH:-main}"
  SNAPSHOT="${SNAPSHOT:-latest}"
  WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/forgejo-restic-restore}"
  RESTORE_ROOT="${RESTORE_ROOT:-$WORK_DIR/restic-restore}"
  RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$WORK_DIR/restic-cache}"
  VERIFY_ONLY="${VERIFY_ONLY:-0}"
  FORCE_CHECKOUT="${FORCE_CHECKOUT:-0}"

  if [[ -z "$CLONE_DIR" ]]; then
    if [[ -n "$FORGEJO_REPO_NAME" ]]; then
      CLONE_DIR="$PWD/$FORGEJO_REPO_NAME"
    else
      CLONE_DIR="$PWD/restored-repo"
    fi
  fi

  export RESTIC_REPOSITORY RESTIC_CACHE_DIR
}

validate_config() {
  [[ -n "$RESTIC_REPOSITORY" ]] || die "missing required value: RESTIC_REPOSITORY"
  [[ -n "$FORGEJO_REPO_PATH" ]] || die "missing required value: FORGEJO_REPO_PATH"

  if [[ -z "${RESTIC_PASSWORD:-}" && -z "${RESTIC_PASSWORD_FILE:-}" && -z "${RESTIC_PASSWORD_COMMAND:-}" ]]; then
    die "set one restic password source: RESTIC_PASSWORD, RESTIC_PASSWORD_FILE, or RESTIC_PASSWORD_COMMAND"
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
  local bare_repo
  local branch_sha
  local branch_subject

  parse_args "$@"
  install_missing_commands
  load_profile
  finalize_defaults
  validate_config

  bare_repo="$RESTORE_ROOT$FORGEJO_REPO_PATH"

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

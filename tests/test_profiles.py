from __future__ import annotations

import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "restore-forgejo-main.sh"


def run(argv: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        argv,
        cwd=cwd or ROOT,
        env=merged_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def make_bare_repo(tmp_path: Path, include_path: str) -> Path:
    work = tmp_path / "source-work"
    work.mkdir()
    run(["git", "init"], cwd=work).check_returncode()
    run(["git", "config", "user.email", "test@example.invalid"], cwd=work).check_returncode()
    run(["git", "config", "user.name", "Test User"], cwd=work).check_returncode()
    (work / "README.md").write_text("restored\n", encoding="utf-8")
    run(["git", "add", "README.md"], cwd=work).check_returncode()
    run(["git", "commit", "-m", "Initial commit"], cwd=work).check_returncode()

    snapshot_root = tmp_path / "snapshot"
    bare_repo = snapshot_root / include_path.lstrip("/")
    bare_repo.parent.mkdir(parents=True)
    run(["git", "clone", "--bare", str(work), str(bare_repo)]).check_returncode()
    return snapshot_root


def fake_restic_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    restic = bin_dir / "restic"
    restic.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "restore" ]] || { echo "unsupported fake restic command" >&2; exit 2; }
shift
snapshot="${1:-}"
shift || true
target=""
include=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    --include)
      include="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$snapshot" && -n "$target" && -n "$include" && -n "${FAKE_SNAPSHOT_ROOT:-}" ]] || exit 3
mkdir -p "$target$(dirname "$include")"
cp -a "$FAKE_SNAPSHOT_ROOT$include" "$target$include"
""",
        encoding="utf-8",
    )
    restic.chmod(0o755)
    return bin_dir


def add_fake_age_batchpass(bin_dir: Path) -> Path:
    args_file = bin_dir / "age-args.txt"
    age = bin_dir / "age"
    age.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$FAKE_AGE_ARGS"
[[ "${1:-}" == "-d" && "${2:-}" == "-j" && "${3:-}" == "batchpass" ]] || exit 7
cat "${4:?}"
""",
        encoding="utf-8",
    )
    age.chmod(0o755)
    plugin = bin_dir / "age-plugin-batchpass"
    plugin.write_text(
        """#!/usr/bin/env bash
echo fake age-plugin-batchpass
""",
        encoding="utf-8",
    )
    plugin.chmod(0o755)
    return args_file


def test_plaintext_profile_restores_selected_repo(tmp_path: Path) -> None:
    include_path = "/repositories/example.git"
    snapshot_root = make_bare_repo(tmp_path, include_path)
    bin_dir = fake_restic_bin(tmp_path)
    checkout = tmp_path / "checkout"
    profile = tmp_path / "profiles.yml"
    profile.write_text(
        f"""
profiles:
  example:
    restic_repository: fake-restic-repo
    forgejo_repo_path: {include_path}
    forgejo_repo_name: ignored-default
    clone_dir: {checkout}
    work_dir: {tmp_path / 'restore-work'}
    env:
      RESTIC_PASSWORD: test-password
""",
        encoding="utf-8",
    )

    result = run(
        [str(SCRIPT), "--profile", str(profile), "--profile-name", "example"],
        env={
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SNAPSHOT_ROOT": str(snapshot_root),
            "INSTALL_DEPS": "0",
        },
        cwd=tmp_path,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert (checkout / "README.md").read_text(encoding="utf-8") == "restored\n"
    assert "repository path: /repositories/example.git" in result.stdout


def test_profile_requires_name_when_multiple_profiles(tmp_path: Path) -> None:
    bin_dir = fake_restic_bin(tmp_path)
    profile = tmp_path / "profiles.yml"
    profile.write_text(
        """
profiles:
  one:
    restic_repository: one
  two:
    restic_repository: two
""",
        encoding="utf-8",
    )

    result = run(
        [str(SCRIPT), "--profile", str(profile)],
        env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "INSTALL_DEPS": "0"},
        cwd=tmp_path,
    )

    assert result.returncode != 0
    assert "--profile-name is required" in result.stderr


def test_explicit_environment_overrides_profile(tmp_path: Path) -> None:
    include_path = "/repositories/example.git"
    snapshot_root = make_bare_repo(tmp_path, include_path)
    bin_dir = fake_restic_bin(tmp_path)
    checkout = tmp_path / "checkout"
    profile = tmp_path / "profiles.yml"
    wrong_checkout = tmp_path / "wrong-checkout"
    profile.write_text(
        f"""
profiles:
  example:
    restic_repository: fake-restic-repo
    forgejo_repo_path: /wrong/path.git
    clone_dir: {wrong_checkout}
    work_dir: {tmp_path / 'wrong-restore-work'}
    env:
      RESTIC_PASSWORD: test-password
""",
        encoding="utf-8",
    )

    result = run(
        [str(SCRIPT), "--profile", str(profile), "--profile-name", "example"],
        env={
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SNAPSHOT_ROOT": str(snapshot_root),
            "INSTALL_DEPS": "0",
            "FORGEJO_REPO_PATH": include_path,
            "CLONE_DIR": str(checkout),
            "WORK_DIR": str(tmp_path / "restore-work"),
            "RESTIC_PASSWORD": "override-password",
        },
        cwd=tmp_path,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert (checkout / "README.md").is_file()
    assert not wrong_checkout.exists()


def test_age_profile_uses_batchpass_when_passphrase_env_is_set(tmp_path: Path) -> None:
    include_path = "/repositories/example.git"
    snapshot_root = make_bare_repo(tmp_path, include_path)
    bin_dir = fake_restic_bin(tmp_path)
    age_args = add_fake_age_batchpass(bin_dir)
    checkout = tmp_path / "checkout"
    profile = tmp_path / "profiles.yml.age"
    profile.write_text(
        f"""
profiles:
  example:
    restic_repository: fake-restic-repo
    forgejo_repo_path: {include_path}
    clone_dir: {checkout}
    work_dir: {tmp_path / 'restore-work'}
    env:
      RESTIC_PASSWORD: test-password
""",
        encoding="utf-8",
    )

    result = run(
        [str(SCRIPT), "--profile", str(profile), "--profile-name", "example"],
        env={
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_SNAPSHOT_ROOT": str(snapshot_root),
            "FAKE_AGE_ARGS": str(age_args),
            "AGE_PASSPHRASE": "test-passphrase",
            "INSTALL_DEPS": "0",
        },
        cwd=tmp_path,
    )

    assert result.returncode == 0, result.stderr + result.stdout
    assert age_args.read_text(encoding="utf-8").strip() == f"-d -j batchpass {profile}"
    assert (checkout / "README.md").read_text(encoding="utf-8") == "restored\n"

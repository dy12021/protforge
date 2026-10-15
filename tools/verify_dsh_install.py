#!/usr/bin/env python3
"""Independently verify a ProtForge -> DSH install.

Reads only what is installed under ``$DSH_HOME/skills`` plus the plugin source
it was generated from; it does not trust the installer's own bookkeeping. Every
check below is an assertion that can fail loudly, because a silently half-
installed skill set is indistinguishable from a working one until a tool run
dies three hours later.

Run ``--self-test`` to prove the guard is not a permanent green light: it builds
a temporary broken copy and asserts each check actually rejects it.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

import yaml

PLUGIN_DIR = Path(r"C:\Users\dy120\.minimax\plugins\protforge")
KEBAB_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
UNRESOLVED_RE = re.compile(r"\$\{PLUGIN_DIR\}|<tools-dir>|<windows-home>")
WINDOWS_PATH_RE = re.compile(r"[A-Za-z]:/[^\s\"'`)\\]+\.(?:sh|py)")
WSL_PATH_RE = re.compile(r"/mnt/[a-z]/[^\s\"'`)\\]+\.(?:sh|py)")


def dsh_home(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    for name in (".dsh-beta", ".dsh"):
        candidate = Path.home() / name
        if candidate.is_dir():
            return candidate
    return Path.home() / ".dsh-beta"


def split_frontmatter(text: str) -> tuple[dict, str]:
    if not text.startswith("---"):
        raise ValueError("no YAML frontmatter")
    end = text.find("\n---", 3)
    if end == -1:
        raise ValueError("frontmatter is not terminated")
    raw, body = text[3:end], text[end + 4 :]
    meta = yaml.safe_load(raw)
    if not isinstance(meta, dict):
        raise ValueError(f"frontmatter is not a mapping (got {type(meta).__name__})")
    return meta, body


def from_wsl(path: str) -> Path:
    """Map a WSL path back to its Windows host location for existence checks."""
    return Path(f"{path[5].upper()}:{path[6:]}")


def referenced_scripts(body: str) -> list[Path]:
    """Every script path a command block would actually execute."""
    return [Path(m) for m in WINDOWS_PATH_RE.findall(body)] + [
        from_wsl(m) for m in WSL_PATH_RE.findall(body)
    ]


def check(dest_root: Path, source_root: Path) -> list[str]:
    failures: list[str] = []
    sources = {p.name: p for p in source_root.iterdir() if (p / "SKILL.md").is_file()}
    installed = {p.name: p for p in dest_root.iterdir() if (p / "SKILL.md").is_file()}

    missing = sorted(set(sources) - set(installed))
    if missing:
        failures.append(f"not installed: {', '.join(missing)}")

    protforge_installed = {n: p for n, p in installed.items() if n.startswith("protforge-")}
    if len(protforge_installed) != len(sources):
        failures.append(
            f"expected {len(sources)} protforge skills, found {len(protforge_installed)}"
        )

    for name, skill_dir in sorted(protforge_installed.items()):
        text = (skill_dir / "SKILL.md").read_text(encoding="utf-8")
        try:
            meta, body = split_frontmatter(text)
        except Exception as exc:  # noqa: BLE001 - report, never crash the sweep
            failures.append(f"{name}: frontmatter invalid ({exc})")
            continue

        for key in ("name", "description"):
            if not isinstance(meta.get(key), str) or not meta[key].strip():
                failures.append(f"{name}: missing/empty '{key}'")
        if meta.get("name") != name:
            failures.append(f"{name}: frontmatter name is {meta.get('name')!r}")
        if not isinstance(meta.get("name"), str) or not KEBAB_RE.match(meta["name"] or ""):
            failures.append(f"{name}: name is not kebab-case")

        leftover = UNRESOLVED_RE.findall(text)
        if leftover:
            failures.append(f"{name}: unresolved placeholder(s) {sorted(set(leftover))}")

        for script in referenced_scripts(body):
            if not script.is_file():
                failures.append(f"{name}: referenced script missing: {script}")

        # Supporting files must be byte-identical copies of the source.
        source_dir = sources.get(name)
        if source_dir is None:
            continue
        for item in source_dir.rglob("*"):
            if not item.is_file() or item.name == "SKILL.md" or "__pycache__" in item.parts:
                continue
            copied = skill_dir / item.relative_to(source_dir)
            if not copied.is_file():
                failures.append(f"{name}: support file missing: {item.name}")
            elif copied.read_bytes() != item.read_bytes():
                failures.append(f"{name}: support file differs: {item.name}")

    return failures


def self_test(dest_root: Path, source_root: Path) -> int:
    """Break the install on purpose; every case below must be detected."""
    cases: list[tuple[str, callable[[Path], None]]] = [
        ("unparseable frontmatter", lambda d: (d / "protforge-fpocket" / "SKILL.md").write_text(
            "---\ndescription: \"bad: value here\"\n---\n\nbody\n", encoding="utf-8")),
        ("leftover placeholder", lambda d: patch(
            d / "protforge-vina-gpu" / "SKILL.md", "& ", "${PLUGIN_DIR}")),
        ("name/dir mismatch", lambda d: patch(
            d / "protforge-p2rank" / "SKILL.md", "name: protforge-p2rank", "name: protforge-p-rank")),
        ("missing referenced script", lambda d: (
            d / "protforge-fpocket" / "scripts" / "fpocket.sh").unlink()),
    ]
    failures = 0
    for label, mutate in cases:
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = Path(tmp) / "skills"
            shutil.copytree(dest_root, sandbox)
            mutate(sandbox)
            detected = check(sandbox, source_root)
            if detected:
                print(f"  [DETECTED] {label}: {detected[0]}")
            else:
                print(f"  [MISSED]   {label}: guard did not fire")
                failures += 1
    return failures


def patch(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"self-test setup failed: {old!r} not in {path.name}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-dir", default=str(PLUGIN_DIR))
    parser.add_argument("--dsh-home", default=None, help="override DSH_HOME")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    dest_root = dsh_home(args.dsh_home) / "skills"
    source_root = Path(args.plugin_dir) / "skills"
    if not dest_root.is_dir():
        print(f"FAIL  no DSH skills directory: {dest_root}")
        return 2

    if args.self_test:
        print("self-test (guard must reject each broken install):")
        missed = self_test(dest_root, source_root)
        print("self-test OK" if not missed else f"self-test FAILED: {missed} case(s) slipped through")
        return 1 if missed else 0

    failures = check(dest_root, source_root)
    print(f"DSH skills dir: {dest_root}")
    if failures:
        print(f"FAIL  {len(failures)} problem(s):")
        for line in failures:
            print(f"  - {line}")
        return 1
    count = sum(1 for p in dest_root.iterdir() if (p / "SKILL.md").is_file())
    print(f"OK    {count} skills valid: frontmatter parses, placeholders resolved, scripts present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

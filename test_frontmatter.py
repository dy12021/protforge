#!/usr/bin/env python3
"""Guard: every SKILL.md must have frontmatter a skill loader can actually parse.

Why this exists: the `description` values are long free text, and several of
them contain "Trigger: When ...". Written as a bare YAML scalar, a ": " inside
the value makes PyYAML raise

    ScannerError: mapping values are not allowed here

A skill whose frontmatter fails to parse is silently dropped by the loader --
the plugin advertised 23 skills but only 5 registered, with no error anywhere.
Quoting the value fixes it, and this test stops it coming back.

Run:  python test_frontmatter.py          (from the repo root, or with a path)
Exits non-zero if any SKILL.md fails to parse or is missing a required key.
"""
import pathlib
import re
import sys

FM_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---", re.S)
REQUIRED = ("name", "description")

try:
    import yaml
except ImportError:                                    # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".") / "skills"
skills = sorted(p for p in root.iterdir() if (p / "SKILL.md").is_file())
if not skills:
    sys.exit(f"no SKILL.md found under {root}")

failed = []
for d in skills:
    text = (d / "SKILL.md").read_text(encoding="utf-8")
    m = FM_RE.match(text)
    if not m:
        failed.append((d.name, "no leading '---' frontmatter block"))
        continue
    try:
        data = yaml.safe_load(m.group(1))
    except yaml.YAMLError as e:
        failed.append((d.name, f"unparseable YAML: {str(e).splitlines()[0]}"))
        continue
    if not isinstance(data, dict):
        failed.append((d.name, f"frontmatter is {type(data).__name__}, expected mapping"))
        continue
    missing = [k for k in REQUIRED if not data.get(k)]
    if missing:
        failed.append((d.name, f"missing/empty key(s): {', '.join(missing)}"))
        continue
    if data["name"] != d.name:
        failed.append((d.name, f"name field is {data['name']!r}, expected to match the directory"))

for name, why in failed:
    print(f"  FAIL {name}\n         {why}")
print(f"checked={len(skills)} failures={len(failed)}")
if failed:
    sys.exit(1)
print("ALL FRONTMATTER OK")

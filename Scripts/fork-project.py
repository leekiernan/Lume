#!/usr/bin/env python3
"""Keep the fork's project.pbxproj a pure function of upstream's.

The fork's only project-file changes are mechanical: signing identity (team,
bundle ids, signing style) and Xcode's recommended settings. Carried as a diff,
they sit next to the version lines, so every upstream version bump conflicts.
Carried as data, an upstream project change is taken whole and the overrides
re-applied — no hand-merging.

  Scripts/fork-project.py capture [--base <rev>]
      Record how the working project file differs from <rev>'s (default
      upstream/main) into Scripts/fork-project-overrides.json. Run after a
      deliberate fork change to the project (e.g. accepting a new Xcode
      recommended setting), then commit both files.

  Scripts/fork-project.py apply [--from <rev>]
      Rewrite the working project file as <rev>'s (default: keep the working
      file) with the overrides applied. Idempotent.

  Scripts/fork-project.py check [--base <rev>]
      Exit non-zero unless applying the overrides to <rev>'s project file
      reproduces the working file exactly.

Upstream intake: when a cherry-pick conflicts in project.pbxproj,
  Scripts/fork-project.py apply --from <upstream-commit>
  git add Lume.xcodeproj/project.pbxproj
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Lume.xcodeproj" / "project.pbxproj"
PROJECT_REL = "Lume.xcodeproj/project.pbxproj"
OVERRIDES = ROOT / "Scripts" / "fork-project-overrides.json"

# One XCBuildConfiguration: `\t\t<ID> /* <name> */ = {` … `buildSettings = {` … `};`
CONFIG = re.compile(
    r"(?P<head>\t\t(?P<id>[0-9A-F]{24}) /\* [^*]+ \*/ = \{\n"
    r"\t\t\tisa = XCBuildConfiguration;\n(?:\t\t\t[^\n]*\n)*?"
    r"\t\t\tbuildSettings = \{\n)(?P<body>(?:\t\t\t\t[^\n]*\n)*?)(?P<tail>\t\t\t\};\n)"
)
# A single-line setting inside buildSettings (multi-line arrays are left alone).
SETTING = re.compile(r'^\t\t\t\t(?P<key>"[^"]+"|[A-Za-z0-9_]+(?:\[[^\]]*\])?) = (?P<value>[^\n]*;)$')
ATTRIBUTE = re.compile(r"^(\t\t\t\t)(LastUpgradeCheck|LastSwiftUpdateCheck) = (\d+);$", re.M)


def git_show(rev: str) -> str:
    return subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{rev}:{PROJECT_REL}"],
        check=True, capture_output=True, text=True,
    ).stdout


def settings(body: str) -> dict:
    out = {}
    for line in body.splitlines():
        match = SETTING.match(line)
        if match:
            out[match["key"]] = match["value"]
    return out


def configs(text: str) -> dict:
    return {m["id"]: settings(m["body"]) for m in CONFIG.finditer(text)}


def sort_key(line: str) -> str:
    match = SETTING.match(line)
    return match["key"].strip('"') if match else line


def apply_to_body(body: str, changes: dict) -> str:
    lines = body.splitlines()
    for key, value in changes.items():
        index = next((i for i, l in enumerate(lines) if (m := SETTING.match(l)) and m["key"] == key), None)
        if value is None:
            if index is not None:
                del lines[index]
            continue
        new = f"\t\t\t\t{key} = {value}"
        if index is not None:
            lines[index] = new
            continue
        # Xcode keeps buildSettings sorted by key; insert where it would.
        position = next((i for i, l in enumerate(lines) if SETTING.match(l) and sort_key(l) > key.strip('"')), len(lines))
        lines.insert(position, new)
    return "".join(f"{l}\n" for l in lines)


def apply(text: str, overrides: dict) -> str:
    unknown = set(overrides["configurations"]) - {m["id"] for m in CONFIG.finditer(text)}
    if unknown:
        sys.exit(f"fork-project: build configurations no longer in the project: {sorted(unknown)}")

    def replace(match):
        changes = overrides["configurations"].get(match["id"])
        if not changes:
            return match.group(0)
        return match["head"] + apply_to_body(match["body"], changes) + match["tail"]

    text = CONFIG.sub(replace, text)
    for name, minimum in overrides.get("attributes", {}).items():
        # Only ever raise: once upstream adopts a newer Xcode, theirs stands.
        text = ATTRIBUTE.sub(
            lambda m: m.group(0) if m[2] != name else f"{m[1]}{name} = {max(int(m[3]), minimum)};", text
        )
    return text


def capture(base_rev: str) -> dict:
    base_text, ours_text = git_show(base_rev), PROJECT.read_text()
    base, ours = configs(base_text), configs(ours_text)
    if set(base) != set(ours):
        sys.exit(f"fork-project: configuration ids differ from {base_rev}; capture needs the same set")
    result = {"configurations": {}, "attributes": {}}
    for config_id in sorted(ours):
        changes = {k: v for k, v in ours[config_id].items() if base[config_id].get(k) != v}
        changes.update({k: None for k in base[config_id] if k not in ours[config_id]})
        if changes:
            result["configurations"][config_id] = dict(sorted(changes.items()))
    base_attrs = {m[2]: int(m[3]) for m in ATTRIBUTE.finditer(base_text)}
    for m in ATTRIBUTE.finditer(ours_text):
        if int(m[3]) > base_attrs.get(m[2], 0):
            result["attributes"][m[2]] = int(m[3])
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("capture", "check"):
        sub.add_parser(name).add_argument("--base", default="upstream/main")
    sub.add_parser("apply").add_argument("--from", dest="source")
    args = parser.parse_args()

    if args.command == "capture":
        OVERRIDES.write_text(json.dumps(capture(args.base), indent=2) + "\n")
        print(f"fork-project: wrote {OVERRIDES.relative_to(ROOT)}")
    elif args.command == "apply":
        source = git_show(args.source) if args.source else PROJECT.read_text()
        PROJECT.write_text(apply(source, json.loads(OVERRIDES.read_text())))
        print(f"fork-project: applied overrides to {PROJECT_REL}")
    else:
        expected = apply(git_show(args.base), json.loads(OVERRIDES.read_text()))
        if expected != PROJECT.read_text():
            sys.exit(f"fork-project: {PROJECT_REL} is not {args.base} + overrides")
        print(f"fork-project: {PROJECT_REL} == {args.base} + overrides")


if __name__ == "__main__":
    main()

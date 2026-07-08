#!/usr/bin/env python3
# ABOUTME: Extracts and strictly parses the YAML frontmatter of a plugin markdown file.
# ABOUTME: Prints the frontmatter as JSON on success; exits non-zero with a reason on failure.

import json
import re
import sys

# Mirrors the frontmatter delimiter Claude Code uses to slice the header off a plugin .md file.
FRONTMATTER = re.compile(r"^---\s*\n(.*?)---\s*\n?", re.DOTALL)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: frontmatter_check.py <file.md>", file=sys.stderr)
        return 2

    try:
        import yaml
    except ImportError:
        print("PyYAML is required to run the frontmatter tests: pip install pyyaml", file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()

    match = FRONTMATTER.match(text)
    if not match:
        print(f"{path}: no YAML frontmatter block found", file=sys.stderr)
        return 1

    # Claude Code attempts a strict parse first and only falls back to a lenient repair pass.
    # A file that needs the repair pass is one edit away from silently losing every key, so the
    # contract here is the strict parse.
    try:
        parsed = yaml.safe_load(match.group(1))
    except yaml.YAMLError as error:
        reason = str(error).splitlines()[0]
        print(f"{path}: frontmatter is not strict YAML: {reason}", file=sys.stderr)
        return 1

    if not isinstance(parsed, dict):
        print(f"{path}: frontmatter parsed to {type(parsed).__name__}, expected a mapping", file=sys.stderr)
        return 1

    json.dump(parsed, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Bump or verify this repo's internal self-references.

Every reusable workflow under .github/workflows/ calls this repo's own
composite actions via a full pinned path
(portainer/github-actions/.github/actions/<name>@<ref>) rather than a local
`./` path, because a reusable workflow's steps execute in the CALLING
repo's context, not this one. That `<ref>` can never be a SHA of "this same
commit" (the commit's hash would have to include itself), so it's kept in
sync with whatever tag this repo is releasing as instead. This script makes
that sync mechanical:

  verify <ref>   fail (exit 1) if any internal reference doesn't point at <ref>
  bump <ref>     rewrite every internal reference to <ref>

Run `verify <tag>` right before pushing a tag, and `bump <tag>` beforehand
to prepare the commit that tag will point at.
"""
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
REPO = "portainer/github-actions"

# Matches `uses: portainer/github-actions/.github/actions|workflows/<name>@<ref>`
# and captures everything up to the `@` separately from the ref itself.
REFERENCE_PATTERN = re.compile(
    rf"(uses:\s*{re.escape(REPO)}/\.github/(?:actions|workflows)/[^@\s]+)@([^\s#]+)"
)


def find_references():
    references = []
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        for lineno, line in enumerate(path.read_text().splitlines(), start=1):
            match = REFERENCE_PATTERN.search(line)
            if match:
                references.append((path, lineno, match.group(2)))
    return references


def cmd_verify(target_ref):
    references = find_references()
    if not references:
        print("No internal self-references found under .github/workflows/ — nothing to verify.")
        return 0

    mismatches = []
    for path, lineno, ref in references:
        rel = path.relative_to(REPO_ROOT)
        status = "OK" if ref == target_ref else "MISMATCH"
        print(f"[{status}] {rel}:{lineno} -> @{ref}")
        if ref != target_ref:
            mismatches.append((rel, lineno, ref))

    if mismatches:
        print(f"\n{len(mismatches)} of {len(references)} internal reference(s) do not point at @{target_ref}.")
        return 1

    print(f"\nAll {len(references)} internal reference(s) correctly pinned to @{target_ref}.")
    return 0


def cmd_bump(target_ref):
    total = 0
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")):
        text = path.read_text()
        new_text, count = REFERENCE_PATTERN.subn(rf"\g<1>@{target_ref}", text)
        if count:
            path.write_text(new_text)
            total += count
            print(f"{path.relative_to(REPO_ROOT)}: bumped {count} reference(s) to @{target_ref}")

    if total == 0:
        print("No internal self-references found under .github/workflows/ — nothing to bump.")
    else:
        print(f"\nBumped {total} internal reference(s) to @{target_ref}.")
    return 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("bump", "verify"):
        print(__doc__)
        return 2

    command, target_ref = sys.argv[1], sys.argv[2]
    return cmd_verify(target_ref) if command == "verify" else cmd_bump(target_ref)


if __name__ == "__main__":
    raise SystemExit(main())

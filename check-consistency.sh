#!/usr/bin/env bash
# Assert cross-skill literals that are duplicated verbatim stay byte-identical.
# Currently checks: the CLAUDE.md "## Branching & merging" paste-block, which the
# three bootstraps each order kept "verbatim-identical" with the others.
# Exits non-zero (naming the offending file) on any drift. Run before committing
# a change to any multi-homed literal — see README "Conventions".
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Files that must carry a byte-identical "## Branching & merging" paste-block.
BLOCK_FILES=(
  "skills/backend-repo-bootstrap/SKILL.md"
  "skills/ios-app-bootstrap/SKILL.md"
  "skills/python-library-bootstrap/SKILL.md"
)

# Print the fenced "## Branching & merging" block of $1: from the header line
# through the next closing ``` fence (inclusive). Empty output if absent.
extract_branching_block() {
  awk '
    /^## Branching & merging$/ { inblock = 1 }
    inblock                    { print }
    inblock && seen && /^```$/ { exit }   # closing fence after the header
    inblock                    { seen = 1 }
  ' "$1"
}

fail=0
ref_file="${BLOCK_FILES[0]}"
ref_block="$(extract_branching_block "$REPO_DIR/$ref_file")"

if [ -z "$ref_block" ]; then
  echo "check-consistency: FAIL — no '## Branching & merging' block in $ref_file" >&2
  exit 1
fi

for file in "${BLOCK_FILES[@]:1}"; do
  block="$(extract_branching_block "$REPO_DIR/$file")"
  if [ -z "$block" ]; then
    echo "check-consistency: FAIL — no '## Branching & merging' block in $file" >&2
    fail=1
    continue
  fi
  if [ "$block" != "$ref_block" ]; then
    echo "check-consistency: FAIL — '## Branching & merging' block in $file differs from $ref_file" >&2
    diff <(printf '%s\n' "$ref_block") <(printf '%s\n' "$block") >&2 || true
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check-consistency: OK — '## Branching & merging' block identical across ${#BLOCK_FILES[@]} bootstraps"

#!/usr/bin/env bash
# Assert cross-skill literals that are duplicated verbatim stay byte-identical.
# Checks: (1) the CLAUDE.md "## Branching & merging" paste-block and (2) the
# `.releaserc` JSON block — byte-identical across the three bootstraps; (3) the
# squash-merge REST-PATCH fragments (PR_TITLE / BLANK) intact in every skill
# that carries them. Exits non-zero (naming the offending file) on any drift.
# Run before committing a change to any multi-homed literal — see README
# "Conventions".
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Files that must carry a byte-identical "## Branching & merging" paste-block
# and a byte-identical `.releaserc` JSON block.
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

# Print the first ```json fence that follows the first `.releaserc` mention of
# $1 — that is the .releaserc block in all three bootstraps. Empty if absent.
extract_releaserc_block() {
  awk '
    /\.releaserc/       { armed = 1 }
    armed && /^```json$/ { infence = 1; next }
    infence && /^```$/   { exit }
    infence              { print }
  ' "$1"
}

fail=0
ref_file="${BLOCK_FILES[0]}"

# --- 1. "## Branching & merging" paste-block -------------------------------
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

# --- 2. `.releaserc` JSON block --------------------------------------------
ref_releaserc="$(extract_releaserc_block "$REPO_DIR/$ref_file")"

if [ -z "$ref_releaserc" ]; then
  echo "check-consistency: FAIL — no .releaserc json block in $ref_file" >&2
  exit 1
fi

for file in "${BLOCK_FILES[@]:1}"; do
  block="$(extract_releaserc_block "$REPO_DIR/$file")"
  if [ -z "$block" ]; then
    echo "check-consistency: FAIL — no .releaserc json block in $file" >&2
    fail=1
    continue
  fi
  if [ "$block" != "$ref_releaserc" ]; then
    echo "check-consistency: FAIL — .releaserc block in $file differs from $ref_file" >&2
    diff <(printf '%s\n' "$ref_releaserc") <(printf '%s\n' "$block") >&2 || true
    fail=1
  fi
done

# --- 3. squash-merge REST-PATCH fragments ----------------------------------
# Every skill that mentions the setting must carry BOTH exact fragments —
# catches a copy drifting to e.g. ...title=DEFAULT or losing the BLANK message.
patch_files=0
while IFS= read -r file; do
  patch_files=$((patch_files + 1))
  for frag in 'squash_merge_commit_title=PR_TITLE' 'squash_merge_commit_message=BLANK'; do
    if ! grep -q "$frag" "$file"; then
      echo "check-consistency: FAIL — $file mentions squash_merge_commit_title but lacks '$frag'" >&2
      fail=1
    fi
  done
done < <(grep -rIl 'squash_merge_commit_title' "$REPO_DIR/skills" "$REPO_DIR/agents" 2>/dev/null)

if [ "$patch_files" -eq 0 ]; then
  echo "check-consistency: FAIL — no skill carries the squash-merge REST-PATCH at all (expected in the bootstraps + gh-fork-safety)" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "check-consistency: OK — branching block + .releaserc identical across ${#BLOCK_FILES[@]} bootstraps; REST-PATCH fragments intact in $patch_files files"

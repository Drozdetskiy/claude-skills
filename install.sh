#!/usr/bin/env bash
# Sync the skills library into ~/.claude — every skill and agent, user scope.
#   install.sh     pull latest, (re)link all skills + agents, prune stale links
# Idempotent — safe to run anytime. Only NEW sessions re-read the skill/agent list.
set -euo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sync_repo() {
  if git -C "$REPO_DIR" diff --quiet && git -C "$REPO_DIR" diff --cached --quiet; then
    if git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
      echo "library: $(git -C "$REPO_DIR" log --oneline -1)"
    else
      echo "library: pull failed (offline or diverged) — using the local state"
    fi
  else
    echo "library: local changes present — skipping git pull"
  fi
}

# Remove links under $1 that point into this repo but whose target no longer exists
# (skill renamed/removed, or an old link left by a previous layout).
prune_stale() { # $1 = target dir
  local link pruned=0
  [ -d "$1" ] || return 0
  for link in "$1"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      "$REPO_DIR"/*)
        if [ ! -e "$link" ]; then
          rm "$link"
          echo "pruned:  $(basename "$link") (target gone)"
          pruned=$((pruned + 1))
        fi
        ;;
    esac
  done
  if [ "$pruned" -eq 0 ]; then echo "pruned:  nothing stale"; fi
}

sync_repo
mkdir -p "$HOME/.claude/skills" "$HOME/.claude/agents"

linked=0
for dir in "$REPO_DIR/skills"/*/; do
  [ -f "$dir/SKILL.md" ] || continue
  ln -sfn "${dir%/}" "$HOME/.claude/skills/$(basename "$dir")"
  linked=$((linked + 1))
done
echo "linked:  $linked skills -> $HOME/.claude/skills"
prune_stale "$HOME/.claude/skills"

linked=0
for file in "$REPO_DIR/agents"/*.md; do
  ln -sfn "$file" "$HOME/.claude/agents/$(basename "$file")"
  linked=$((linked + 1))
done
echo "linked:  $linked agents -> $HOME/.claude/agents"
prune_stale "$HOME/.claude/agents"

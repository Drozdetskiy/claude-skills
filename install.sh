#!/usr/bin/env bash
# Install/sync the skills library (skills AND agents).
#   install.sh --user                       link user/ skills into ~/.claude/skills and
#                                           agents/user/ agents into ~/.claude/agents (once per machine)
#   install.sh [project-dir]                sync project scope: refresh existing links, prune stale,
#                                           auto-link skills whose applies.sh matches this repo,
#                                           honoring opt-outs recorded by 'remove'
#   install.sh add    [project-dir] name…   force-link specific skills (clears their opt-out)
#   install.sh remove [project-dir] name…   unlink specific skills and remember the opt-out
# Idempotent — run anytime. Only NEW sessions re-read the skill/agent list.
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

prune_stale() { # $1 = target dir
  local pruned=0 link
  for link in "$1"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      "$REPO_DIR"/*)
        if [ ! -f "$link/SKILL.md" ]; then
          rm "$link"
          echo "pruned:  $(basename "$link") (target gone)"
          pruned=$((pruned + 1))
        fi
        ;;
    esac
  done
  if [ "$pruned" -eq 0 ]; then echo "pruned:  nothing stale"; fi
}

prune_stale_files() { # $1 = target dir (agent links are files, not skill dirs)
  local link
  [ -d "$1" ] || return 0
  for link in "$1"/*; do
    [ -L "$link" ] || continue
    case "$(readlink "$link")" in
      "$REPO_DIR"/*)
        if [ ! -f "$link" ]; then
          rm "$link"
          echo "pruned:  $(basename "$link") (target gone)"
        fi
        ;;
    esac
  done
}

gitignore_warn() { # $1 = project dir
  local sub
  if git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for sub in skills agents; do
      [ -d "$1/.claude/$sub" ] || continue
      if ! git -C "$1" check-ignore -q "$1/.claude/$sub/probe" 2>/dev/null; then
        echo "warning: .claude/$sub/ is NOT git-ignored in $1 — add it to .gitignore (the symlinks are machine-specific)"
      fi
    done
  fi
}

is_skipped() { # $1 = skipfile, $2 = name
  [ -f "$1" ] && grep -qx "$2" "$1"
}

unskip() { # $1 = skipfile, $2 = name
  [ -f "$1" ] || return 0
  grep -vx "$2" "$1" > "$1.tmp" || true
  mv "$1.tmp" "$1"
}

project_sync() { # $1 = project dir
  local project="$1" target="$1/.claude/skills" skipfile="$1/.claude/skills/.skipped"
  mkdir -p "$target"
  local dir name
  for dir in "$REPO_DIR/project"/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/SKILL.md" ] || continue
    if [ -L "$target/$name" ]; then
      ln -sfn "${dir%/}" "$target/$name"
      echo "linked:  $name (kept)"
    elif is_skipped "$skipfile" "$name"; then
      echo "skipped: $name (opted out — 'install.sh add . $name' to restore)"
    elif [ -x "$dir/applies.sh" ] && ! "$dir/applies.sh" "$project" >/dev/null 2>&1; then
      echo "skipped: $name (not applicable here)"
    else
      ln -sfn "${dir%/}" "$target/$name"
      echo "linked:  $name (auto: applicable)"
    fi
  done
  prune_stale "$target"
  gitignore_warn "$project"
}

project_add() { # $1 = project dir, $2... = skill names
  local project="$1" skills="$1/.claude/skills"
  shift
  local name found
  for name in "$@"; do
    found=0
    if [ -f "$REPO_DIR/project/$name/SKILL.md" ]; then
      mkdir -p "$skills"
      ln -sfn "$REPO_DIR/project/$name" "$skills/$name"
      unskip "$skills/.skipped" "$name"
      echo "linked:  $name (explicit)"
      found=1
    fi
    if [ "$found" -eq 0 ]; then
      echo "error: unknown project skill '$name' (see $REPO_DIR/project/)" >&2
      exit 1
    fi
  done
  gitignore_warn "$project"
}

project_remove() { # $1 = project dir, $2... = skill names
  local skills="$1/.claude/skills"
  shift
  local name found
  for name in "$@"; do
    found=0
    if [ -f "$REPO_DIR/project/$name/SKILL.md" ] || [ -L "$skills/$name" ]; then
      [ -L "$skills/$name" ] && rm "$skills/$name"
      mkdir -p "$skills"
      if ! is_skipped "$skills/.skipped" "$name"; then
        echo "$name" >> "$skills/.skipped"
      fi
      echo "removed: $name (opt-out recorded — sync will not re-add it)"
      found=1
    fi
    if [ "$found" -eq 0 ]; then
      echo "error: unknown project skill '$name' (see $REPO_DIR/project/)" >&2
      exit 1
    fi
  done
}

resolve_project() { # $1 = maybe-dir (must not be a skill name)
  local p="${1:-.}"
  p="$(cd "$p" && pwd)"
  if [ "$p" = "$REPO_DIR" ]; then
    echo "error: run from (or pass) a project directory, not the skills library itself" >&2
    exit 1
  fi
  echo "$p"
}

case "${1:-sync}" in
  --user)
    sync_repo
    mkdir -p "$HOME/.claude/skills"
    linked=0
    for dir in "$REPO_DIR/user"/*/; do
      name="$(basename "$dir")"
      [ -f "$dir/SKILL.md" ] || continue
      ln -sfn "${dir%/}" "$HOME/.claude/skills/$name"
      linked=$((linked + 1))
    done
    echo "linked:  $linked skills (user/) -> $HOME/.claude/skills"
    prune_stale "$HOME/.claude/skills"
    linked=0
    for file in "$REPO_DIR/agents/user"/*.md; do
      mkdir -p "$HOME/.claude/agents"
      ln -sfn "$file" "$HOME/.claude/agents/$(basename "$file")"
      linked=$((linked + 1))
    done
    echo "linked:  $linked agents (agents/user/) -> $HOME/.claude/agents"
    prune_stale_files "$HOME/.claude/agents"
    ;;
  add|remove)
    cmd="$1"; shift
    # First arg is the project dir only if it is a directory and not a skill name
    proj="."
    if [ $# -gt 0 ] && [ -d "$1" ] && [ ! -f "$REPO_DIR/project/$1/SKILL.md" ]; then
      proj="$1"; shift
    fi
    if [ $# -eq 0 ]; then
      echo "usage: install.sh $cmd [project-dir] <skill-name>..." >&2
      exit 1
    fi
    proj="$(resolve_project "$proj")"
    sync_repo
    "project_$cmd" "$proj" "$@"
    ;;
  *)
    proj="$(resolve_project "${1:-.}")"
    sync_repo
    project_sync "$proj"
    ;;
esac

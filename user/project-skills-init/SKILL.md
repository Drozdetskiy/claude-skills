---
name: project-skills-init
description: Wire the per-project skills from the claude-skills library into a project's .claude/skills — run install.sh, pick which project-scope skills apply, ensure the symlinks are git-ignored. Use when starting work in a project that lacks .claude/skills, after cloning a repo on a new machine, or right after bootstrapping a new repo.
---

# Project skills init

The library (`~/Development/skills`, github.com/Drozdetskiy/claude-skills) is split
in two scopes. **User scope** (`user/`, `agents/user/`) is linked once per machine
into `~/.claude/skills` and `~/.claude/agents` and is available in every session:
the repo bootstraps (needed BEFORE a project exists), the review/audit harnesses,
the named review/CI agents, this skill. **Project scope** (`project/`) is linked per
project into `<repo>/.claude/skills` — adopting an operational process like the
task-pipeline / ship-feature flow is a deliberate per-project decision, not
machine-wide ambience.

## Procedure

1. **Locate the library**: `~/Development/skills`. If missing (new machine):
   `git clone git@github.com:Drozdetskiy/claude-skills.git ~/Development/skills`
   and run `~/Development/skills/install.sh --user` first.
2. **Sync**: `~/Development/skills/install.sh <project-dir>` — applicability is
   detected per skill, not judged: every project-scope skill ships an
   `applies.sh` (task-pipeline and ship-feature check for a `.releaserc`;
   ios-localization for `project.yml`/`*.xcodeproj`), and sync
   auto-links only what matches, keeps existing links, and honors recorded
   opt-outs. Read the per-item output
   (`auto: applicable` / `not applicable here` / `opted out`) and relay
   anything surprising to the user.
3. **Per-item overrides** when the user wants something the detection didn't:
   `install.sh add <dir> <name>` force-links (and clears the opt-out);
   `install.sh remove <dir> <name>` unlinks AND records the opt-out in
   `.claude/skills/.skipped` so the next sync won't silently re-add it.
4. **Heed the gitignore warning**: `.claude/skills/` and `.claude/agents/` must
   be git-ignored — the links are machine-specific absolute paths. Add the lines
   through the repo's normal change process (a task PR into the feature branch).
5. Remind the user: only NEW sessions re-read the skill/agent list.

## Gotchas

- **Symlink, never copy** — the library stays the single source of truth; edits and
  `git pull` propagate to every project immediately.
- Re-running `install.sh` is always safe: it pulls, relinks, prunes links left by
  renamed/removed skills, and never resurrects an explicit `remove`.
- If `.claude/skills` contains REAL directories (not symlinks), those are the
  project's own private skills — leave them alone; the script never touches them.
- When adding a NEW project-scope skill to the library, ship an `applies.sh` with
  it (exit 0 = applicable to the repo passed as `$1`) — detection by command, not
  by judgment; without one the skill links everywhere.

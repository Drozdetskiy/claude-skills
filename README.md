# Claude Code skills

Personal skill + agent library for [Claude Code](https://claude.com/claude-code) —
battle-tested playbooks distilled from real projects. Each skill is a directory with
a `SKILL.md` (frontmatter `name`/`description` + the playbook) and optional
`templates/`; each agent is a single `.md` subagent definition.

Two scopes:

- **`user/`** + **`agents/user/`** — linked once per machine into `~/.claude/skills`
  and `~/.claude/agents`, available in every session: repo bootstraps (needed BEFORE
  a project exists), review/audit harnesses, the named review/CI agents, and the
  per-project initializer.
- **`project/`** — linked per project into `<repo>/.claude/skills`: operational
  skills tied to a process the project has deliberately adopted.

## User-scope skills

| Skill | Use for |
|---|---|
| [`ios-app-bootstrap`](user/ios-app-bootstrap/SKILL.md) | New iOS app repo: XcodeGen + SwiftUI skeleton, fastlane match signing, main + ephemeral feature branches (GitHub Flow) with semantic-release shipping every feature to TestFlight, PR test CI with snapshot-safe Xcode pinning, day-one testability seams |
| [`backend-repo-bootstrap`](user/backend-repo-bootstrap/SKILL.md) | New Python/FastAPI backend repo: uv + mise toolchain, CI with Postgres service containers, branch protection, conventional commits + semantic-release on main with ephemeral feature branches (GitHub Flow), multi-stage Docker, OIDC-based AWS release pipeline |
| [`python-library-bootstrap`](user/python-library-bootstrap/SKILL.md) | New redistributable Python package for PyPI: uv toolchain, hatchling + hatch-vcs dynamic versioning (git tag = version), ruff + mypy, multi-version pytest matrix behind one gate check, semantic-release on main, tokenless Trusted-Publishing (OIDC) to PyPI; public or private repo |
| [`homebrew-tap-release`](user/homebrew-tap-release/SKILL.md) | Distribute a CLI via a Homebrew tap: bootstrap homebrew-<tap> + Formula/*.rb, then bump version/url/sha256 per release from the PUBLISHED asset — sequencing (Release before formula), the mandatory homebrew- prefix, cross-repo tap-push token, brew audit/test; the PyPI distribution-slot companion to python-library-bootstrap |
| [`expo-to-native-ios-port`](user/expo-to-native-ios-port/SKILL.md) | Port an Expo/React Native app to native SwiftUI 1:1: Firebase auth via REST (not the iOS SDK), per-feature Route factories for conflict-free parallel screen ports, a single networking choke point, the frozen RN app as contract |
| [`gh-fork-safety`](user/gh-fork-safety/SKILL.md) | Run gh/git in a fork or multi-remote checkout: `gh repo set-default` before any query, pin `--repo/--base/--head`, the phantom-upstream failure mode, gh flag drift across versions |
| [`adversarial-diff-review`](user/adversarial-diff-review/SKILL.md) | Multi-agent review of a branch diff: parallel lens reviewers, each finding adversarially verified by an independent refuter |
| [`doc-code-audit`](user/doc-code-audit/SKILL.md) | Multi-agent audit of a planning doc against the codebase: per-section claim verifiers, cross-task lenses (contradictions/ordering/coherence), adversarial adjudication |
| [`task-handoff-spec`](user/task-handoff-spec/SKILL.md) | Write a task spec a fresh session (possibly in another repo) executes without re-deriving context: scout target-repo conventions, decisions with rationale, adversarial test cases, dated file:line citations |
| [`project-skills-init`](user/project-skills-init/SKILL.md) | Wire project-scope skills into a repo's `.claude/skills`: pick what applies, run install.sh, keep the links git-ignored |
| [`session-retro`](user/session-retro/SKILL.md) | Mine Claude Code session transcripts for reusable knowledge: retro the current session or mine all recent ones, pull human prompts with jq (not whole transcripts), filter programmatic sdk-cli runs, cluster recurring asks, route each to a new skill / template fix / rule / memory — proposes, never auto-creates |

## Project-scope skills

| Skill | Use for |
|---|---|
| [`task-pipeline`](project/task-pipeline/SKILL.md) | Drive one task from idea/issue to a squash-merged task-PR: issue authoring, plan as issue comment, size-scaled review gate, a CC PR title you confirm before it opens, check babysitting, optional auto-merge; target mode solo (no feature name → PR base = main, the merge is the release, Fixes #N closes the issue) or feature (feature name → PR base = that branch, ship-feature releases later); autonomy modes plan / push / auto |
| [`ship-feature`](project/ship-feature/SKILL.md) | Ship a finished feature branch to main: config preflight (diff new settings, verify/apply each layer), rebase-merge feature→main, watch semantic-release/deploy/smoke, recover from red smoke without a new version |
| [`feature-cycle`](project/feature-cycle/SKILL.md) | Drive a whole feature idea to a ready-to-ship branch: decompose into an ordered task chain (feature-decomposer), approve it once, run each task through task-pipeline sequentially and autonomously (auto-merge on green, self-heal red), aggregate config keys, stop at the ship gate; modes auto / push |
| [`ios-localization`](project/ios-localization/SKILL.md) | Localize an iOS app + its App Store listing into N languages: language-store plumbing, agent fan-out translation with per-language register rules, economical fixture/snapshot policy, ASC name-availability check, metadata-only deliver |
| [`llm-structured-outputs-hardening`](project/llm-structured-outputs-hardening/SKILL.md) | Harden an OpenAI(-compatible) Structured Outputs layer: enforce array cardinality in the schema not via retries, catch the SDK errors that bypass APIError, survive reasoning_effort enum drift, asymmetric per-finish-reason resample, latency-as-fallback-signal |
| [`llm-prompt-i18n`](project/llm-prompt-i18n/SKILL.md) | LLM prompt templates + multilingual output: str.format brace escaping, the literal-leak / negative-instruction anti-pattern, one source of truth for the active language, scoping localization (AI content is free, only static strings need work) |
| [`postgres-async-concurrency`](project/postgres-async-concurrency/SKILL.md) | Concurrency/idempotency on async SQLAlchemy + asyncpg: the EvalPlanQual FOR UPDATE trap, get_or_create lying under races, non-blocking advisory locks for replay, position-bearing array ordering, loop-bound pool disposal in tests |

## User-scope agents

| Agent | Use for |
|---|---|
| [`diff-reviewer`](agents/user/diff-reviewer.md) | One lens of a multi-lens diff review (lens passed in the prompt) — findings with file:line evidence; used by adversarial-diff-review and task-pipeline |
| [`finding-refuter`](agents/user/finding-refuter.md) | Adversarial verification of ONE finding — tries to refute it against the actual code (incl. dependency sources), defaults to not-real |
| [`ci-doctor`](agents/user/ci-doctor.md) | Diagnose a red CI run/check: classify flake / infra / real / config-advisory, with evidence and an executable recommended action |
| [`feature-decomposer`](agents/user/feature-decomposer.md) | Decompose a feature idea into an ordered chain of one-PR tasks (title / scope / CC type / deps / acceptance / execution mode) + a proposed feature-branch name — read-only repo scout, propose-only; consumed by feature-cycle or run standalone |
| [`task-implementer`](agents/user/task-implementer.md) | Implement ONE specified task in an isolated context — ask-first, code + tests, WIP commit, self-review, status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT); used by task-pipeline / feature-cycle in `isolated` execution mode |

## Install / sync

```bash
git clone git@github.com:Drozdetskiy/claude-skills.git ~/Development/skills   # once
~/Development/skills/install.sh --user                  # once per machine: user skills + agents
~/Development/skills/install.sh [project-dir]           # sync: auto-link what applies
~/Development/skills/install.sh add    [dir] <name>…    # force-link skill/agent (clears opt-out)
~/Development/skills/install.sh remove [dir] <name>…    # unlink + record opt-out
```

`install.sh` is idempotent: pulls the latest, symlinks the scope's skills and
agents (symlinks, not copies — library edits are picked up immediately), prunes
links left behind by renamed/removed/re-scoped items, and in project mode warns
when `.claude/skills/` or `.claude/agents/` is not git-ignored (the links are
machine-specific absolute paths and must not be committed). Sync links only the
skills whose `applies.sh` matches the repo, keeps existing links, and honors
opt-outs recorded by `remove` (in `.claude/skills/.skipped`). Re-run anytime;
only NEW sessions re-read the skill/agent list.

## Conventions

- One skill = one directory = one `SKILL.md`; templates live next to it. One
  agent = one `.md` file under `agents/<scope>/`.
- Scope is part of a skill's design: `user/` for what must be available before or
  regardless of a project (bootstraps, harnesses); `project/` for process the
  project opted into. When in doubt, ask "does invoking this make sense in a
  random repo?" — no → `project/`. The same test scopes agents.
- Agents carry role discipline; invocation prompts carry specifics. One
  parameterized agent (lens passed in the prompt) beats N near-identical agent
  files. Skills that reference agents via `agentType` must stay runnable without
  them (prompts self-sufficient, agents an upgrade).
- Every project-scope skill ships an `applies.sh` (exit 0 = applicable to the repo
  passed as `$1`) — applicability is detected by command, not judgment. Without
  one the skill links everywhere.
- Skills encode invariants and gotchas, not project specifics — project specifics
  belong in that project's `CLAUDE.md`.
- No `model:` pins in frontmatter — skills inherit the session model.
- Every gotcha listed cost real debugging time; keep it that way.
- Several long-lived literals are multi-homed across the three bootstraps (+
  `gh-fork-safety`) rather than living in one place: the feature-branch / squash+rebase
  merge model, the CLAUDE.md "Branching & merging" paste-block (asserted byte-identical
  in all three — diff them, don't eyeball; `./check-consistency.sh` enforces it), the
  gh-2.93 squash-merge REST-PATCH one-liner, the PR-title-lint event/scope rule, and
  `.releaserc`. When any changes, grep ALL skills for the OLD literal before committing
  — desync between skills is a recurring bug.
- The skill content a session serves is a SNAPSHOT taken at session start — a
  session that outlives a library commit keeps quoting the old text. When editing
  or fact-checking skills mid-session, always go through the library repo path
  (`~/Development/skills/...`), never the installed view.

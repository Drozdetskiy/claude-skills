# Claude Code skills

Personal skill + agent library for [Claude Code](https://claude.com/claude-code) —
battle-tested playbooks distilled from real projects. Each skill is a directory with
a `SKILL.md` (frontmatter `name`/`description` + the playbook) and optional
`templates/`; each agent is a single `.md` subagent definition.

Everything is **user scope**: `install.sh` links `skills/` into `~/.claude/skills` and
`agents/` into `~/.claude/agents` once per machine, so every skill and agent is
available in every session. A skill's `description` states when it applies (e.g. "in a
repo on the semantic-release-on-main model", "async SQLAlchemy + asyncpg service") — that
prose is the gate; there is no per-repo linking.

## Skills

| Skill | Use for |
|---|---|
| [`ios-app-bootstrap`](skills/ios-app-bootstrap/SKILL.md) | New iOS app repo: XcodeGen + SwiftUI skeleton, fastlane match signing, main + ephemeral feature branches (GitHub Flow) with semantic-release shipping every feature to TestFlight, PR test CI with snapshot-safe Xcode pinning, day-one testability seams |
| [`backend-repo-bootstrap`](skills/backend-repo-bootstrap/SKILL.md) | New Python/FastAPI backend repo: uv + mise toolchain, CI with Postgres service containers, branch protection, conventional commits + semantic-release on main with ephemeral feature branches (GitHub Flow), multi-stage Docker, OIDC-based AWS release pipeline |
| [`python-library-bootstrap`](skills/python-library-bootstrap/SKILL.md) | New redistributable Python package for PyPI: uv toolchain, hatchling + hatch-vcs dynamic versioning (git tag = version), ruff + mypy, multi-version pytest matrix behind one gate check, semantic-release on main, tokenless Trusted-Publishing (OIDC) to PyPI; public or private repo |
| [`adversarial-diff-review`](skills/adversarial-diff-review/SKILL.md) | Multi-agent review of a branch diff: parallel lens reviewers (incl. substrate-contract — dependency claims checked against installed sources), each finding adversarially verified by an independent refuter; `light` mode = correctness + substrate-contract + spec-compliance only, for small diffs and budget runs |
| [`doc-code-audit`](skills/doc-code-audit/SKILL.md) | Multi-agent audit of a planning doc against the codebase: per-section claim verifiers, cross-task lenses (contradictions/ordering/coherence), adversarial adjudication |
| [`task-handoff-spec`](skills/task-handoff-spec/SKILL.md) | Write a task spec a fresh session (possibly in another repo) executes without re-deriving context: scout target-repo conventions, decisions with rationale, adversarial test cases, dated file:line citations |
| [`gh-fork-safety`](skills/gh-fork-safety/SKILL.md) | Run gh/git in a fork or multi-remote checkout: `gh repo set-default` before any query, pin `--repo/--base/--head`, the phantom-upstream failure mode, gh flag drift across versions |
| [`session-retro`](skills/session-retro/SKILL.md) | Mine Claude Code session transcripts for reusable knowledge: retro the current session or mine all recent ones, pull human prompts with jq (not whole transcripts), filter programmatic sdk-cli runs, cluster recurring asks, route each to a new skill / template fix / rule / memory — proposes, never auto-creates |
| [`task-pipeline`](skills/task-pipeline/SKILL.md) | Drive one task from idea/issue to a squash-merged task-PR: issue authoring, plan as issue comment, size-scaled review gate, a CC PR title you confirm before it opens, check babysitting, optional auto-merge; target mode solo (no feature name → PR base = main, the merge is the release, Fixes #N closes the issue) or feature (feature name → PR base = that branch, ship-feature releases later); autonomy modes plan / push / auto |
| [`ship-feature`](skills/ship-feature/SKILL.md) | Ship a finished feature branch to main: config preflight (diff new settings, verify/apply each layer), rebase-merge feature→main, watch semantic-release/deploy/smoke, recover from red smoke without a new version |
| [`feature-cycle`](skills/feature-cycle/SKILL.md) | Drive a whole feature idea to a ready-to-ship branch: decompose into an ordered task chain (feature-decomposer), approve it once, run each task through task-pipeline sequentially and autonomously (auto-merge on green, self-heal red), aggregate config keys, stop at the ship gate; modes auto / push |
| [`ios-localization`](skills/ios-localization/SKILL.md) | Localize an iOS app + its App Store listing into N languages: language-store plumbing, agent fan-out translation with per-language register rules, economical fixture/snapshot policy, ASC name-availability check, metadata-only deliver |
| [`llm-structured-outputs-hardening`](skills/llm-structured-outputs-hardening/SKILL.md) | Harden an OpenAI(-compatible) Structured Outputs layer: enforce array cardinality in the schema not via retries, catch the SDK errors that bypass APIError, survive reasoning_effort enum drift, asymmetric per-finish-reason resample, latency-as-fallback-signal |
| [`llm-prompt-i18n`](skills/llm-prompt-i18n/SKILL.md) | LLM prompt templates + multilingual output: str.format brace escaping, the literal-leak / negative-instruction anti-pattern, one source of truth for the active language, scoping localization (AI content is free, only static strings need work) |
| [`postgres-async-concurrency`](skills/postgres-async-concurrency/SKILL.md) | Concurrency/idempotency on async SQLAlchemy + asyncpg: the EvalPlanQual FOR UPDATE trap, get_or_create lying under races, non-blocking advisory locks for replay, position-bearing array ordering, loop-bound pool disposal in tests |

## Agents

| Agent | Use for |
|---|---|
| [`diff-reviewer`](agents/diff-reviewer.md) | One lens of a multi-lens diff review (lens passed in the prompt) — findings with file:line evidence; used by adversarial-diff-review and task-pipeline |
| [`finding-refuter`](agents/finding-refuter.md) | Adversarial verification of ONE finding — tries to refute it against the actual code (incl. dependency sources), defaults to not-real |
| [`ci-doctor`](agents/ci-doctor.md) | Diagnose a red CI run/check: classify flake / infra / real / config-advisory, with evidence and an executable recommended action |
| [`feature-decomposer`](agents/feature-decomposer.md) | Decompose a feature idea into an ordered chain of one-PR tasks (title / scope / CC type / deps / acceptance / execution mode) + a proposed feature-branch name — read-only repo scout, propose-only; consumed by feature-cycle or run standalone |
| [`task-implementer`](agents/task-implementer.md) | Implement ONE specified task in an isolated context — ask-first, code + tests, WIP commit, self-review, status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT); used by task-pipeline / feature-cycle in `isolated` execution mode |

## Install / sync

```bash
git clone git@github.com:Drozdetskiy/claude-skills.git ~/Development/skills   # once
~/Development/skills/install.sh                                                # link skills + agents
```

`install.sh` is idempotent: pulls the latest, symlinks every skill and agent into
`~/.claude/skills` and `~/.claude/agents` (symlinks, not copies — library edits are
picked up immediately), and prunes links left behind by renamed/removed items. Re-run
anytime; only NEW sessions re-read the skill/agent list.

## Conventions

- One skill = one directory = one `SKILL.md`; templates live next to it. One
  agent = one `.md` file under `agents/`.
- A skill's `description` carries its own applicability — the answer to "does invoking
  this make sense here?" lives in the prose, not in a separate gate. Keep it explicit
  (name the precondition: the release model, the stack, the file that must exist).
- Agents carry role discipline; invocation prompts carry specifics. One
  parameterized agent (lens passed in the prompt) beats N near-identical agent
  files. Skills that reference agents via `agentType` must stay runnable without
  them (prompts self-sufficient, agents an upgrade).
- Skills encode invariants and gotchas, not project specifics — project specifics
  belong in that project's `CLAUDE.md`.
- No `model:` pins in frontmatter — skills inherit the session model.
- Every gotcha listed cost real debugging time; keep it that way.
- Several long-lived literals are multi-homed across the three bootstraps (+
  `gh-fork-safety`) rather than living in one place: the CLAUDE.md "Branching &
  merging" paste-block, `.releaserc`, the gh-2.93 squash-merge REST-PATCH one-liner,
  the feature-branch / squash+rebase merge model, and the PR-title-lint event/scope
  rule. `./check-consistency.sh` enforces the first three mechanically (byte-identical
  paste-block and `.releaserc` across the bootstraps; intact `PR_TITLE`/`BLANK`
  fragments wherever the REST-PATCH appears) — run it before committing a change to
  any multi-homed literal. The prose rules it cannot check: grep ALL skills for the
  OLD literal before committing — desync between skills is a recurring bug.
- The skill content a session serves is a SNAPSHOT taken at session start — a
  session that outlives a library commit keeps quoting the old text. When editing
  or fact-checking skills mid-session, always go through the library repo path
  (`~/Development/skills/...`), never the installed view.

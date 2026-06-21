---
name: task-pipeline
description: Drive one task from idea or issue number to a squash-merged task-PR on a feature branch — issue authoring, plan as an issue comment, implementation, size-scaled review gate (diff-reviewer + finding-refuter agents), Conventional-Commit-titled PR, check babysitting via ci-doctor, optional auto-merge. Modes plan / push (default) / auto. Use when asked to take an issue, implement a task, start work on a feature or bug, or run the pipeline in a repo on the semantic-release-on-main model.
---

# Task pipeline (issue → plan → implement → review → PR → feature branch)

Operational companion to ship-feature on the OTHER side of the feature branch:
this skill drives one task from idea to a squash-merged commit on a feature
branch; ship-feature then rebase-merges the finished feature into `main` (one
release). The issue is the unit of work, its number threads through branch and
PR, and the task-PR title becomes the commit and the line in the release notes.

A feature branch is a short-lived branch off `main`, **named by the developer**
(e.g. `dark-mode`); tasks squash into it; it is deleted when it ships. A small,
standalone change is its own one-task feature.

## Modes

Mode comes from the invocation (e.g. `/task-pipeline 42 dark-mode --auto`);
**default is `push`**.

| Mode | Runs through | Stops |
|---|---|---|
| `plan` | issue + plan comment | before any code — user approves the plan, re-invoke to continue |
| `push` (default) | PR open, checks driven to green | before merge — merge is the user's call |
| `auto` | squash-merge into the feature branch | only for what the user alone can provide |

`auto` is never fully unattended: secret VALUES always come from the user
(config-first — see ship-feature), and a review-gate critical the pipeline cannot
fix safely is a stop, not a guess. Everything else — red checks, refuted
findings, rebases — it handles itself. `auto` ends at the feature branch; it does
NOT ship (that is ship-feature, a separate decision).

## Execution mode — coupled (default) or isolated

Orthogonal to the autonomy mode above: autonomy is how FAR a task goes
(plan/push/auto), execution is WHO writes it. The caller sets it — feature-cycle
passes it per task from the decomposer's `execution` flag; a standalone invocation
defaults to `coupled`.

- **`coupled` (default)** — the main loop writes the code, carrying the feature's
  running context (the decisions, conventions, and code earlier tasks just landed).
  Best for tightly-coupled chains where continuity beats context hygiene; it is the
  original behaviour. Review-gate fixes are applied in place.
- **`isolated`** — the main loop is the CONTROLLER: it constructs a self-contained
  brief and dispatches a fresh `task-implementer` subagent to write the code, then
  runs the review gate on what comes back. Best for self-contained tasks — the
  implementer's context stays clean and a long chain doesn't flood the controller.
  Two rules keep that benefit: (1) curate the brief from the CURRENT feature-branch
  code at dispatch time (this is why the decomposer ships skeletons, not frozen
  specs that go stale); (2) when review finds issues, **re-dispatch the implementer
  or a fix subagent — never fix in the controller's context**, which reintroduces
  the pollution the mode exists to avoid. Honour the implementer's status:
  `BLOCKED`/`NEEDS_CONTEXT` → add context, escalate the model, split the task, or
  stop to the human; never force the same model to retry unchanged.

This is subagent-driven-development applied per task and gated on the dependency
graph, not universally: coupled work keeps its shared context, isolated work gets a
clean one.

## Procedure

1. **Preflight**: in a multi-remote checkout pin gh first (`gh repo set-default
   OWNER/REPO` — wrong-repo answers look plausible and cost real debugging time).
   Confirm the model (`.releaserc` present; `main` is default and protected — full
   check in ship-feature) — if absent, stop and offer the bootstrap instead.
2. **Entry**: given an issue number, read it; given a raw idea, author the issue
   first — `gh issue create` with an imperative title (NOT a conventional-commit
   title: the type is unknown yet and lives in the PR title anyway) and a body
   with the problem, acceptance criteria, and constraints. Write the body so a
   fresh session could implement from it alone (task-handoff-spec discipline:
   decisions WITH rationale, not just conclusions).
3. **Feature branch**: determine which feature this task belongs to — the
   developer names it (passed in the invocation, or ask). Start it from fresh
   `main` if it does not exist yet:
   `git fetch && git switch main && git pull && git switch -c <feature> && git push -u origin <feature>`.
   If it exists, `git switch <feature> && git pull`. Do NOT open the feature→`main` PR during
   the chain — an open PR re-runs its checks (`test` + `config-preflight`) on every
   task merge into the feature branch, burning CI minutes for nothing until ship.
   ship-feature opens it once, at ship; the feature's new config keys are surfaced
   meanwhile by each task's report and feature-cycle's aggregation.
4. **Plan**: scout the code the task touches (conventions, integration points,
   existing seams), then post the plan as an ISSUE COMMENT — approach, files,
   tests, risks, and any decision taken with its why. The issue thread is the
   spec's home: branch and PR link back to it. In `plan` mode — stop here with the
   comment link.
5. **Branch**: `gh issue develop <N> --base <feature> --checkout` — GitHub creates
   `<N>-<slug>` from the feature branch and links it to the issue's Development
   section.
6. **Implement — `coupled` (default) or `isolated`** (see Execution mode): in
   `coupled` mode the main loop writes the code + tests directly, carrying the
   feature's running context. In `isolated` mode, dispatch one `task-implementer`
   subagent with a self-contained brief — the full task text, the context you
   curate from the CURRENT feature-branch code (the step-4 scout, the decisions and
   conventions that hold), and the working dir/branch — then act on its returned
   status (`DONE`/`DONE_WITH_CONCERNS`/`BLOCKED`/`NEEDS_CONTEXT`). If the agent
   isn't installed, the same brief works inline. Either way: branch commits may be
   sloppy WIP checkpoints (they die at squash; the bar is the code and tests, not
   the commit log), and the project's suite runs locally before the review gate.
7. **Review gate — scaled by diff size AND execution mode**: in `isolated` mode the
   controller never saw the code, so the gate is NON-optional and runs at least a
   spec-compliance lens (built EXACTLY to the task's acceptance — nothing missing,
   nothing extra) AND a correctness lens via `diff-reviewer`, each finding through a
   `finding-refuter` ("don't trust the report — read the code"). In `coupled` mode
   the size scale applies: small, mechanically simple diff → one `diff-reviewer`
   (correctness lens) + a `finding-refuter` on each finding; large or risky diff
   (hundreds of lines, or touching public contract / auth / concurrency / money) →
   full adversarial-diff-review (lens panel + refuters). Fix what survives
   refutation (see Execution mode for WHERE the fix goes), re-run tests. In `auto`
   mode this gate substitutes for human review — do not skip it for "trivial"
   changes that touch risky surface.
8. **Task-PR**: base = the feature branch. Title = Conventional Commit
   (`feat:`/`fix:`/…, breaking → `!`) — this exact string becomes the commit on
   the feature branch and the changelog line, so write it for the release-notes
   reader. Body: a summary for the reviewer + a link to the issue (`Task #N` /
   `Part of #N`, NOT `Fixes #N` — the feature branch isn't the default branch, so
   a closing keyword would not fire on this merge). Push, `gh pr create --base
   <feature>`. The PR-title lint also runs on `edited` — fix the title, not the
   lint.
9. **Checks**: `gh pr checks --watch`. Red → diagnose with `ci-doctor`: flake →
   rerun; real → fix on the branch and push. Note any NEW config keys the task
   introduces for the report — the `config-preflight` check itself runs on the
   feature→`main` PR (a ship-feature concern), not here. In `push` mode — stop
   here: PR link, checks green, merge is the user's.
10. **Merge** (`auto` only): `gh pr merge --squash --delete-branch` into the
    feature branch — squash puts the title-only commit on the feature branch; the
    task branch is auto-deleted. Then **close the task issue explicitly**
    (`gh issue close <N> --reason completed`) — the feature branch is not the
    default, so GitHub will not auto-close it. `git switch <feature> && git pull`.
11. **Report** (every mode): final state + PR/issue links, what survived or died
    in the review gate, and — always — any config keys the task introduced:
    "values for X, Y needed before <feature> ships". Never let a key reach a
    shippable feature unannounced.

## Hotfix

A prod emergency is just a one-task feature branched straight from `main`:
`gh issue develop <N> --base main --checkout`, fix, FULL-depth review regardless
of size, then ship immediately (ship-feature). There is no long-lived branch to
reconcile and no resync — other in-flight feature branches simply
`git rebase origin/main` when convenient after the hotfix ships.

## Gotchas

- **The pipeline ends at the feature branch, deliberately.** Merging a task
  deploys nothing; shipping the feature is a separate decision (ship-feature). Do
  not "helpfully" ship in `auto` mode.
- **Execution mode (`coupled`/`isolated`) is WHO writes; autonomy
  (`plan`/`push`/`auto`) is HOW FAR — they compose.** `auto`+`isolated` = a fresh
  `task-implementer` writes the task, the gate clears it, it auto-merges. In
  `isolated` mode never fix the implementer's work in the controller's context —
  re-dispatch, or a long chain loses the context hygiene the mode bought.
- **Issue titles vs PR titles carry different things**: issue = imperative
  description of the work; PR = conventional commit for the changelog. Copying the
  issue title into the PR usually produces a bad changelog line.
- **Task issues don't auto-close** — the task PR merges into the feature branch,
  not the default branch, so close them explicitly (step 10). The work reaches
  `main` later, when the feature ships.
- **task = issue; the feature branch is developer-named** — don't invent a
  feature-level issue or derive the branch name from the task issue.
- After a sibling feature ships, in-flight feature branches sit on an older
  `main` — `git rebase origin/main` to pick up the released commits before
  shipping (they drop as patch-identical).
- Several tasks in flight on one feature branch are fine, but merge them one at a
  time and let checks re-run — two green-on-stale-base PRs can conflict
  semantically on the feature branch.

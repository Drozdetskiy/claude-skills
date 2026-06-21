---
name: feature-cycle
description: Drive a whole feature from a raw idea to a ready-to-ship feature branch — decompose the idea into an ordered task chain (feature-decomposer), get the chain approved once, then run each task through task-pipeline sequentially and autonomously (auto-merge on green, self-heal red checks), aggregate the config keys the feature needs, and stop at the ship gate. Modes auto (default) / push. Orchestrates task-pipeline and ship-feature; it does not reimplement them. Use when asked to take a feature idea from scratch, build out a feature end to end, or run a whole chain of tasks in a repo on the semantic-release-on-main model.
---

# Feature cycle (decompose → approve chain → autonomous task loop → ship gate)

The arc over task-pipeline and ship-feature: task-pipeline drives ONE task onto a
feature branch, ship-feature ships the finished branch to `main` (one release);
this skill strings the whole feature together — decompose the idea into an ordered
chain, run the chain task-by-task, and hand a ready feature branch to ship-feature.
It adds NO new mechanics. The per-task work IS task-pipeline; the heavy review
fan-out is the adversarial-diff-review Workflow that task-pipeline already launches;
shipping stays a separate decision (ship-feature). What this skill owns is the
glue: the chain, the autonomous loop, cross-task config aggregation, and two human
gates.

## Why a main-loop skill (not an agent, not a Workflow)

A subagent cannot fan out the review fleet — sub-agents cannot spawn sub-agents —
so the cycle cannot be one agent. A Workflow takes no mid-run user input (sign-off
between stages means separate workflows), but the cycle has two human gates —
chain approval and the ship decision — so it cannot be one Workflow either. It is
a procedure the main loop follows: it spawns the decomposer agent, runs
task-pipeline per task, and launches the review Workflow inside the gate. The
main-loop requirement is about the CONTROLLER — what holds the gates and dispatches
— not about who writes the code: per task the controller may implement in its own
context (`coupled`) or hand the work to a fresh `task-implementer` subagent
(`isolated`); see task-pipeline's Execution mode. Don't "simplify" it into a single
agent or a single workflow — neither primitive holds both the fan-out and the gates.

## Modes

Mode comes from the invocation (e.g. `/feature-cycle "dark mode" --push`);
**default is `auto`**. The mode IS the per-task task-pipeline mode; the two human
gates are ALWAYS on regardless of mode.

| Mode | Per task | You are in the loop at |
|---|---|---|
| `auto` (default) | implement → review gate → green → squash-merge into the feature branch | chain approval + ship gate only |
| `push` | same, but stops before merging each task PR | chain approval + every task merge + ship gate |

`auto` is autonomous EXECUTION, not unattended work: you approve the chain first,
shipping is still yours, and the cycle stops to ask only for what only you can give
(see Genuine stops). In `auto` the size-scaled review gate SUBSTITUTES for human
review — green CI checks alone are not the merge bar; surviving the gate is.

## Procedure

1. **Preflight** — pin gh in a multi-remote checkout (`gh repo set-default
   OWNER/REPO`; see gh-fork-safety). Confirm the model: `.releaserc` present,
   `main` default and protected (full check in ship-feature) — if absent, stop and
   offer the bootstrap. Confirm `.tasks/` is git-ignored (the chain doc is local
   scratch); if not, warn before writing it.
2. **Decompose** — spawn `feature-decomposer` (`agentType: feature-decomposer`,
   structured output) with the idea and the repo path. If the agent isn't
   installed, run the same prompt inline — the prompt is self-sufficient, the agent
   is an upgrade. Write its result to `.tasks/<feature>.md`: the agent is read-only,
   the cycle writes the doc.
3. **Gate 1 — approve the chain (always; yours).** Show the chain and the proposed
   branch name. The developer edits or confirms the name — it is theirs to choose;
   the decomposer only proposed. STOP until "go". Skipping this gate would let an
   LLM's decomposition become N issues and N merged PRs before anyone looked.
4. **Task loop (sequential).** For each task in order, run the task-pipeline
   procedure — do not duplicate it — seeding its issue authoring with the task node
   (title, scope, acceptance, scout findings); task-pipeline creates the issue, not
   the decomposer. The invocation mode (`auto`/`push`) is task-pipeline's autonomy
   mode; also pass each task's execution mode (`coupled`/`isolated`, from the
   decomposer's `execution` flag, default `coupled`) — `coupled` runs in this
   context, `isolated` goes to a fresh `task-implementer` subagent (task-pipeline
   §Execution mode). Branch the task off the feature branch; before merging, bring the task branch
   current with the feature tip (a check that was green on a stale base can go red
   once merged). In `auto`, after each task merges, confirm the feature branch
   itself is green before the next task — integrate one at a time and let checks
   re-run.
5. **Red after a merge → fix forward, don't stop.** A red feature branch after a
   task merged is fix-first, not a gate: ci-doctor → flake: rerun; real: fix on the
   feature branch. The task branch is gone, but the feature branch is ephemeral,
   unprotected, and yours sequentially — amend the squash tip or add a follow-up
   commit (`git push --force-with-lease` is fine; nothing long-lived tracks the
   tip). Escalate to a stop only if the fix would be a guess.
6. **Genuine stops — mid-chain, only two classes.** (a) Something cannot be fixed
   safely without guessing: a review-gate critical that survived refutation, or a
   red check whose correct fix is ambiguous. (b) A value or secret only you have
   (config-first — values are never invented). Tasks are sequential, so a hard stop
   on task N halts the rest of the chain; report where it stopped and why.
   Everything else — red checks, refuted findings, rebases — the cycle handles
   itself.
7. **Aggregate config.** task-pipeline reports the config keys each task introduces;
   the cycle accumulates them across the whole feature for the ship handoff. The
   `config-preflight` check on the feature→`main` PR re-detects them — this
   aggregate is the human-facing summary, not a substitute for that gate.
8. **Gate 2 — ship (always; stop before `main`).** When the chain is done, STOP.
   Report: the feature branch, the N task commits and the bump they imply, and the
   aggregated config keys — "feature ready; needs values for X, Y before it ships;
   run ship-feature when provisioned." Do NOT ship: that is ship-feature, a
   separate decision (the config values and the ship call are both yours).

## Resume

`.tasks/<feature>.md` plus gh/git state IS the cycle's memory — there is no
in-flight state to lose. Re-invoking reads the doc, reconciles against the repo
(which task issues are closed, which PRs merged into the feature branch), and
continues from the first unfinished task. An interrupted cycle is restartable, not
restarted.

## Gotchas

- **The cycle ends before ship, deliberately.** A full feature branch deploys
  nothing; shipping is ship-feature. Do not "helpfully" ship after the last task.
- **Chain approval is not optional, even in `auto`.** `auto` automates execution of
  an APPROVED plan; the decomposition itself is never auto-executed unseen.
- **In `auto` the review gate is the only thing standing in for a human reviewer** —
  do not skip it for "trivial" diffs that touch risky surface (auth, money,
  concurrency, public contract). Green CI is regression coverage, not review.
- **task = issue; the developer names the feature branch.** The decomposer proposes
  a name and the chain; it does not create issues and does not invent a
  feature-level issue.
- **Tasks are sequential on one branch.** Don't parallelize task branches off the
  feature — two green-on-stale-base PRs can conflict semantically once merged.
- **Execution mode comes from the decomposer's graph, not a global switch.** Most
  chains are coupled (continuity); `isolated` is the per-task exception for
  self-contained work. Don't flip a whole chain to `isolated` to "go faster" — a
  mis-fed isolated task drifts off the feature's decisions.
- **`.tasks/` is local scratch** — `.tasks/<feature>.md` is the cycle's git-ignored
  state (preflight step 1 enforces it), never committed, not a repo artifact.

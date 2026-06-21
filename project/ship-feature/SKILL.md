---
name: ship-feature
description: Ship a finished feature branch to main — config preflight (diff new settings since the last release, verify and apply each layer with the user), rebase-merge the feature into main, watch the release run, recover from red smoke without a new version. Use when asked to ship/release a feature, cut a release, or merge a feature branch into main in a repo on the semantic-release-on-main model (set up by backend-repo-bootstrap / ios-app-bootstrap).
---

# Ship a feature (preflight → rebase-merge → watch → recover)

Operational companion to task-pipeline: task-pipeline fills a feature branch
(squash-merged task PRs); this skill SHIPS it — rebase-merges the feature into
`main`, which cuts ONE release via semantic-release. Shipping IS the deploy.

## Why a procedure

Merging the feature into `main` IS the deploy. Code that needs out-of-band
settings (server `.env`, GitHub secrets/vars, Terraform) must wait until the
config exists: **config-first, code-second** (removal is the reverse — code stops
reading first, config is removed after). A missing runtime var crashloops the new
container with prod already switched over. **The feature branch IS the waiting
slot** — hold it (don't merge) until its config is in place.

## Preconditions — run BEFORE anything else

First, in a multi-remote checkout (origin + a fork parent as `upstream`), pin gh
to the right repo: `gh repo set-default OWNER/REPO`. Without it gh silently
resolves `{owner}/{repo}` to EITHER remote and returns that repo's rulesets,
default branch, and PR list — wrong-repo answers look plausible and cost real
debugging time.

Then verify the repo is on this model; each check is one command: `.releaserc`
present at the root; the release workflow triggers on `push: branches: [main]`
(not on tags); `main` allows rebase-merge and squash but NOT merge commits
(repo merge settings + the `required_linear_history` rule). If any fail — **stop**:
this repo is not on the model. Do not improvise a hybrid; offer the migration
(backend-repo-bootstrap / ios-app-bootstrap) instead.

## Procedure

1. **Assemble**: `git log $(git describe --tags --abbrev=0 origin/main)..origin/<feature> --oneline`
   — the task commits that will land on `main` and the bump they imply (highest
   type wins; any `!` → major; on a `0.x` base a `!` jumps straight to `1.0.0`).
2. **Config diff** (pure git, no cloud access): diff `origin/main..origin/<feature>`
   over the settings surface — the app settings class (pydantic `Settings`
   fields), compose/Dockerfile `${VAR}` references, workflow `secrets.*`/`vars.*`
   references, `terraform/` changes. Extract NEW keys; classify each by layer:
   server runtime (instance `.env`) / GitHub secrets-vars / infra.
3. **Verify and apply with the user** — presence only; values are not
   machine-checkable, and secret values must come from the user, never invented:
   - GitHub: `gh secret list` / `gh variable list` (needs an admin-scoped token —
     the workflow `GITHUB_TOKEN` cannot list secrets).
   - Server: SSM Run Command printing key NAMES only (`cut -d= -f1`) — output
     lands in logs/CloudTrail; never print values.
   - Terraform: applied before the merge (`plan` clean).
4. **Smoke sanity**: if the feature changes endpoints / status codes / `detail`
   codes / response shapes, update the smoke script IN the feature before
   shipping — a stale smoke fails the release AFTER the deploy.
5. **Ship**: open the feature→`main` PR if it isn't already (freeform title — it
   is discarded by the rebase-merge), confirm `test` is green, then
   **rebase-merge** it — never squash (collapses the feature to one changelog
   line), never merge-commit (the linear-history rule rejects it). Let
   "Automatically delete head branches" remove the feature branch. Watch the
   release run: the semantic-release verdict ("Analysis of N commits" must equal
   the task commits since the last tag — wrong N means it lost the base tag, check
   `fetch-depth: 0`), the config gate, deploy, smoke.
6. **After the run**: nothing to resync — the feature branch is gone and `main`
   moved forward linearly. Locally `git checkout main && git pull`. OTHER
   in-flight feature branches need `git rebase origin/main` when convenient
   (their base advanced — rebase per task-pipeline's Gotchas on in-flight branches).
7. **Recovery — red smoke means prod is already on the new code**: missing config
   → apply it → `workflow_dispatch` re-runs gate+deploy+smoke for the current
   version. No new release needed; a `ci:`-typed smoke fix alone never cuts one —
   dispatch IS the re-run path. Do not re-run the failed run itself: it checks out
   the old ref and can never see the fix.

## Enforcement layers (don't rely on memory)

- **Feature-PR advisory job** (`config-preflight`): diff-only detection — fails
  the check with "this feature introduces keys X, Y" so a forgotten setting is
  visible at review time. Deliberately NO cloud access: a PR-event job carries
  OIDC sub `refs/pull/...` and must not pass the role trust policy (scoped to
  `refs/heads/main`) — do not widen the trust policy to PRs.
- **Hard gate at the START of the release job** (which already holds the role and
  shell access anyway): verify key presence on the instance BEFORE deploying and
  fail fast while the old container still serves. A deploy-time gate beats a
  merge-time gate — it checks at the moment of application. Run it (and its
  AWS/SSH setup) on EVERY push to `main`, not only releasing ones — a no-release
  feature re-checks drift for free, so a missing key surfaces before a release
  depends on it.
- **App boot validation** (pydantic-settings required fields) — the last line:
  crash fast with a clear message instead of half-working.

## Gotchas

- **Only presence is checkable, never correctness** — a key can exist with a
  wrong value; smoke is what catches that.
- `GITHUB_TOKEN` cannot list repo secrets; per-key presence can be tested via env
  mapping (`env: { FOO: ${{ secrets.FOO }} }` + `if: env.FOO != ''`).
- A workflow referencing a missing secret silently gets an empty string —
  config-first applies to CI-consumed settings too.
- A red `config-preflight` is NOT a merge blocker and can never turn green for
  that feature (diff-based — the keys stay "new" however many times you re-run
  it). Apply the config, then merge with the check still red; it is advisory by
  design, never a required check. A bootstrap/migration feature is BORN red (it
  introduces the OIDC terraform change itself) — expected.
- **No resync, ever** — the feature branch is deleted on merge, so nothing
  long-lived survives to diverge from `main` (this is the whole reason the model
  dropped a long-lived `dev`). If a new PR's diff ever re-shows already-merged
  commits, its branch is on a stale base: `git rebase origin/main`.
- Changes to the release pipeline itself (action majors, gate logic, workflow
  restructure) deserve their own `ci:`-typed no-release feature: it live-verifies
  the new pipeline for free — semantic-release loads, the gate runs — before any
  `feat`/`fix` feature depends on it.
- This model usually runs in sibling repos (backend + iOS app). A pipeline flaw
  fixed in one repo almost certainly lives in the sibling — grep it for the same
  pattern in the same session (mirror of the skills-repo convention).
- iOS: the config surface is the ASC/match secrets (they rarely change) — same
  procedure, different deploy slot (fastlane/TestFlight).

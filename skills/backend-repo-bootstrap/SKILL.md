---
name: backend-repo-bootstrap
description: Bootstrap a Python/FastAPI backend repo — uv + mise toolchain, GitHub Actions CI with Postgres service containers, branch protection, conventional commits + semantic-release on main with ephemeral feature branches (GitHub Flow), multi-stage Docker, OIDC-based AWS release pipeline. Use when creating a new backend repo or modernizing toolchain/CI/CD in an existing one. For iOS repos use ios-app-bootstrap instead.
---

# Backend repo bootstrap (Python/FastAPI → AWS)

Battle-tested playbook (distilled from a FastAPI/PostgreSQL/AWS backend). Adapt names; keep the shape. Verify every layer as you go — the Verification section is mandatory, not optional.

## Checklist (ordered phases)

1. Create the repo; `main` is the only long-lived branch and the default
2. Pin the toolchain: `.python-version`, `pyproject.toml` (uv), `mise.toml` tasks
3. Lint/format config (ruff) — re-check rules after `requires-python` lands
4. Committed `.env.test` with dummy creds for hermetic CI tests
5. CI workflows: `lint` + `test` (Postgres service container matching prod), plus an advisory `config-preflight` on feature→`main` PRs
6. Commit/branch conventions in CLAUDE.md: main + ephemeral feature branches (GitHub Flow), conventional PR titles
7. Branch protection ruleset, merge strategy (squash task→feature, rebase-merge feature→main), PR-title lint
8. Multi-stage Dockerfile (uv, non-root, stdlib healthcheck)
9. AWS OIDC role for GitHub Actions (Terraform), scoped to the `main` ref
10. GitHub secrets/variables split
11. Dedicated deploy SSH key, delivered over SSM
12. Release workflow on main: semantic-release (version → tag → GitHub Release) → build → push → deploy → smoke
13. Verification (every layer)

## 1. Repo creation

```bash
gh repo create OWNER/REPO --private --source . --push
```

One branch, `main`, and it stays the default — there is no long-lived `dev` in this model. Work happens on short-lived feature branches off `main` (developer-named) that rebase-merge back and are deleted; releases are cut from `main` by semantic-release. Because task PRs target a feature branch (not the default branch), `Fixes #N` will NOT auto-close their issues on that merge — see §6/§7 for how task issues are closed.

## 2. Toolchain: uv + mise

Three files at repo root. `.python-version` holds just the version (e.g. `3.14`). `pyproject.toml` is the uv manifest — exact pins for runtime deps, dev tools in `[dependency-groups]`, and for a non-installable flat layout:

```toml
[project]
requires-python = ">=3.14"
dependencies = ["fastapi==0.136.3", "uvicorn==0.49.0", ...]   # exact pins

[dependency-groups]
dev = ["ruff==0.15.16", "pytest==9.0.3", "pytest-asyncio==1.4.0", "pytest-cov==7.1.0"]

[tool.uv]
package = false
```

Run `uv lock` and commit `uv.lock`. **Declare every binary you invoke** (ruff, pytest) as a dev dep — pipenv-era setups often relied on globally installed tools; `uv run ruff` fails if ruff isn't in the manifest.

`mise.toml` replaces the Makefile: `[tools]` pins tool versions, `[tasks.*]` are the command surface. Tasks run through `uv run`, which auto-syncs `.venv` against `uv.lock`:

```toml
[tools]
uv = "0.11"

[tasks.install]
run = "uv sync --dev"
[tasks.test]
run = "uv run pytest tests/ -v"
[tasks.lint]
run = "uv run ruff check ."
```

**Parameter convention: env-prefix, not make-style trailing vars.** `make smoke SMOKE_TOKEN=x` becomes `SMOKE_TOKEN=x mise run smoke`; in the task body read `"${VAR:-default}"`. Secrets always via environment, never as CLI args (not echoed, not in argv). Compose tasks by nesting `mise run` — this works and is the intended pattern:

```toml
[tasks.smoke-anon]
run = '''
SMOKE_TOKEN="$(bash scripts/smoke-anon-token.sh)" mise run smoke
'''
```

**`.gitignore`** — beyond the Python/tooling caches, ignore the local and machine-specific paths that must never be committed (`.claude/skills/` and `.claude/agents/` are `install.sh` symlinks: absolute paths meaningless on another machine; `.claude/settings.local.json`, `.claude/worktrees/`, and `.tasks/` are per-checkout state):

```gitignore
# OS / editor
.DS_Store
.idea/

# Claude Code (machine-specific — local settings, symlinked skills/agents, worktrees)
.claude/settings.local.json
.claude/skills/
.claude/agents/
.claude/worktrees/

# Task queue
.tasks/
```

## 3. Lint config

When `pyproject.toml` with `requires-python` first appears, ruff infers a new `target-version` and **new rule families fire** on code that previously passed. Triage them; do not blind `--fix`. In particular keep `TC001/TC002/TC003` ignored for FastAPI/pydantic code — they move imports under `TYPE_CHECKING`, but DI and pydantic introspect annotations at runtime, so the "fix" NameErrors at import time.

## 4. Committed `.env.test`

Commit a `.env.test` with **dummy** values (header comment: "Safe to commit — no real credentials"): test DB DSN pointing at `localhost:5432`, fake API keys, monitoring disabled. The test conftest loads it; CI needs zero secret configuration for tests.

## 5. CI workflow — `.github/workflows/ci.yml`

`ci.yml` carries two jobs, `lint` and `test`, on `pull_request:` (every PR, any base — task PRs into feature branches AND feature PRs into `main`) plus a `concurrency: ci-${{ github.ref }}` / `cancel-in-progress: true` group. (A third, separate `config-preflight.yml` workflow runs on feature→`main` PRs only — see the end of this section.) PR-only is deliberate: every push to `main` is a feature rebase-merge and release.yml runs the same lint+test job there — a `push: [main]` trigger would double-run the suite on every release. Shared setup: `actions/checkout@v5`, `jdx/mise-action@v4` with `cache: true`, plus a uv package cache keyed on the lockfile:

```yaml
      - uses: jdx/mise-action@v4
        with:
          cache: true
      - uses: actions/cache@v5
        with:
          path: ~/.cache/uv
          key: uv-${{ runner.os }}-${{ hashFiles('uv.lock') }}
      - run: mise run install
```

The `test` job runs a Postgres **service container pinned to the same major as prod**:

```yaml
    services:
      postgres:
        image: postgres:16-alpine        # same major as prod compose
        env: { POSTGRES_USER: app, POSTGRES_PASSWORD: app, POSTGRES_DB: app_tests_db_local }
        ports: ["5432:5432"]
        options: >-
          --health-cmd "pg_isready -U app"
          --health-interval 5s --health-timeout 5s --health-retries 10
```

The DSN in `.env.test` hits `localhost:5432` = this container. No mocked DB.

### config-preflight — advisory, on feature→`main` PRs

A separate workflow `.github/workflows/config-preflight.yml` is the `config-preflight`
check the operational skills (ship-feature / task-pipeline / feature-cycle) refer to — the
FIRST config-first enforcement layer (the enforcing one is the release job's config gate,
§12). Diff-only, **no cloud access**: a PR-event job's OIDC sub is `refs/pull/*` and must
not pass the deploy role's trust policy (scoped to `refs/heads/main`) — don't widen it.

```yaml
name: Config preflight
on:
  pull_request:
    branches: [main]          # feature→main PRs only — task→feature PRs carry no config decision
jobs:
  config-preflight:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0      # the diff needs the base ref, not just the merge commit
      - run: python3 scripts/config_preflight.py "origin/${{ github.base_ref }}"
```

`scripts/config_preflight.py` diffs the base ref against the feature over the settings
surface — pydantic `Settings` fields, compose/Dockerfile `${VAR}`s, workflow
`secrets.*`/`vars.*`, `terraform/` — and exits non-zero listing the NEW keys, so a
forgotten setting is visible at review time. **Advisory, never a required check**: it is
diff-based, so it stays red for a feature that genuinely adds config (apply the config,
then merge with it still red); a bootstrap/migration feature is born red (it introduces the
OIDC/terraform change itself). Enforcement is the release job's config gate (§12), which
checks key PRESENCE on the instance at deploy time. iOS has no equivalent — its config
surface is static ASC/match secrets, so ios-app-bootstrap ships no `config-preflight`.

## 6. Commit and branch conventions

Paste this block into the new repo's CLAUDE.md — it is what makes every future session pick the right merge button without re-deriving the model. Keep it verbatim-identical with the copy in ios-app-bootstrap §6:

```markdown
## Branching & merging

- `main` is the only long-lived branch and the default — never commit to it directly.
- A feature gets a short-lived branch off `main`, named by you (e.g. `dark-mode`),
  deleted after it ships. A small change is its own one-task feature.
- Task branches: `<issue>-<slug>` (create via `gh issue develop <N> --base <feature> --checkout`),
  one single-purpose change per branch, cut from the feature branch.
- Task PRs target the feature branch, merged with **squash** only. The PR title becomes the
  commit and MUST be a Conventional Commit: `<type>(<scope>?): <imperative summary>` — types
  `feat fix chore docs refactor ci test perf`, lowercase, no trailing period, ≤72 chars;
  breaking changes are `!` on any type (`feat!:`). Branch commits may be messy — only the PR
  title matters. The task issue is closed on this merge (`gh issue close <N>` — the feature
  branch is not the default, so GitHub will not auto-close it).
- Feature → `main` PRs are merged with **rebase** only — never squash (it collapses the
  feature into one changelog line), never merge-commit (keeps `main` linear). The task
  commits land on `main` one by one; semantic-release cuts ONE release per feature, bump =
  the highest type in the batch. The feature-PR title is freeform — rebase-merge discards it.
- The task-PR title is the changelog entry — write it for the release-notes reader.
- Never add AI co-authorship trailers to commits or PRs.
```

Context for the skill user (not for CLAUDE.md): `gh issue develop` also LINKS the branch to the issue — the name alone links nothing; without issues use `<NNNN>-<slug>` or plain `<slug>`. A type prefix in the branch name would just drift into a lie when the change turns out to be a fix — the type lives only in the PR title, where it is load-bearing and linted. Issues do NOT auto-close on the task→feature merge (auto-close fires only on the default branch, `main`), so close them explicitly when the task lands; the code reaches `main` later, when the feature ships. Each merged PR should capture a user-visible outcome; churn lives in the diff.

## 7. Branch protection + squash merge

Ruleset via the API (the `gh` CLI has no ruleset subcommand):

```bash
gh api repos/{owner}/{repo}/rulesets -X POST --input - <<'EOF'
{
  "name": "main", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
        "require_last_push_approval": false, "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "lint" }, { "context": "test" } ] } }
  ]
}
EOF
```

0 approvals is correct for a solo repo — PRs are still required, just self-mergeable. Contexts must equal the CI **job names**. The `required_linear_history` rule keeps `main` a straight line — it permits rebase-merge and squash but blocks merge commits, so a feature can never land as a merge node. `main` is the default branch, so `~DEFAULT_BRANCH` would also work here; `refs/heads/main` is explicit and unambiguous. Then make squash merges inherit the PR title (so conventional PR titles become conventional commits):

```bash
gh api repos/OWNER/REPO -X PATCH -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK
```

(`gh repo edit --squash-merge-commit-title` no longer exists in current gh — 2.93 dropped it; the REST PATCH is version-proof.)

`PR_TITLE` must be explicit — GitHub's DEFAULT takes the commit message for
single-commit PRs, so a clean PR title over one `wip` commit would land as `wip`.
`BLANK` keeps commits title-only: breaking changes are `!` on ANY type (`feat!`,
`fix!`, `refactor!`) — no `BREAKING CHANGE:` footers to manage, but the
commit-analyzer must run the `conventionalcommits` preset (the default angular
preset ignores `!`).

Merge strategy is two-lane, set repo-wide: enable **squash** and **rebase-merge**,
disable merge commits
(`gh api repos/OWNER/REPO -X PATCH -f allow_merge_commit=false -f allow_squash_merge=true -f allow_rebase_merge=true`).
**Squash** is the task→feature lane (the PR title carries the release semantics; branch
commits may be sloppy WIP). **Rebase-merge** is the feature→`main` lane — it replays the
squashed conventional commits onto `main` one by one, linearly, and semantic-release cuts
one release per feature. `main` requires `lint`+`test` on the feature PR. There is no
long-lived branch to protect besides `main` and no post-merge resync, so **no bypass actor
is needed** — the personal-repo 422 ("Actor GitHub Actions integration must be part of the
ruleset source or owner organization") that the old dev-resync force push tripped over
simply never arises. Turn repo-level **"Automatically delete head branches" ON**
(`gh api repos/OWNER/REPO -X PATCH -f delete_branch_on_merge=true`): it deletes task
branches after the squash and feature branches after the rebase-merge — both are meant to
be ephemeral.

Add a PR-title lint (commitlint or `amannn/action-semantic-pull-request`) on the
`pull_request` event — NOT `pull_request_target`: the title comes from the event
payload, so the write-scoped token `pull_request_target` grants buys nothing and
needlessly exposes secrets to PR-head context. Trigger on `opened|edited|synchronize`
— without the `edited` event a PR can be renamed to garbage after the check went green.
Scope it to PRs whose base is NOT `main` (`branches-ignore: [main]`): the CC titles
live on task→feature PRs; a feature→`main` PR title is freeform and discarded by the
rebase merge, so linting it is pure noise. Keep this check **advisory — do NOT add it
to `main`'s `required_status_checks`**. It cannot be a required check in this model:
task→feature PRs target ephemeral, unprotected feature branches (required checks aren't
enforced there), and it never runs on feature→`main` PRs — so listing `PR title` under
`main`'s required checks would deadlock every feature→`main` merge (the check never
reports there, so the status stays pending forever). It is a visible red-X nudge on the
task→feature PR, where the title becomes the squash commit and the changelog line.

## 8. Dockerfile (multi-stage, uv)

Load-bearing lines — builder stage:

```dockerfile
# syntax=docker/dockerfile:1.7
FROM python:3.14-slim AS builder
WORKDIR /app
COPY --from=ghcr.io/astral-sh/uv:0.11.19 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project
```

uv comes pinned from the distroless image (no pip bootstrap, no requirements-export detour). `--frozen` verifies hashes from `uv.lock`. **Skip apt entirely** when all deps ship manylinux wheels (e.g. asyncpg needs no libpq/gcc). Runtime stage: an explicit `FROM … AS runtime` on the same base image (so the venv's python symlink stays valid), with **`WORKDIR` set to `/app` in both stages** — uv writes the env to `<workdir>/.venv`, so without it the builder creates `/.venv` while the runtime copies `/app/.venv` and the build fails `"/app/.venv": not found`. Create the non-root `app` user explicitly (the base image has none, so `COPY --chown=app:app` / `USER app` fail otherwise), copy the venv and prepend it to PATH, and add a curl-free healthcheck:

```dockerfile
FROM python:3.14-slim AS runtime
WORKDIR /app
RUN useradd --create-home --uid 1000 app
ENV PATH="/app/.venv/bin:$PATH"
COPY --from=builder /app/.venv /app/.venv
COPY --chown=app:app . /app/
RUN chown app:app /app    # COPY --chown sets contents, not the /app dir node itself
USER app
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request, sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3).status == 200 else 1)"
```

## 9. AWS OIDC role (Terraform)

No long-lived AWS keys in GitHub. `aws_iam_openid_connect_provider` for `https://token.actions.githubusercontent.com` (`client_id_list = ["sts.amazonaws.com"]`), and a role whose trust policy restricts to **the release branch of this repo only** — the release job is triggered by the push to `main` (semantic-release creates the tag later, *inside* the job), so the OIDC `sub` is the branch ref, not a tag ref:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = ["repo:${var.github_repo}:ref:refs/heads/main"]   # the release branch — not PRs, not forks
}
```

Least-privilege policy: `ecr:GetAuthorizationToken` on `*` (account-level, can't be scoped); ECR push actions (`InitiateLayerUpload`/`UploadLayerPart`/`CompleteLayerUpload`/`PutImage`/`BatchCheckLayerAvailability`/`BatchGetImage`/`GetDownloadUrlForLayer`) on the one repo ARN; `ssm:StartSession` on the instance ARN + `arn:aws:ssm:REGION::document/AWS-StartSSHSession`; `ssm:TerminateSession`/`ResumeSession` on `session/*`. Output the role ARN for step 10.

## 10. GitHub secrets/variables split

Variables (non-sensitive config): `gh variable set AWS_ROLE_ARN ECR_REPO EC2_HOST DOMAIN AWS_REGION`. Secrets (credentials): `gh secret set DEPLOY_SSH_KEY` plus smoke credentials (e.g. `APP_FIREBASE_API_KEY`, `SMOKE_ANON_REFRESH_TOKEN`). Feed secrets via stdin/env (`gh secret set NAME < file`), never as command-line args.

## 11. Dedicated deploy key over SSM

```bash
ssh-keygen -t ed25519 -f /tmp/deploy_key -N "" -C "github-release"
aws ssm send-command --instance-ids i-XXXX --document-name AWS-RunShellScript \
  --parameters commands="echo '$(cat /tmp/deploy_key.pub)' >> /home/ec2-user/.ssh/authorized_keys"
gh secret set DEPLOY_SSH_KEY < /tmp/deploy_key
rm /tmp/deploy_key /tmp/deploy_key.pub          # no local copies
```

## 12. Release workflow — `.github/workflows/release.yml`

Triggered by `push: branches: [main]` — i.e. by a feature rebase-merging into `main` — plus `workflow_dispatch` (see below), with `permissions: { id-token: write, contents: write, issues: write, pull-requests: write }` (OIDC + tag/release creation; the last two because `@semantic-release/github`'s success step comments on released PRs/issues — omit them and the job fails "Resource not accessible by integration") and `concurrency: release` (no overlapping deploys). Job 1 `test`: same mise/uv/postgres setup as CI, runs lint + tests. Job 2 `release` (`needs: test`) starts with semantic-release deciding whether this merge releases at all:

```yaml
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0    # semantic-release needs full history + tags to find the base tag;
                            # a shallow checkout makes it treat every run as the first release
      - uses: actions/setup-node@v6
        with: { node-version: 22 }
      - id: semrel
        if: github.event_name == 'push'             # dispatch re-runs deploy+smoke, never cuts a release
        uses: cycjimmy/semantic-release-action@v6   # exposes new_release_published / new_release_version
        # v6 of both actions = Node 24 runtimes; the @v4 majors are Node 20 actions,
        # which GitHub force-runs on Node 24 from 2026-06 and removes 2026-09.
        with:
          # the conventionalcommits preset is a separate npm package, NOT bundled
          # with semantic-release — without this the run dies with
          # "Cannot find module 'conventional-changelog-conventionalcommits'"
          extra_plugins: |
            conventional-changelog-conventionalcommits
        env: { GITHUB_TOKEN: ${{ github.token }} }

      # One tag resolution for BOTH triggers, so the same gate (tag != '') drives
      # deploy+smoke on a released push AND a workflow_dispatch recovery run.
      # Empty on a no-release push -> deploy+smoke skip, config gate still runs.
      - name: Resolve deploy tag
        id: tag
        if: steps.semrel.outputs.new_release_published == 'true' || github.event_name == 'workflow_dispatch'
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            echo "tag=$(git describe --tags --abbrev=0)" >> "$GITHUB_OUTPUT"
          else
            echo "tag=v${{ steps.semrel.outputs.new_release_version }}" >> "$GITHUB_OUTPUT"
          fi
```

`.releaserc`:

```json
{
  "branches": ["main"],
  "tagFormat": "v${version}",
  "plugins": [
    ["@semantic-release/commit-analyzer", { "preset": "conventionalcommits" }],
    ["@semantic-release/release-notes-generator", { "preset": "conventionalcommits" }],
    "@semantic-release/github"
  ]
}
```

Decisions encoded there: the **changelog lives in GitHub Releases ONLY** — no `@semantic-release/changelog`/`git` back-commits (they fight branch protection; regenerate a file on demand with `conventional-changelog -p conventionalcommits -i CHANGELOG.md -s -r 0`); `"branches": ["main"]` alone — releases come only from `main`, no prerelease channel (this model has no long-lived integration branch to attach one to); the default `GITHUB_TOKEN` is enough precisely because nothing is triggered BY the tag — deploy runs in-job. A `chore:`/`ci:`-only feature publishes nothing and the deploy/smoke steps are skipped — that's what `workflow_dispatch` is for: re-running gate+deploy+smoke for the current version (resolve its tag with `git describe --tags --abbrev=0` under `if: github.event_name == 'workflow_dispatch'`, e.g. after applying missing config or fixing a broken smoke script). Gate **deploy and smoke** (and their buildx/qemu prerequisites) on `if: steps.tag.outputs.tag != ''` (the `Resolve deploy tag` step sets it for a released push or a dispatch) — but run the **config gate** (ship-feature skill, "Enforcement layers") and its AWS/SSH/toolchain setup on EVERY run, ungated: a no-release feature merge still re-checks that the instance config covers the settings class on `main`, so drift surfaces on the next merge instead of mid-release:

```yaml
      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}
      - uses: docker/setup-qemu-action@v4        # prod is arm64; emulate on x86 runner
      - uses: docker/setup-buildx-action@v4
```

Then SSH-over-SSM setup (no open port 22): install `session-manager-plugin` from the `.deb`, write the key from `secrets.DEPLOY_SSH_KEY` to `~/.ssh/deploy_key` (chmod 600), and append to `~/.ssh/config`:

```
Host i-* mi-*
  User ec2-user
  IdentityFile ~/.ssh/deploy_key
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

Then run the deploy script (env from `vars.*`, `TAG: ${{ steps.tag.outputs.tag }}`, the step itself gated on `steps.tag.outputs.tag != ''`) — buildx arm64 → ECR push → ssh to instance → compose pull && up -d. Then a **required** prod smoke step (independent client against the live host; fails the release if prod misbehaves). Two consequences of smoke-after-deploy to internalize: a red release usually means *prod is already on the new code* (the deploy step succeeded — check before assuming an outage), and **the smoke script encodes the public API contract**, so any task that changes endpoints/status codes/`detail` codes/response shapes must update the smoke in the same PR, before the feature ships to `main`. The GitHub Release itself was already created by semantic-release. **There is no dev-resync step in this model**: a feature branch is deleted right after it rebase-merges, so nothing long-lived survives to diverge from `main` — the SHA rewrite that rebase-merge performs is harmless once the branch is gone, and the next feature simply branches off the new `main`.

## The release model in one paragraph

Versions are **derived, not chosen**: task branches squash into a feature branch
(one conventional PR title = one commit = one changelog entry), the feature
rebase-merges into `main`, and semantic-release cuts ONE release per feature with
the bump equal to the highest type in the batch — three feats make one minor,
versions never accumulate per commit. Releasable types: `feat`, `fix`, any `!`;
decide explicitly whether `perf`/`refactor` patch-bump. The same model runs the
iOS repo too — see ios-app-bootstrap (fastlane/TestFlight in the deploy slot,
everything else identical) and a redistributable library — see
python-library-bootstrap (uv build → PyPI Trusted Publishing in the deploy slot).

## Verification (do all of these, in order)

1. **Local toolchain**: `mise install && mise run install && mise run lint && mise run test` from a clean checkout. Tests must pass against a real local Postgres using `.env.test`.
2. **Image**: build it, boot it against a real DB, and wait for the healthcheck — `docker build -t app . && docker run --env-file .env.test app`, then `docker inspect --format '{{.State.Health.Status}}'` until `healthy`. Hit `/healthz` yourself.
3. **First CI run**: open a trivial PR and **watch it** (`gh run watch`). Check both jobs go green, the caches populate, and there are zero deprecation annotations.
4. **Ruleset**: try pushing to `main` directly — it must be rejected; confirm the PR merge button requires `lint`+`test` and that merge-commit is disabled (linear history).
5. **First release**: create a feature branch off `main`, squash-merge a `feat:` task PR into it, then rebase-merge the feature into `main` and watch the whole run — semantic-release computes the version and creates the tag + GitHub Release, then OIDC assume, buildx, ECR push, deploy, smoke. Confirm the feature branch was auto-deleted and that a `chore:`-only feature publishes nothing.
6. **Independent smoke**: from your local machine (not CI), run the smoke task against prod. Two different network paths confirming the same deploy.
7. **Deployed-contract probe**: after merging an API contract change, diff the LIVE `/openapi.json` against the repo's `main` (response schemas, status codes, `deprecated` flags) before any client starts consuming the new contract. "Merged" is not "deployed" — a no-release (`chore`/`ci`-only) merge deploys nothing and a manual deploy can lag, so prod can sit behind `main`, and a client built against `main` will mis-handle prod.

## Pitfalls

- **pipenv/pip leftovers when migrating to uv.** Tools you ran via global installs (ruff!) must be declared as dev deps or `uv run` can't find them; delete requirements-export detours from the Dockerfile — `uv sync --frozen` from `pyproject.toml`+`uv.lock` directly.
- **ruff target-version shifts when `requires-python` appears** — new rule families fire repo-wide. TC001–TC003 are dangerous to auto-fix in FastAPI/pydantic code (runtime annotation introspection); ignore them explicitly with a comment saying why.
- **GitHub free plan: rulesets/branch protection are unavailable on private repos.** Needs Pro or a public repo — check before promising protected `main`.
- **Merge all of a feature's task PRs before shipping it.** Task PRs are based on the feature branch; rebase-merging the feature into `main` and deleting it retargets/closes any still-open task PR (GitHub retargets stacked PRs to the default branch only when the base disappears via the merge flow; deleting by hand closes the children). Merge tasks bottom-up and let "delete branch on merge" clean up.
- **`make task VAR=x` → `VAR=x mise run task`.** mise tasks take parameters as env prefixes; trailing `VAR=x` after the task name is not a thing.
- **Node 20 actions deprecation**: pin current majors (`actions/checkout@v5` etc.) and read the run's annotations — deprecations show as warnings long before they break.
- **buildx can't read a Dockerfile from /tmp under colima** (xattr errors). Keep alternative dockerfiles inside the repo tree, not in /tmp.
- **`uv run` does not autoload `.env`** (pipenv did). Apps reading env through pydantic-settings are fine (they load the file themselves); ad-hoc scripts may need `uv run --env-file .env ...`.
- **Composing mise tasks**: a task body may call `mise run other-task` (e.g. a token-minting wrapper exporting `SMOKE_TOKEN` then `mise run smoke`). This is the supported composition pattern — use it instead of duplicating commands.
- **Stale smoke fails the release AFTER the deploy.** If an API contract change ships without updating the smoke script, the tag pipeline deploys the new code, then the smoke (testing the old contract) goes red: prod is healthy but no GitHub Release is created. Recovery: fix the smoke, run it locally against prod to confirm green, merge — and note a `ci:`/`test:`-typed smoke fix alone does NOT cut a new release, so re-run deploy+smoke via the release workflow's `workflow_dispatch` path instead of waiting for the next `feat`/`fix` feature. Do not re-run the failed workflow run itself: it checks out the old ref and can never see the fix.
- **Verify the smoke script whenever the contract changes** — cheapest enforcement is a CLAUDE.md rule: "does `scripts/smoke.py` still match the contract doc after your change?"
- **semantic-release makes PR titles load-bearing.** A `fix:` title on a feature ships a wrong version and wrong release notes; lint checks format, not truth. Keep PRs single-purpose — if a branch contains several independent feats, that's several PRs, not one.

---
name: python-library-bootstrap
description: Bootstrap a redistributable Python library/package for PyPI — uv toolchain, hatchling + hatch-vcs dynamic versioning (the git tag IS the version, nothing is back-committed), ruff + mypy, a multi-version pytest matrix behind one gate check, conventional commits + semantic-release on main with ephemeral feature branches (GitHub Flow), and tokenless Trusted-Publishing (OIDC) to PyPI. Public or private repo. Use when creating a package/SDK/CLI to publish on PyPI (or a private index). For a deployed FastAPI service use backend-repo-bootstrap; for an iOS app use ios-app-bootstrap — same release model, different deploy slot.
---

# Python library bootstrap (uv → PyPI)

Battle-tested playbook. It reuses the **exact** release model of `backend-repo-bootstrap`
(semantic-release on `main`, short-lived feature branches, conventional PR titles) and
changes only the **deploy slot**: instead of building a Docker image and shipping it to AWS,
it builds an sdist+wheel and **Trusted-Publishes them to PyPI over OIDC** — no API token
anywhere. Adapt names; keep the shape. The Verification section is mandatory, not optional.

Two facts drive every library-specific decision below, and both are the *inverse* of the
backend skill:

- **The package is installable and consumed by others.** So: `src/` layout, a real build
  backend, `py.typed`, and dependency **ranges** (not `==` pins).
- **The version is derived from the git tag, never written into a file.** semantic-release
  computes `vX.Y.Z` and tags it; `hatch-vcs` reads that tag at build time. Back-committing
  the version into `pyproject.toml` would fight branch protection — exactly why the backend
  keeps its changelog in GitHub Releases only. Same reasoning, same payoff.

## Checklist (ordered phases)

1. Confirm the open decisions with the user (§0) — name, visibility, Python floor, license
2. Scaffold an installable `src/` package: `uv init --lib`, `py.typed`, `.gitignore` (§1)
3. Toolchain: `.python-version`, `mise.toml` for local tasks (§2)
4. `pyproject.toml` — hatchling + hatch-vcs dynamic version, ranges, PEP 639 license, source-only sdist allowlist (§3)
5. Versioning wired end-to-end: tag → hatch-vcs → artifact; reject the back-commit path (§4)
6. ruff + mypy + pytest config; ship `py.typed` (§5)
7. CI `ci.yml`: lint + a Python matrix behind one `tests-pass` gate check (§6)
8. Branch model, protection ruleset, merge config — same as backend/iOS (§7)
9. PyPI Trusted Publishing: pending publisher + GitHub Environment (manual, browser) (§8)
10. Release `release.yml`: semantic-release → build at the tag → Trusted-Publish (§9)
11. Verification (every layer), including a TestPyPI dry-run
12. Repo-local Claude config: commit `.claude/settings.json` and wire project skills via `project-skills-init` (§2a; the machine-specific `.claude/*` is gitignored in §1)

## 0. Decisions to confirm with the user first

- **Package name** — must be free on PyPI and is **normalized** (`Acme_Widgets`, `acme-widgets`,
  `acme.widgets` all collide as `acme-widgets`). Check before committing to it: open
  `https://pypi.org/project/<name>/` (404 = free) — the truly safe reservation is the pending
  publisher in §8, which claims the name on the first publish.
- **Repo visibility: public or private.** Orthogonal to *package* visibility — a private GitHub
  repo can still publish a **public** package to PyPI (closed source, open distribution). If you
  need the *distribution* itself private, PyPI is the wrong target: point the publish step at a
  **private index** (AWS CodeArtifact, GCP Artifact Registry, Azure Artifacts, or self-hosted
  devpi) — Trusted Publishing is PyPI/TestPyPI-only, private indexes use a token. Confirm which
  "private" they mean. Also: branch-protection **rulesets need a public repo or GitHub Pro** on
  private ones (see §7).
- **Python support floor + matrix** — e.g. floor `3.10`, matrix `3.10–3.14`. The floor is
  `requires-python`; the matrix is what CI tests. Supporting an old floor is a promise you must
  keep (see the lower-bound-drift pitfall).
- **License** — public packages need one. SPDX expression (`MIT`, `Apache-2.0`, …) + a `LICENSE`
  file (§3). Private/internal: `license = "LicenseRef-Proprietary"` and set the upload-blocking
  classifier if it must never reach PyPI (see pitfalls).
- **TestPyPI dry-run?** Recommended — wire a second trusted publisher on test.pypi.org and prove
  the whole pipeline there before the first real PyPI release (§11).

## 1. Scaffold an installable `src/` package

```bash
uv init --lib --build-backend hatch --name acme-widgets .
```

`--lib` gives the **`src/` layout** (`src/acme_widgets/__init__.py`) and an installable
build-system stanza — this matters: a flat layout lets `import acme_widgets` resolve against the
*working tree* during tests, so you never actually exercise the built artifact. `src/` forces
tests to run against the installed package, which is what your users get. uv's `hatch` value
is hatchling with a *static* version; §3 swaps that for hatch-vcs so the version comes from the
git tag. (If `uv init` flags have drifted, just create `src/<pkg>/` + a `[build-system]` by hand
— the shape below is the contract, not the command.)

Then add the two things `uv init` won't:

- **`src/acme_widgets/py.typed`** — an empty marker file (PEP 561). Without it, downstream users
  get **zero** type information from your package even though you wrote annotations. The
  `Typing :: Typed` classifier is cosmetic; this file is what actually ships the types.
- A **runtime `__version__`** in `__init__.py` that reads installed metadata (no build hook,
  no import of a generated file):

  ```python
  from importlib.metadata import PackageNotFoundError, version

  try:
      __version__ = version("acme-widgets")
  except PackageNotFoundError:        # running from a source tree that was never installed
      __version__ = "0.0.0+unknown"
  ```

Then extend the `uv init`-generated `.gitignore` with the local/machine-specific paths it omits — these must never be committed (`.claude/skills/` and `.claude/agents/` are `install.sh` symlinks: absolute paths meaningless on another machine; `.claude/settings.local.json`, `.claude/worktrees/`, and `.tasks/` are per-checkout state; `.claude/settings.json` itself stays committed — see §2a):

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

### 1a. (Optional) Namespace package — one shared `foo.*` import root across several distributions

Skip this for a normal single package. Use it only when shipping an *ecosystem* of co-installable
distributions that share a top-level import name — `foo.settings`, `foo.db`, … each its own PyPI
project `foo-settings`, `foo-db` (the `google.cloud.*` model). It's PEP 420 implicit namespace
packages; the deltas from the single-package layout above:

- **Layout:** code lives in `src/foo/<subpkg>/`; distribution `foo-<subpkg>`, import `foo.<subpkg>`.
  **`src/foo/` MUST NOT contain `__init__.py`** — that empty dir is the namespace root; an
  `__init__.py` there makes it a regular package and breaks merging with the sibling distributions.
  Every sibling must omit it too.
- **`py.typed` goes in the subpackage** (`src/foo/<subpkg>/py.typed`), never the namespace root.
- **`__version__`** reads the per-distribution name: `version("foo-<subpkg>")`.
- **pyproject:** hatchling can't auto-detect the package (it looks for `foo_<subpkg>`), so name it:
  ```toml
  [tool.hatch.build.targets.wheel]
  packages = ["src/foo"]
  ```
- **mypy:** add `explicit_package_bases = true` + `mypy_path = "src"` (next to `files`/`strict`) so
  `foo.<subpkg>` resolves under the src layout.
- **Verify** (extends Verification #1): `unzip -l dist/*.whl` shows `foo/<subpkg>/py.typed` and does
  NOT show `foo/__init__.py`. Compose-check: install two sibling wheels in one venv → both
  `import foo.<a>` / `import foo.<b>` resolve and `foo.__file__ is None` (a real namespace).
- **Repo shape:** this skill's release model (one semantic-release → one `v${version}` tag → one
  artifact) is **one distribution per repo**. A monorepo of independently-versioned distributions
  needs per-package tags + monorepo-aware release tooling — out of scope here.

## 2. Toolchain: uv + mise (local) — CI drives uv directly

`.python-version` holds the floor (e.g. `3.10`). `mise.toml` is the **local** command surface
(the muscle-memory `mise run test` that matches your backend/iOS repos); it pins uv and wraps the
same `uv run …` commands CI runs, so the two can't drift:

```toml
[tools]
uv = "0.11"

[tasks.install]
run = "uv sync --dev"
[tasks.lint]
run = "uv run ruff check ."
[tasks.format]
run = "uv run ruff format ."
[tasks.typecheck]
run = "uv run mypy"
[tasks.test]
run = "uv run pytest"
[tasks.build]
run = "uv build"
```

**CI does NOT use mise here** — and that is the one deliberate departure from
backend-repo-bootstrap. mise pins a *single* Python via `.python-version`; a library must test a
*matrix* of Pythons, and the clean way to do that is `astral-sh/setup-uv`'s `python-version`
input (§6). Don't "fix" the CI back onto mise-action to match the backend — the divergence is the
point. Run `uv lock` and commit `uv.lock` (reproducible **dev/CI**; downstream consumers resolve
against your ranges, not your lock — see §3).

### 2a. A committed `.claude/settings.json`

The `.gitignore` from §1 already ignores everything machine-specific under `.claude/`
(`settings.local.json`, the symlinked `skills/`/`agents/`, `worktrees/`) while leaving
`.claude/settings.json` itself committable — that committed file is what this section adds.

**`.claude/settings.json`** (committed) — a curated permission allowlist of the repo's standard dev
tools, so every session in the repo skips the prompts for the safe inner loop. Optionally a
PostToolUse hook that keeps a derived file in sync — the library analogue of the iOS repo's
`xcodegen generate` on `project.yml`: here, `uv lock` after a `pyproject.toml` edit:

```json
{
  "permissions": {
    "allow": [
      "Bash(uv sync:*)", "Bash(uv run:*)", "Bash(uv build:*)", "Bash(uv lock:*)",
      "Bash(mise run:*)", "Bash(ruff:*)", "Bash(mypy:*)", "Bash(pytest:*)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "f=$(jq -r '.tool_input.file_path // empty'); case \"$f\" in */pyproject.toml) cd \"$CLAUDE_PROJECT_DIR\" && uv lock >&2 ;; esac; true"
          }
        ]
      }
    ]
  }
}
```

Keep `settings.json` to a *safe* allowlist (no `gh`/`git` write commands, no blanket `Bash(*)`);
machine- or person-specific grants belong in the gitignored `.claude/settings.local.json`. After the
repo exists, wire the project skills (`ship-feature`, `task-pipeline`, any domain skills) via the
**`project-skills-init`** skill — it symlinks them under `.claude/skills/` (gitignored in §1),
so they are never committed.

## 3. `pyproject.toml` — the library-specific shape

```toml
[build-system]
requires = ["hatchling>=1.27", "hatch-vcs>=0.4"]
build-backend = "hatchling.build"

[project]
name = "acme-widgets"
dynamic = ["version"]                 # hatch-vcs fills this from the git tag — see §4
description = "Widgets for the Acme platform."
readme = "README.md"
requires-python = ">=3.10"
license = "MIT"                       # PEP 639 SPDX expression — needs hatchling >= 1.27
license-files = ["LICENSE"]
authors = [{ name = "Acme", email = "dev@acme.example" }]
keywords = ["acme", "widgets"]
classifiers = [
  "Programming Language :: Python :: 3 :: Only",
  "Typing :: Typed",                  # you ship py.typed (the FILE is what counts, this is cosmetic)
  "Development Status :: 4 - Beta",
]
dependencies = [
  "httpx>=0.27,<1",                   # RANGES, not == pins — see below
]

[project.urls]
Homepage  = "https://github.com/OWNER/REPO"
Source    = "https://github.com/OWNER/REPO"
Changelog = "https://github.com/OWNER/REPO/releases"   # semantic-release writes the notes here
Issues    = "https://github.com/OWNER/REPO/issues"

[dependency-groups]
dev = ["pytest>=8", "pytest-cov>=5", "mypy>=1.13", "ruff>=0.9"]

[tool.hatch.version]
source = "vcs"                        # version is the latest vX.Y.Z tag — nothing static here

[tool.hatch.build.hooks.vcs]          # OPTIONAL: also write src/acme_widgets/_version.py
version-file = "src/acme_widgets/_version.py"

# Ship ONLY package sources in the sdist. hatchling's default bundles every VCS-tracked
# file — CLAUDE.md, .github/, .releaserc, mise.toml, uv.lock — into the PUBLIC PyPI archive
# (the wheel is unaffected; it packages src/ only). This allowlist keeps internal/dev files
# out and fails closed as new ones appear. README + LICENSE stay in — the metadata reads them
# when a wheel is built FROM the sdist. (hatchling force-ships the root .gitignore regardless:
# harmless ignore patterns, NOT removable via include/exclude — an explicit exclude is a no-op.)
[tool.hatch.build.targets.sdist]
include = ["src", "tests", "README.md", "LICENSE", "pyproject.toml"]

[tool.mypy]
strict = true
files = ["src", "tests"]
```

This block is identical for a single package and a namespace package (`include = ["src", …]`
covers `src/foo/<subpkg>/` too) — it is **not** a §1a delta. Prefer this allowlist over a
blocklist (`exclude`): a dev file added later stays out by default instead of silently shipping.

Three things that are the **opposite** of an application's `pyproject.toml`:

- **Dependency ranges, never `==` pins.** A backend pins exactly because it owns its runtime; a
  library is *co-installed* with everything else in the user's environment, so a hard pin
  (`httpx==0.27.2`) is a resolver landmine the moment another package wants `httpx>=0.28`. Use a
  lower bound for the API you rely on and an upper bound only at the next *known* major
  (`>=0.27,<1`). `uv.lock` still pins for your CI — that is dev reproducibility, not a constraint
  you impose on users.
- **No `[tool.uv] package = false`.** That flag is the backend's "this is an app, don't build
  it" switch. A library IS built — leave it out so `uv` treats the project as a package.
- **PEP 639 license.** Use the SPDX string + `license-files`, and **drop any old
  `License :: OSI Approved :: …` classifier** — pairing the new `license` expression with the
  legacy classifier emits a build warning on current hatchling/twine.

## 4. Versioning: derived end-to-end (the load-bearing design)

The version flows in one direction and no human ever types it:

```
conventional commits  →  semantic-release computes X.Y.Z  →  git tag vX.Y.Z
                       →  hatch-vcs reads the tag at build time  →  wheel/sdist carry X.Y.Z
                       →  Trusted-Publish to PyPI
```

`hatch-vcs` (`source = "vcs"`) resolves the version from git at build time: a commit tagged
*exactly* `vX.Y.Z` builds the clean `X.Y.Z`; any commit *past* the latest tag builds a PEP 440
dev version (`X.Y.(Z+1).devN+g<sha>`). `tagFormat: "v${version}"` in `.releaserc` (§7) and
hatch-vcs's default `v`-prefix tag regex line up out of the box. The release job (§9) builds
**at the freshly created tag**, so the artifact is always a clean release version.

**Reject the back-commit path.** The tempting alternative — `@semantic-release/exec` running
`uv version X.Y.Z`, then `@semantic-release/git` committing `pyproject.toml` back to `main` —
forces a write to the protected branch, needs a bypass actor, and re-introduces exactly the
force-push-into-protected-`main` pain this whole model was built to avoid. The git tag is already
the source of truth; let the build read it. (`uv-dynamic-versioning` is a lighter,
uv-tuned hatchling plugin that does the same job if you prefer it over `hatch-vcs`; either works,
`hatch-vcs` is the more battle-tested default.)

## 5. Lint / type / test config

- **ruff** for lint + format (`ruff check`, `ruff format --check`). `target-version` is inferred
  from `requires-python`; as with the backend, new rule families fire when `requires-python`
  first lands — triage them, don't blind-`--fix`. A library should keep public-API hygiene rules
  (e.g. `D` docstrings on public symbols) *on* where the backend might not.
- **mypy `strict`** over `src` and `tests`. A library ships its types (`py.typed`), so a type
  error is a defect your users inherit — this is a correctness gate, not a nicety. (Astral's
  `ty` is faster and on the same toolchain, but still preview as of mid-2026; adopt it when it
  stabilizes — until then mypy is the safe choice for a published contract.)
- **pytest + pytest-cov.** Tests import the *installed* package (that's the `src/` payoff).
- **`py.typed` must end up in the wheel** — verify it (§11). With hatchling + `src/` layout it is
  included automatically as package data; the failure mode is silent (types just don't ship).

## 6. CI — `.github/workflows/ci.yml`

On `pull_request` (every PR, any base) with a `concurrency` cancel group. `lint`/`typecheck` run
once on the floor Python; `test` is the **matrix**; a single `tests-pass` gate job is the only
thing branch protection requires — so adding `3.15` to the matrix later never touches the ruleset.

```yaml
name: CI

on: pull_request

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0                 # uv sync builds the project; hatch-vcs needs the tags
      - uses: astral-sh/setup-uv@v8.2.0   # FULL immutable tag — @v8 / @v8.0 do NOT resolve (v8 policy)
        with:
          enable-cache: true
          python-version: "3.10"
      - run: uv sync --dev
      - run: uv run ruff check .
      - run: uv run ruff format --check .
      - run: uv run mypy

  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        python-version: ["3.10", "3.11", "3.12", "3.13", "3.14"]
        include:
          - { python-version: "3.10", resolution: "lowest-direct" }  # exercise the declared floors (see lower-bound-drift pitfall)
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - uses: astral-sh/setup-uv@v8.2.0
        with:
          enable-cache: true
          python-version: ${{ matrix.python-version }}
      - run: uv sync --dev --resolution ${{ matrix.resolution || 'highest' }}
      - run: uv run pytest

  tests-pass:                            # the ONE required check — survives matrix edits
    needs: [lint, test]
    if: always()                         # MUST run even when a dependency failed (see below)
    runs-on: ubuntu-latest
    steps:
      - if: contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')
        run: exit 1
      - run: echo "all required checks green"
```

Two load-bearing details:

- **`setup-uv` is pinned to a full version tag** (`@v8.2.0`), not `@v8`. As of v8 (a deliberate
  supply-chain change) Astral stopped publishing moving major/minor tags — only immutable
  `vX.Y.Z` tags resolve. Bump the pin (or pin a commit SHA + Dependabot) when you update; check
  the action's releases page for the current patch. Every other action here (`checkout@v5`,
  `setup-node@v6`, `semantic-release-action@v6`, `gh-action-pypi-publish@release/v1`) still uses
  a moving major ref — `setup-uv` is the exception.
- **The `tests-pass` gate must be `if: always()` + an explicit result check.** A plain
  `needs:`-only job is *skipped* when a dependency fails, and GitHub can score a **skipped
  required check as success** — green-lighting a PR whose matrix is red. `if: always()` forces it
  to run; `contains(needs.*.result, 'failure')` makes it fail loudly. `fetch-depth: 0` is in CI
  too (not just release): `uv sync` builds the project, which invokes hatch-vcs, which needs tags.
- **The `lowest-direct` `include:` leg actually exercises your dependency floors** — delete it
  only if you don't promise old lower bounds (see the lower-bound-drift pitfall).

Required status checks in the ruleset (§7): **`lint`** and **`tests-pass`** — the matrix legs
(`test (3.10)` …) are intentionally *not* required individually; the gate covers them.

## 7. Branch model, protection ruleset + merge config (GitHub Flow)

Identical to backend-repo-bootstrap and ios-app-bootstrap — `main` is the only long-lived branch;
task branches (issue-linked, `gh issue develop <N> --base <feature> --checkout`) squash into a
developer-named feature branch (the PR title IS the conventional commit; breaking changes are `!`
on any type, which requires the `conventionalcommits` preset — the default angular preset ignores
`!`); the feature **rebase-merges** into `main` → one release per feature, bump = the highest type
in the batch. `gh repo create OWNER/REPO --private --source . --push` (or `--public`).

`.releaserc` at the repo root (the changelog lives in GitHub Releases only — no
`@semantic-release/changelog`/`git` back-commit plugins; they fight branch protection, and for a
library the back-commit is *doubly* wrong since hatch-vcs already derives the version from the
tag, §4):

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

Branch-protection ruleset via the API (the `gh` CLI has no ruleset subcommand) — contexts must
equal the CI **job names** (`lint`, `tests-pass`):

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
        "required_status_checks": [ { "context": "lint" }, { "context": "tests-pass" } ] } }
  ]
}
EOF
```

0 approvals is correct for a solo repo (PRs still required, self-mergeable). `required_linear_history`
permits rebase-merge and squash but blocks merge commits. There is no long-lived branch besides
`main` and no post-merge resync, so **no bypass actor is needed**. Make squash merges title-only
with the PR title as the message (`PR_TITLE` must be explicit — GitHub's DEFAULT takes the commit
message for single-commit PRs, so one `wip` commit under a clean title would land as `wip`;
`gh repo edit --squash-merge-commit-title` was dropped in gh 2.93, use the REST PATCH):

```bash
gh api repos/OWNER/REPO -X PATCH -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK
gh api repos/OWNER/REPO -X PATCH -f allow_merge_commit=false -f allow_squash_merge=true -f allow_rebase_merge=true
gh api repos/OWNER/REPO -X PATCH -f delete_branch_on_merge=true
```

Add a **PR-title lint** (e.g. `amannn/action-semantic-pull-request`) on the `pull_request` event
(NOT `pull_request_target` — the title is in the event payload, so the write-scoped token it
grants buys nothing and needlessly exposes secrets to PR-head context), triggered on
`opened|edited|synchronize` (the `edited` event stops rename-after-green), scoped to PRs whose
base is NOT `main` (`branches-ignore: [main]`). Keep it **advisory — do NOT add it to `main`'s
`required_status_checks`**: it never runs on feature → `main` PRs, so requiring it would deadlock
every feature → `main` merge; task → feature PRs target unprotected feature branches, so nothing
enforces it there regardless. Give the job **`permissions: { pull-requests: read }`** — the v6
action fetches the PR through the API (not just the event payload), so without it the check fails
with `Resource not accessible by integration` on every PR.

Paste this block into the new repo's CLAUDE.md — it is what makes every future session pick the
right merge button without re-deriving the model. Keep it verbatim-identical with the copies in
backend-repo-bootstrap §6 and ios-app-bootstrap §6:

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

The Branching block is the *invariant* part — paste it verbatim. Round out CLAUDE.md with the
project-specific sections every mature repo in this family carries, so future sessions don't
re-derive them (skeleton — fill per project):

```markdown
# <package>

<One line: what this library is and the `foo.*` namespace it lives in, if any.>

## Commands

- `mise run install` — uv sync --dev
- `mise run lint` / `mise run typecheck` / `mise run test` — ruff, mypy --strict, pytest
- `mise run build` — uv build (sdist + wheel)
- Release: rebase-merge a feature into `main` → semantic-release tags `vX.Y.Z` → Trusted-Publish to PyPI.

## Conventions

- Public API is typed and shipped (`py.typed`); a mypy --strict error is a defect users inherit.
- Dependency **ranges**, never `==` pins (this is a co-installed library).
- The git tag is the only version source — never hand-edit a version into `pyproject.toml`.
- All repository text (README, docs, comments) in English. Never add AI co-authorship trailers.

## Testing

- pytest against the INSTALLED package (src layout); cover the public API surface.
- New public behavior ships with a test in the same PR.
```

For a **namespace package**, also paste the §1a "Package layout — PEP 420" caveats into CLAUDE.md so
no future session adds an `__init__.py` at the namespace root and breaks sibling composition.

## 8. PyPI Trusted Publishing — manual steps only the user can do (browser, ~10 min)

Trusted Publishing exchanges a short-lived GitHub OIDC token for a 15-minute PyPI token at upload
time — **no API token is ever created or stored**. It is the PyPI analogue of the backend's AWS
OIDC role. Setup is browser-only:

1. **Reserve the name with a pending publisher.** PyPI → account → *Publishing* → *Add a pending
   publisher* (works *before* the project exists — it reserves the name AND authorizes the first
   upload, solving the chicken-and-egg of "can't add a publisher to a project that isn't there").
   Fill in: **PyPI Project Name** = `acme-widgets`, **Owner** = `OWNER`, **Repository** = `REPO`,
   **Workflow name** = `release.yml`, **Environment name** = `pypi`.
2. **(Optional, recommended) Same on test.pypi.org** for the §11 dry-run.
3. **Create the GitHub Environment.** Repo → Settings → *Environments* → New → **`pypi`**.
   Optionally add *required reviewers* (turns publishing into a manual-approval gate) and a
   *deployment branch rule* restricting it to `main` + tags. This is where you gate releases if
   you don't want every `feat`/`fix` auto-shipping to PyPI.

The string **`pypi`** must be **identical** in three places — the job's `environment:` (§9), the
GitHub Environment, and the PyPI publisher's *Environment name* field. A mismatch is the #1
Trusted-Publishing failure: OIDC claim doesn't match → `403` at upload.

## 9. Release — `.github/workflows/release.yml`

Three jobs, least-privilege: `test` (release gate) → `release` (version + tag + GitHub Release;
`contents: write` to push the tag, **plus `issues:`/`pull-requests: write`** — `@semantic-release/github`'s
success step comments on the released PRs/issues, and without them the job fails
"Resource not accessible by integration", which *skips* `publish`) → `publish` (build + upload;
`id-token: write` for OIDC, **plus `contents: read`** — naming any permission resets the rest to
`none`, and `actions/checkout` cannot read a PRIVATE repo at the tag without it). Splitting
`release` from `publish` keeps the OIDC scope off the release job and the `pypi` environment on
publish only, and a half-failed upload can be re-driven via `workflow_dispatch` without cutting a
new version (the existing tag → `publish` only; semantic-release is skipped on dispatch).

```yaml
name: Release

on:
  push:
    branches: [main]                 # a feature rebase-merging into main
  workflow_dispatch:                 # recover a half-failed upload — re-publish an existing tag
    inputs:
      tag:
        description: "Existing tag to (re)publish, e.g. v1.2.3"
        required: true

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  test:                              # release gate — the full matrix already ran on the feature PR,
    runs-on: ubuntu-latest           # so re-run lint+test on the floor Python as a sanity check
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0 }
      - uses: astral-sh/setup-uv@v8.2.0
        with: { enable-cache: true, python-version: "3.10" }
      - run: uv sync --dev
      - run: uv run ruff check .
      - run: uv run mypy
      - run: uv run pytest

  release:                           # push event only: compute version, tag, GitHub Release
    needs: test
    runs-on: ubuntu-latest
    permissions:
      contents: write                # semantic-release pushes the tag + creates the Release
      issues: write                  # @semantic-release/github success step comments on released issues
      pull-requests: write           # ...and on released PRs — omit and it fails "Resource not accessible by integration"
    outputs:
      published: ${{ steps.semrel.outputs.new_release_published }}
      version:   ${{ steps.semrel.outputs.new_release_version }}
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 0 }      # full history + tags, or semantic-release treats it as the first release
      - uses: actions/setup-node@v6
        with: { node-version: 22 }
      - id: semrel
        if: github.event_name == 'push'
        uses: cycjimmy/semantic-release-action@v6
        with:
          extra_plugins: |
            conventional-changelog-conventionalcommits
        env:                          # block style — a flow map { } cannot hold a ${{ }} expression
          GITHUB_TOKEN: ${{ github.token }}

  publish:                           # build AT THE TAG and Trusted-Publish to PyPI
    needs: release
    if: needs.release.outputs.published == 'true' || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    environment: pypi                # scopes the trusted publisher; optional manual-approval gate (§8)
    permissions:
      id-token: write                # OIDC — the ONLY credential; no PyPI token anywhere
      contents: read                 # checkout a PRIVATE repo at the tag — naming any scope resets the rest to none
    steps:
      - uses: actions/checkout@v5
        with:
          # Build from the EXACT tag, never a moved main HEAD — see note below.
          ref: ${{ github.event.inputs.tag || format('v{0}', needs.release.outputs.version) }}
          fetch-depth: 0             # hatch-vcs needs the tag present to stamp a clean version
      - uses: astral-sh/setup-uv@v8.2.0
        with: { enable-cache: true }
      - run: uv build               # sdist + wheel into dist/; hatch-vcs stamps the tag's version
      - uses: pypa/gh-action-pypi-publish@release/v1
        # No username/password: OIDC Trusted Publishing. PEP 740 attestations are emitted by default.
        # For TestPyPI add:  with: { repository-url: https://test.pypi.org/legacy/ }
```

The non-obvious lines:

- **`ref: …format('v{0}', needs.release.outputs.version)`** — the publish job checks out the
  *tag*, not `main`. semantic-release just created `vX.Y.Z` and pushed it; building anywhere
  *past* it (a main HEAD that moved while the release ran) would make hatch-vcs stamp a PEP 440
  **dev** version, and PyPI would reject or mis-name it. Building the tag guarantees the clean
  `X.Y.Z`. The cross-job tag is reliably present because `publish` `needs: release` (so the tag
  push has completed) and `fetch-depth: 0` fetches it.
- **`workflow_dispatch` requires a `tag` input** (unlike the backend's input-less dispatch).
  PyPI uploads are **immutable** — you can't re-deploy "current"; you can only finish an
  upload that half-failed, by rebuilding that exact tag. A no-release `chore:`-only feature
  cuts no tag, so `publish` is skipped — that's correct, nothing to ship.

## The release model in one paragraph

Versions are **derived, not chosen**: task branches squash into a feature branch (one
conventional PR title = one commit = one changelog entry), the feature rebase-merges into `main`,
semantic-release cuts ONE release per feature (bump = highest type in the batch) and tags it, and
`hatch-vcs` stamps that tag onto the wheel/sdist that Trusted-Publishing uploads to PyPI. No human
types a version and nothing is back-committed — the tag is the single source of truth, end to end.
The same model runs the FastAPI backend (`backend-repo-bootstrap`, Docker→AWS in the deploy slot)
and the iOS app (`ios-app-bootstrap`, fastlane→TestFlight); this skill just puts `uv build`→PyPI
there instead.

## Verification (do all of these, in order)

1. **Local**: from a clean checkout, `mise run install && mise run lint && mise run typecheck &&
   mise run test`, then `uv build`. Confirm **`py.typed` actually shipped**:
   `unzip -l dist/*.whl | grep py.typed` (no match = your users get no types — fix package data).
   Then confirm the **sdist ships only package sources** — the wheel is clean by construction, the
   sdist is what leaks to the PUBLIC index:
   `tar tzf dist/*.tar.gz | grep -E 'CLAUDE|\.github|releaserc|mise|uv\.lock'` must print **nothing**
   (any hit = tighten the §3 allowlist). And prove the allowlist didn't drop a build input — CI
   never runs `uv build`, so it cannot catch an over-tight sdist: extract `dist/*.tar.gz` and
   `uv build --wheel` *inside* the extracted dir; it must succeed (README/LICENSE/src all present,
   version resolved from PKG-INFO with no `.git`).
2. **Version pipeline** (proves §4 before you ever publish): on a throwaway,
   `git tag v0.0.1 && uv build && unzip -p dist/*.whl '*/METADATA' | grep '^Version:'` — must read
   `Version: 0.0.1` — then `git tag -d v0.0.1` and clear `dist/`. A `0.0.0`/`…dev…` here means a
   shallow clone or a missing tag, not a clean release.
3. **First CI run**: open a trivial PR and watch it (`gh run watch`). `lint` + the matrix +
   `tests-pass` go green; caches populate; **zero deprecation annotations** (Node-20 actions).
4. **Ruleset**: push to `main` directly → rejected; the merge button requires `lint` + `tests-pass`;
   merge-commit is disabled (linear history).
5. **TestPyPI dry-run** (before the first *real* release): with the test.pypi.org pending
   publisher and `repository-url: https://test.pypi.org/legacy/`, run one release (or a
   `workflow_dispatch` on an existing tag). Then from a clean venv:
   `uv pip install --index-url https://test.pypi.org/simple/ --extra-index-url https://pypi.org/simple/ acme-widgets`,
   `python -c "import acme_widgets; print(acme_widgets.__version__)"` — import works and `__version__` matches the tag.
   (`-i`/`--index-url` **replaces** the default index, and TestPyPI does not mirror PyPI — so the package's own runtime deps (`httpx` etc.) resolve only with `--extra-index-url https://pypi.org/simple/`; `--index https://test.pypi.org/simple/` would also work, since it *appends* to the default index.)
6. **First real release**: feature branch off `main` → squash a `feat:` task PR into it →
   rebase-merge the feature → watch the run. semantic-release tags + creates the GitHub Release;
   `publish` builds the tag and uploads; the project appears on PyPI. Install from a **clean
   venv** (`uv pip install acme-widgets`), import it, confirm `__version__` == the tag. Confirm the
   feature branch auto-deleted.
7. **Chore-only publishes nothing**: rebase-merge a `chore:`-only feature → semantic-release cuts
   no version, `publish` is skipped, PyPI is unchanged.

## Pitfalls (each cost real debugging time)

- **Shallow clone → wrong version.** hatch-vcs/setuptools-scm needs full history + tags;
  `fetch-depth: 0` on **every** checkout that builds (lint, test, release-gate, publish), not just
  the publish. A shallow clone silently stamps `0.0.0`/a dev version. (If you set a
  `fallback_version` for the pre-first-tag period, know it *masks* this bug in release — so keep
  Verification #2 in the loop.)
- **PyPI uploads are immutable.** You cannot overwrite a version or re-use a filename. A bad
  release is **yanked** (PyPI → Manage → Yank) and superseded by a new patch — never "fix and
  re-push" the same version. For a genuinely half-finished upload, `pypa/gh-action-pypi-publish`
  takes `skip-existing: true` to upload only the missing files; don't set it by default (it hides
  real duplicate-version mistakes).
- **The sdist ships your whole repo by default.** hatchling's default sdist includes every
  VCS-tracked file — `CLAUDE.md`, `.github/`, `.releaserc`, `mise.toml`, `uv.lock` — so your
  internal process doc and CI config land in the PUBLIC PyPI archive (the wheel is unaffected). Lock
  it with a `[tool.hatch.build.targets.sdist] include` allowlist (§3) and verify the published
  artifact (Verification #1), not just the wheel. Because uploads are immutable this leak is
  *permanent* once shipped: only a **new** version with the clean sdist supersedes it — and that
  needs a **releasing** commit (`fix:`, not `chore:`/`build:`, which cut no release, so the leaky
  version stays `latest`). Catch it before the first publish.
- **`==` pins in `[project.dependencies]`.** The inverse of the backend. Exact pins in a library
  are a downstream resolver landmine — use ranges; the lock is for *your* CI only.
- **Lower-bound drift.** Declaring `httpx>=0.27` but using a 0.28-only API passes CI (which
  resolves *highest*) and breaks a user pinned to 0.27. The shown matrix carries a
  `lowest-direct` leg (`uv sync --resolution lowest-direct`) for this; keep it if you promise
  old floors.
- **`py.typed` not in the wheel.** PEP 561: the marker FILE must ship, not just the
  `Typing :: Typed` classifier. Verify with `unzip -l` (Verification #1) — the failure is silent.
- **No pending publisher → first publish 403s.** Configure it (§8) *before* the first release, or
  the upload fails with "not authorized" / "non-existent project".
- **Environment-name mismatch.** `environment: pypi` (job) ≠ the GitHub Environment ≠ the PyPI
  publisher's Environment field → OIDC `403`. Keep the string identical in all three (§8).
- **`id-token: write` missing.** Without the job-level permission the OIDC mint fails and the
  action falls back to looking for a password, then errors. It lives on the **publish** job only.
- **`setup-uv` immutable tags.** `@v8` / `@v8.0` do not exist post-v8 — pin a full `vX.Y.Z` (or a
  SHA) and bump deliberately. The other actions still use moving major refs.
- **PEP 639 license + legacy classifier together** warn on current hatchling/twine — SPDX
  `license` string + `license-files`, and delete the old `License :: …` classifier.
- **Back-committing the version fights branch protection.** Don't reach for
  `@semantic-release/git` + `uv version` — the tag is the source of truth and hatch-vcs reads it
  (§4). This is the library mirror of the backend's "changelog in GitHub Releases only".
- **Private repo + rulesets need Pro/public** (same as backend/iOS). And remember: a private repo
  still publishes a **public** package to PyPI — if the *distribution* must be private, retarget
  the publish step at a private index (token-based; Trusted Publishing is PyPI/TestPyPI-only).
- **Node-20 actions deprecation**: pin current majors (`checkout@v5`, `setup-node@v6`,
  `semantic-release-action@v6`) and read the run annotations — deprecations warn long before they break.
- **`${{ }}` inside an inline flow mapping is invalid YAML.** `env: { GITHUB_TOKEN: ${{ github.token }} }`
  or `with: { ref: ${{ … }} }` fails to parse — a flow map `{ }` cannot hold a `${{ }}` expression, and
  GitHub rejects the whole workflow with a **startup failure** (0s run, no jobs, "this run likely failed
  because of a workflow file issue"). Use block style (`env:`/`with:` keys on their own lines) or quote
  the value (`"${{ … }}"`). Flow maps *without* expressions (`with: { fetch-depth: 0 }`) are fine.

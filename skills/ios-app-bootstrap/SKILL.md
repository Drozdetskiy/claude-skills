---
name: ios-app-bootstrap
description: Bootstrap a native iOS app repo from zero to TestFlight — XcodeGen + SwiftUI skeleton, fastlane match code signing, main + ephemeral feature branches (GitHub Flow) with semantic-release shipping every feature to TestFlight, PR test CI with snapshot-safe Xcode pinning, branch protection. Use when creating a new iOS app/repo from scratch or wiring up TestFlight/test CI for one. For backend repos use backend-repo-bootstrap (same model, different deploy slot).
---

# iOS App Bootstrap (zero → TestFlight)

Battle-tested playbook (a production iOS app, 2026-06). Templates live in `./templates/` — copy them and replace `{{APP_NAME}}` (PascalCase target name), `{{BUNDLE_ID}}`, `{{GH_USER}}`, `{{REPO}}`, `{{CERTS_REPO}}`, `{{DISPLAY_NAME}}`.

## 0. Decisions to confirm with the user first

- App/target name, display name, **bundle ID** (explicit, reverse-DNS), deployment target (iOS 17+ is a sane default).
- Repo name; private or public. Certs repo name (`<app>-certs`, MUST be private).
- Release cadence: each feature ships by rebase-merging into `main` (semantic-release; same model as backend-repo-bootstrap), and every release uploads to TestFlight. macOS minutes burn at ×10 (~200 real min/month on the free plan), and every feature = one TestFlight build — group related tasks into one feature rather than shipping each task to `main` separately.

## 1. Scaffold the project

Prereqs: `brew install xcodegen` (fastlane is preinstalled on GitHub macOS runners and usually via brew locally).

1. `git init -b main`, copy `templates/gitignore` → `.gitignore`.
2. Copy `templates/project.yml`, substitute placeholders. Key points already encoded: `VERSIONING_SYSTEM: apple-generic` + `CURRENT_PROJECT_VERSION` (required by fastlane `increment_build_number`), an explicit `scheme:` block (without it `xcodebuild -scheme` fails on CI), `ITSAppUsesNonExemptEncryption: false`, portrait-only with `UIRequiresFullScreen: true` (avoids the iPad multitasking-orientation upload validation), and a `{{APP_NAME}}Tests` (`bundle.unit-test`) target wired into the scheme's `testTargets` so `xcodebuild test` has an action to run — without it the required `Tests` check (§6) exits 66 "not configured for the test action" and blocks every feature→`main` PR. Also copy `templates/Tests/SmokeTests.swift` → `Tests/` — the always-green smoke the test target runs (grow it into the real suite per §7).
3. Minimal SwiftUI sources: `App/Sources/<AppName>App.swift` (`@main`), `ContentView.swift`.
4. App icon: a single 1024×1024 PNG in `App/Resources/Assets.xcassets/AppIcon.appiconset/` with a single-size `Contents.json` (`"size": "1024x1024"`, `"idiom": "universal"`, `"platform": "ios"`). Upload to TestFlight FAILS without an icon.
5. `xcodegen generate`, commit the generated `.xcodeproj` (CI must not depend on xcodegen).
6. Verify build **and** test: `xcodebuild -scheme <AppName> -destination 'generic/platform=iOS Simulator' build`, then `xcodebuild test -scheme <AppName> -destination 'platform=iOS Simulator,name=iPhone NN'`. The required `Tests` check runs `test`, so a missing/broken test action must surface here locally — not as a red check on your first feature→`main` PR.

## 2. fastlane

Copy `templates/Fastfile`, `templates/Matchfile`, `templates/Appfile`, `templates/env.example` (→ `.env.example`). Design encoded there:

- Auth via App Store Connect **API key** from env (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` base64) — never Apple ID/2FA on CI.
- `match` with git storage; **readonly on CI**; certs created once locally via the `certs` lane.
- App version comes from semantic-release via the `MARKETING_VERSION` env var (the Fastfile falls back to parsing a `v1.2.3` tag ref for manual runs); build number = `latest_testflight_build_number + 1`.
- Manual signing flipped at build time via `update_code_signing_settings` (keeps the project on Automatic for local dev).
- No Gemfile: brew fastlane locally, preinstalled fastlane on runners.

## 3. GitHub

1. `gh repo create <repo> --private --source=. --push` and `gh repo create <certs-repo> --private --add-readme`.
2. `main` stays the default branch — there is no long-lived `dev`. Work happens on short-lived feature branches off `main` (developer-named) that rebase-merge back and are deleted; releases are cut from `main`. Task PRs target a feature branch (not the default), so `Fixes #N` will NOT auto-close their issues on that merge — see §6 for how task issues are closed.
3. `gh auth setup-git` (lets local match clone the certs repo over https).
4. Copy `templates/release.yml` → `.github/workflows/release.yml` (push to `main` + `workflow_dispatch`, semantic-release → `fastlane beta`, `concurrency` group, `runs-on: macos-15`).

## 4. Manual steps only the user can do (browser, ~15 min)

1. Register the bundle ID: developer.apple.com → Identifiers → + → App IDs → App → Explicit.
2. Create the app in App Store Connect (My Apps → + → New App). App name must be UNIQUE across the whole App Store.
3. Create an API key: ASC → Users and Access → Integrations → Team Keys, role **App Manager**; download `.p8` (one-time download), note Key ID + Issuer ID.
4. Team ID: developer.apple.com → Membership details.
5. Fine-grained PAT for CI → certs repo only, **Contents: Read-only** (Metadata gets added automatically).

## 5. Wire it up (agent does this)

1. `.env` from `.env.example`: `ASC_KEY_CONTENT=$(base64 -i AuthKey_XXX.p8)`, `MATCH_PASSWORD=$(openssl rand -base64 18)`. Tell the user to save MATCH_PASSWORD in their password manager.
2. `fastlane certs` (one-time; creates cert + profile, pushes encrypted to the certs repo). Verify via `gh api repos/<user>/<certs-repo>/commits` — expect a "[fastlane] Updated appstore..." commit.
3. Six secrets: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION` = `base64("ghuser:PAT")`. Use `gh secret set`.
4. First release: create a feature branch off `main`, squash-merge a `feat:` task PR into it, then rebase-merge the feature into `main` — semantic-release computes the version, tags, creates the GitHub Release, and `fastlane beta` uploads. Watch with `gh run watch <id> --exit-status` (background). Apple processing adds ~5–10 min after upload before the build shows in TestFlight. Confirm the feature branch was auto-deleted afterwards.

## 6. Branch model, PR test CI + branch protection (GitHub Flow)

The same model as backend-repo-bootstrap: task branches (issue-linked,
`gh issue develop <N> --base <feature> --checkout`) squash into a developer-named
feature branch — the PR title IS the conventional commit, breaking changes are `!`
on any type (requires the `conventionalcommits` preset; the default angular preset
ignores `!`); the feature rebase-merges into `main` — one release per feature, bump =
the highest type in the batch. Add a PR-title lint on the `pull_request` event (NOT
`pull_request_target` — the title is in the event payload, so the write-scoped token it
grants buys nothing and needlessly exposes secrets to PR-head context), triggered on
`opened|edited|synchronize` (the `edited` event stops rename-after-green), scoped to PRs
whose base is NOT `main` (`branches-ignore: [main]`). Keep it advisory — do NOT add it to
`main`'s `required_status_checks` (it never runs on feature → `main` PRs, so requiring it
would deadlock every feature → `main` merge; task → feature PRs target unprotected feature
branches, so nothing enforces it there regardless). Add `.releaserc` at the repo root:

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

The changelog lives in GitHub Releases only (no back-commit plugins). A
`chore:`-only feature publishes nothing — `workflow_dispatch` on release.yml
re-runs build+upload for the current version. There is no prerelease channel —
releases come only from `main`.

- Copy `templates/ci.yml` → `.github/workflows/ci.yml`: the `test` job is **named
  `Tests`** (the job name IS the required status-check context below) and runs
  `xcodebuild test -scheme <AppName>` on `pull_request`. The required `Tests` check
  then references this shipped workflow instead of hand-authored prose. Keep
  XCUITest/E2E targets OUT of PR CI (macOS minutes burn at ×10) — run them locally
  before tagging a release instead.
- **Pin the runner's Xcode to the version that recorded your snapshot baselines**
  (`sudo xcode-select -s /Applications/Xcode_NN.N.app`). This is a separate concern
  from the SDK-floor pin in the TestFlight workflow: snapshot baselines are
  pixel-exact per Xcode/simulator-runtime version.
- Branch protection ruleset (the `gh` CLI has no ruleset subcommand):

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
          "required_status_checks": [ { "context": "Tests" } ] } }
    ]
  }
  EOF
  ```

  0 approvals is correct for a solo repo; the context must equal the CI **job name**.
  The `required_linear_history` rule keeps `main` a straight line — it permits
  rebase-merge and squash but blocks merge commits. `main` is the default branch, so
  `~DEFAULT_BRANCH` would also work; `refs/heads/main` is explicit. There is no
  long-lived branch besides `main` and no post-merge resync, so **no bypass actor is
  needed** (the personal-repo 422 the old dev-resync force push tripped over never
  arises). Turn repo-level **"Automatically delete head branches" ON**
  (`gh api repos/OWNER/REPO -X PATCH -f delete_branch_on_merge=true`) — it deletes
  task branches after the squash and feature branches after the rebase-merge, both
  ephemeral by design.
  Caveat: rulesets/branch protection need a public repo or GitHub Pro on private ones.
- Make squash merges title-only with the PR title as the message (`PR_TITLE`
  must be explicit — GitHub's DEFAULT takes the commit message for single-commit
  PRs, so one `wip` commit under a clean title would land as `wip`;
  `gh repo edit --squash-merge-commit-title` no longer exists in current gh,
  use the REST PATCH):

  ```bash
  gh api repos/OWNER/REPO -X PATCH -f allow_merge_commit=false -f allow_squash_merge=true -f allow_rebase_merge=true
  gh api repos/OWNER/REPO -X PATCH -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=BLANK
  ```

Paste this block into the new repo's CLAUDE.md — it is what makes every future
session pick the right merge button without re-deriving the model. Keep it
verbatim-identical with the copy in backend-repo-bootstrap §6:

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

## 7. Testability seams (design in from day one)

Not tests — the architectural seams that make a test pyramid (broad unit tests,
one snapshot per screen, a few XCUITest flows run before tagging) possible later.
(The one piece already shipped is `templates/Tests/SmokeTests.swift` — a single
always-green test whose only job is to give the scheme a test action so the
required `Tests` check passes from day one. It is the seed of the unit suite, not
a real test; replace it as soon as there is behaviour worth asserting.)
Each is cheap while the first real code is being written and expensive to retrofit
once view models are wired to concrete types:

- **Protocol-based networking** (`APIClient` protocol over a `URLSession`
  implementation). XCUITest runs in a separate process and CANNOT intercept the
  app's network — the only mock seam is inside the app: a launch flag
  (`UITEST_MOCK_API=1` in `launchEnvironment`) swaps in a fixture-backed client
  at bootstrap.
- **The same launch flag bypasses external SDKs** that won't run on CI: auth
  bootstrap (fake session instead of the real provider), speech/camera/etc.
  (a protocol around the system API with a scripted stub). Wrap every such SDK
  in a protocol at the dependency container, not at call sites.
- **`accessibilityIdentifier` plumbing in every design-system component** from
  birth (the React Native `testID` analogue). Bolting identifiers onto finished
  screens is a sweep across every view; accepting them as a component parameter
  from day one is free.
- **A launch argument that disables animations** for UI tests; snapshots and
  screenshots on ONE fixed simulator model, status bar normalized via
  `simctl status_bar override`.
- **A single dependency container** (`AppDependencies`-style) where all these
  swaps happen in one place, keyed off the launch environment — scattered
  `ProcessInfo` checks rot.

## Gotchas (each cost real debugging time)

- **match branch mismatch**: `gh repo create --add-readme` makes `main`, but match defaults to `master`. Set `git_branch("main")` in Matchfile AND make sure that change is committed/pushed before CI runs. Symptom: `No code signing identity found and cannot create a new one because you enabled 'readonly'`.
- **SDK floor on upload**: App Store Connect rejects builds made with last year's SDK (`Validation failed (409) SDK version issue... must be built with the iOS NN SDK or later`); Apple raises the floor every April. Runner images default to an older Xcode — always keep the explicit "Select Xcode" step from `templates/release.yml` and bump its version glob when a new floor lands. Locally the same applies: build with the current major Xcode.
- **Snapshot baselines are Xcode-version-exact**: when the runner's default Xcode differs from the one that recorded the baselines, EVERY snapshot suite fails at once with "Snapshot does not match reference" — that signature means "wrong toolchain", not "broken UI". Pin the Xcode version in the test CI; later move the pin only together with a deliberate baseline re-record, never blindly.
- **Key ID = filename**: the real Key ID is the suffix of `AuthKey_<KEYID>.p8`. If the user dictates a different ID, trust the filename (they likely copied another key's ID from the list).
- **Fresh Xcode**: if `xcodebuild` reports no eligible destinations / "iOS X.Y is not installed", run `xcodebuild -downloadPlatform iOS` (multi-GB; run in background and continue other setup).
- **Placeholders in user-run commands**: when the user runs a command you gave them (e.g. `gh secret set ... 'USER:YOUR_TOKEN'`), check their pasted output for unreplaced placeholders before relying on the secret.
- **gh token lacks `workflow` scope** by default: pushing `.github/workflows/*` works over ssh remotes but fails over https. Keep the remote on ssh.
- **Old match storage / cert limit**: Apple caps iOS Distribution certs (~2–3 per team). If `fastlane certs` hits the limit, an old cert (EAS, previous match repos) must be revoked in the developer portal.
- macOS `base64` flag is `-i file`. GitHub free plan = 2000 min/month ÷ 10 for macOS.

## Optional polish

- `CLAUDE.md`: record the invariants (pbxproj is generated; version is computed by semantic-release on `main`; match readonly on CI), commands, and the "Branching & merging" block from §6.
- `.claude/settings.json`: allowlist `xcodebuild`/`xcodegen`/`xcrun simctl`; PostToolUse hook that reruns `xcodegen generate` whenever `project.yml` is edited.

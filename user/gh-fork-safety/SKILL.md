---
name: gh-fork-safety
description: Run gh and git safely in a fork or multi-remote checkout — gh repo set-default before any query, pin --repo/--base/--head on PR commands, recognize the phantom-upstream failure mode (plausible wrong-repo answers, no error), and work around gh flag drift across versions. Use whenever a checkout is a fork or has more than one remote, before creating PRs or querying rulesets / default branch / checks.
---

# gh / git fork & multi-remote safety

Battle-tested playbook (a production backend + iOS, 2026-06: recurred across 4+ sessions
on a fork `your-fork/…` of upstream `upstream-owner/…`). The defining trait of these bugs:
`gh` returns a **plausible but wrong-repo answer with no error**, so you build plans on
phantom state. This is the standalone reference; [ship-feature] embeds the one-line
precondition.

## The core failure: gh silently targets the wrong remote

In a checkout with `origin` + a fork parent as `upstream`, `gh` resolves `{owner}/{repo}`
to **either** remote. Symptoms, all without a "wrong repo" message:

- `gh pr create` → `No commits between upstream-owner:master and your-fork:feat/…` (it
  defaulted the base to the **upstream**, whose default is `master` while your fork uses
  `main`).
- `gh api …/rulesets` → 403 (you queried the parent).
- default-branch lookups → `master` (the parent's), not your fork's `main`.
- `gh pr list` → a **phantom PR** from the upstream repo.

**Fix — always, before any gh query:** `gh repo set-default OWNER/REPO`.

## Pin every PR command

Never rely on inference in a multi-remote checkout:

- `gh pr create --repo OWNER/REPO --base main --head <branch>`
- `gh pr merge N --repo OWNER/REPO --rebase --delete-branch` (rebase-merge is the
  GitHub-Flow ship model — see [ship-feature]; never merge-commit, never squash a feature
  ship).
- Watch the **upstream/fork default-branch mismatch** (`master` vs `main`) — it's the
  source of most "no commits between" errors.

## gh flag drift across versions

`gh` removes flags between minor versions; bootstrap docs assume older ones.

- `gh 2.93` **dropped only** `--squash-merge-commit-title`. Title control moved into the
  `--squash-merge-commit-message` enum (the `pr-title` value), but the enum can't produce
  "PR title + blank body", so set both via REST:
  `gh api repos/{owner}/{repo} -X PATCH -f squash_merge_commit_title=PR_TITLE -f
  squash_merge_commit_message=BLANK`.
- Enforce the merge model the same way:
  `-f allow_merge_commit=false -f allow_rebase_merge=true -f allow_squash_merge=true`.
- If a flag errors with `unknown flag`, check the installed `gh --version` before assuming
  your command is wrong.

## Flaky gh endpoints

- `gh pr checks <n> --watch` can throw a **transient 401 on the graphql endpoint**
  mid-run even with valid auth. Poll with plain `gh pr checks <n>` in a loop until the
  output no longer contains `pending`; if 401 recurs, `gh auth refresh -h github.com`.

## Gotchas

- Listing **secrets** needs an admin-scoped token; the workflow `GITHUB_TOKEN` cannot do
  it (`gh secret list` returns empty/forbidden) — a different failure than fork-targeting,
  but it reads the same "plausible empty answer".
- This skill is git-host hygiene only; it deliberately does **not** carry any branch-model
  resync step — the current model (GitHub Flow, ephemeral feature branches) has nothing
  long-lived to resync. If you see resync instructions anywhere, they're from the retired
  main+dev train.

---
name: homebrew-tap-release
description: Distribute a CLI via a Homebrew tap — bootstrap the tap repo and formula once, then bump the formula on every release. Covers creating homebrew-<tap> + Formula/<name>.rb (url, sha256, deps, install + test blocks) and the per-version dance: compute sha256 from the PUBLISHED release asset (never a local build), update version/url/sha256, push the tap, verify with brew install + brew audit. Sequencing is load-bearing — the GitHub Release / PyPI sdist must exist first, because the url and sha256 come from it. Use when adding `brew install` to a CLI you already publish (PyPI / GitHub Releases), or cutting a new version of a tapped formula.
---

# Homebrew tap release (bootstrap the tap → bump per release)

Battle-tested on a CLI published to PyPI + GitHub Releases (cadence-memory, 2026-06:
`0.5.4 → 0.6.0` — sdist built, sha256 into the formula, tap pushed by hand). The formula
lives in a SEPARATE repo and points at an immutable published artifact, so the brew step
always comes AFTER the release that produces that artifact. Distribution-slot companion to
`python-library-bootstrap` (PyPI): same "the git tag is the version" model, a second
delivery channel.

## A. Bootstrap (once)

- Create the tap repo **`homebrew-<tap>`** under the same owner — the `homebrew-` prefix is
  what makes `brew tap OWNER/<tap>` resolve.
- Add **`Formula/<name>.rb`** (Python CLI shape):
  ```ruby
  class AcmeCli < Formula
    include Language::Python::Virtualenv
    desc "…"
    homepage "https://github.com/OWNER/REPO"
    url "https://files.pythonhosted.org/packages/source/a/acme-cli/acme_cli-1.2.3.tar.gz"
    sha256 "…"                       # of THAT published file
    license "MIT"
    depends_on "python@3.12"
    def install
      virtualenv_install_with_resources
    end
    test do
      assert_match "1.2.3", shell_output("#{bin}/acme --version")
    end
  end
  ```
  A non-Python CLI uses a prebuilt-binary `url` + `bin.install`; the sequencing and sha256
  rules are identical.

## B. Release bump (every version)

1. **The release must exist first** — semantic-release tags `vX.Y.Z`, the GitHub Release /
   PyPI upload publishes the artifact. The formula's `url` + `sha256` come from that
   artifact, so this step is strictly after it.
2. **Take the sha256 from the PUBLISHED asset**, not a local build (a local rebuild can
   differ byte-for-byte): `curl -sL <artifact-url> | shasum -a 256`.
3. **Update the formula** — `url`, `sha256` (and a `version` field if present) — then
   commit and push the **tap** repo.
4. **Verify**: `brew tap OWNER/<tap> && brew install OWNER/<tap>/<name>` (or
   `brew upgrade`), then `brew audit --strict OWNER/<tap>/<name>` and
   `brew test OWNER/<tap>/<name>`.

## Automating the bump

The reliable shape: a job in the release workflow (or a `repository_dispatch` it fires)
that, AFTER the publish job succeeds, checks out the tap repo with a **PAT that can push to
it** (the default `GITHUB_TOKEN` is scoped to the source repo and cannot push to a
different one), recomputes the sha256 from the just-published asset, edits the formula, and
pushes. Keep it a separate job gated on a successful publish so a failed upload never
advances the formula.

## Gotchas

- **sha256 must match the exact published bytes** — compute it from the downloaded release
  asset, never from local `dist/`; a rebuild (different timestamps / zip ordering) yields a
  different hash and `brew install` fails the checksum.
- **The tap is a different repo** — cross-repo push needs a PAT / deploy key; `GITHUB_TOKEN`
  won't reach it.
- **Order is load-bearing**: tag + Release / PyPI → then url + sha256 → then formula push.
  Bumping the formula before the artifact is published points `url` at a 404.
- **The `homebrew-` prefix is mandatory** on the tap repo name, or `brew tap` won't find it.
- **Audit before you trust it** — `brew audit --strict` catches formula mistakes that still
  "install" locally but break for everyone else.

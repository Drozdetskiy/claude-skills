---
name: ios-localization
description: Localize a native iOS app and its App Store listing into N languages — language-store plumbing, agent fan-out translation of the string catalog with per-language register rules, economical test/fixture/snapshot policy, ASC name-availability check, and metadata-only deliver. Use when adding languages to an iOS app, translating UI strings at scale, or localizing/authoring App Store metadata.
---

# iOS Localization (app + App Store listing)

Battle-tested playbook (a production iOS app, 2026-06: en/ru → 12 languages + full ASC listing in one day). Two phases — in-app strings and store metadata — sharing one engine: parallel background translation agents with per-language register rules and programmatic validation. Never translate inline in the main context: 100+ keys × 10 languages is agent work.

## Phase A — the app

### 1. The language list is a contract, not a choice

- Find the authoritative list (backend i18n module / content catalogue — e.g. `SUPPORTED_CONTENT_LANGUAGES`), don't invent one. Verify the backend actually serves each language before building (`GET …?language=ja` → expect real translated content).
- Mirror the list in one enum (`AppLanguage`) and **pin it with a unit test** asserting the raw values against the backend list, so drift fails loudly.

### 2. Plumbing checklist

- **Device-locale default**: match `Locale(identifier:).language.languageCode` EXACTLY against the supported set — a prefix check makes `rue` (Rusyn) pass as `ru`. Regional variants collapse via the language code (`de-AT` → de, `pt-BR` → pt). Unsupported → source language. Take a `preferredLanguages: [String]` parameter for testability; only the FIRST entry decides (that's the device locale).
- **Accept-Language**: set in ONE place (the request builder) so every endpoint inherits it; test propagation on the endpoints with other query params (the language must ride the header, never the URL).
- **Picker names are endonyms** (`Español`, `日本語`) via a `nativeName` property on the enum — endonyms are language-invariant, so DELETE the localized language-name keys; a user lost in the wrong locale can still find their language.
- **Speech/dictation**: one BCP-47 locale per language (es → es-ES, pt → pt-BR — pick the dominant speech population and note the choice); unknown → en-US. Keep the on-device-model probe per session start.
- **project.yml / Info.plist**: add `CFBundleLocalizations` (all codes) + `CFBundleDevelopmentRegion`. XcodeGen ≥2.45 derives `knownRegions` from the `.xcstrings` itself.
- **Layout debt**: a 12-row language picker no longer fits small screens — expect to make the Settings sections scroll (and snapshot the smallest supported device to prove it).

### 3. Translation fan-out

1. Export the catalog to a working JSON: `{key: {en, ru}}` (source + one existing translation as a register reference).
2. One **background agent per language**, all launched in a single message. Each prompt carries: app domain & tone ("mystical-but-clear", no slang), the brand words to keep untranslated, placeholder rules (`%1$@`/`%ld` — reorderable, never droppable), domain terminology with the standard local terms (pick one consistently: Legung, tirada, расклад, スプレッド…), and per-language register:
   - de: "du", avoid clumsy compounds, THE length stress-test; pl: informal imperative, also long
   - fr: vouvoiement + French typography; es: region-neutral tú; pt: pt-BR-leaning você; it: tu; tr: warm "sen"
   - uk: formal «ви», idiomatic — never a Russian calque; ru reference shows register only
   - ja/ko: polite sentence forms for prose, but UI labels/buttons as CONCISE forms **without honorific endings** (再試行, not 再試行してください; 다시 시도)
3. Each agent writes `/tmp/...//<lang>.json` and self-validates; you re-validate centrally anyway: key-set equality + placeholder **multiset** match (`%(?:[0-9]+\$)?[-+ 0#]*[0-9]*(?:\.[0-9]+)?[@a-zA-Z]+`) + no empties.
4. Merge into `.xcstrings` preserving Xcode's exact JSON style — `json.dump(..., indent=2, separators=(',', ' : '), ensure_ascii=False)`, sorted keys — or every future Xcode edit produces a noise diff.

### 4. Test economy (do NOT multiply everything ×N)

- **Fixtures**: keep the original pair complete + add ONE new language — the longest-strings one (de) — to exercise the localized-fixture path. The mock client falls back to the source language for the rest (that's the backend's own fallback contract; test both directions). Generate the de fixture with an agent that diffs en-vs-ru leaf values to find exactly the localized fields and touches nothing else.
- **Snapshots**: a stress SLICE, not a matrix — the longest language (de, incl. one smallest-device variant) + a CJK language (ja) over a representative screen set (settings/picker, text-input chrome, content cards/chips) + a CJK render of the card/label design-system component (Latin custom fonts have no CJK glyphs; the per-glyph system fallback has taller metrics — verify nothing clips under `lineLimit`). For CJK content, inline REAL prod strings in the test instead of adding a fixture file.
- **The typography sweep = looking at every recorded baseline yourself** (Read the PNGs). Recording them green proves nothing about truncation.
- L10n round-trip test for one new language + one CJK (string + format-args lookup through the actual lproj).

### 5. Build-system traps

- After deleting a stale snapshot baseline the build FAILS (the generated project still references the PNG) — rerun `xcodegen generate`.
- Verify the BUILT product, not the catalog: the `.app` must contain all N `<lang>.lproj/Localizable.strings`. Beware stale DerivedData copies — check the newest bundle by mtime.
- First test run records missing baselines and fails; the second run is the real verdict.

## Phase B — App Store metadata

### 1. Download before you plan

`fastlane deliver download_metadata --app_identifier … --api_key_path …` into `fastlane/metadata/`. The listing may be **EMPTY** (TestFlight-only apps usually are) — then this is an authoring task, not localization, and product decisions surface: app name, category, support/privacy URLs, screenshots. Stop and ask; don't invent silently. Check the sibling/legacy app's listing too before concluding there's no source copy.

### 2. App name availability

There is no availability checker. Two levels:
- Necessary-not-sufficient: iTunes Search API (`itunes.apple.com/search?term=…&entity=software`) for exact `trackName` matches among PUBLISHED apps. Unpublished apps reserve names invisibly.
- **Authoritative = the rename attempt itself**: PATCH `/v1/appInfoLocalizations/{id}` `{attributes:{name:…}}`. Success ⇒ the name is now yours (that IS the reservation); 409 ⇒ taken. Safe when the app has no published version. Get the loc id via `/v1/apps?filter[bundleId]=…` → `/v1/apps/{id}/appInfos?include=appInfoLocalizations`.
- No PyJWT on the machine? Mint the ES256 JWT with openssl: sign `b64url(header).b64url(payload)` with the .p8 (`openssl dgst -sha256 -sign`), then convert the DER signature to raw r‖s (two 32-byte zero-padded ints). `aud: "appstoreconnect-v1"`, exp ≤20 min.

### 3. Authoring + fan-out

- ASC locale codes ≠ ISO: `en-US, ru, es-ES, pt-BR, de-DE, fr-FR, it, pl, tr, uk, ja, ko`.
- Hard limits (characters, `len()`): name 30, subtitle 30, promotional_text 170, keywords 100 **including commas**, description 4000. German/Polish subtitles will NOT fit literally — instruct agents to transcreate, and say so explicitly or they'll ship a 32-char literal.
- **Keywords are transcreations, not translations**: what locals actually type, comma-separated, no spaces, lowercase/unaccented where users type so. Don't repeat the latin app-name words (already indexed) but DO add local-script equivalents (таро, タロット, tarocchi) — different strings, separately indexed.
- Keep one language-invariant line (the endonym language list) byte-identical across locales; translate only its lead-in.
- Same agent pattern as Phase A: per-locale background agents → JSON → central validation (limits, endonym line intact, brand present, keyword commas) → write `fastlane/metadata/<locale>/{name,subtitle,promotional_text,keywords,description}.txt`. `name.txt` = the brand in every locale.

### 4. Metadata-only lane

```ruby
lane :metadata do
  deliver(api_key: …, app_identifier: …,
    skip_binary_upload: true, skip_screenshots: true,
    skip_app_version_update: true, run_precheck_before_submit: false,
    force: true)
end
```
It edits the listing **draft** — nothing is user-visible until an App Store version is submitted, so pushing authored copy is reversible. Before the first real submission someone must still set: support URL, privacy policy URL, category, screenshots — list these in the PR as open items.

## Order of operations

Phase A: explore → branch → launch translation agents (background) → plumbing edits while they run → merge+validate catalog → tests/fixtures/snapshots → build, verify lprojs in the bundle → record + visually review baselines → PR → release.
Phase B (separate PR): download metadata → resolve product decisions with the user (name/category/URLs) → author source copy → checkpoint the copy with the user → fan-out → validate → commit → PR → `fastlane metadata`.

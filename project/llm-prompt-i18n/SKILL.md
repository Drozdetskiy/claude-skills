---
name: llm-prompt-i18n
description: Author and debug LLM prompt templates and multilingual model output — escape literal braces in str.format prompts, kill the literal-leak / negative-instruction anti-pattern where the model copies an in-prompt example verbatim, keep ONE source of truth for the active language, and scope localization correctly (AI-generated content is multilingual for free; only static strings need work). Use when editing prompt template files, debugging a wrong-language or leaked-label in model output, or localizing an LLM product.
---

# LLM prompt templates & i18n (escaping, leaks, language source-of-truth)

Battle-tested playbook (a production backend, 2026-06: a user-facing feature's language
leak and a historic two-language-system bug). These are failure modes of
*prompt text*, not of the API layer — for the decoding/SDK side see
[llm-structured-outputs-hardening].

## str.format template traps

- Prompts rendered with `str.format` turn any literal `{` into a **`KeyError` = 500 in
  prod**. Every literal JSON brace in an example block must be **doubled**: `{{ }}`.
- A placeholder like `{language}` usually expands to a full **word** (`english`,
  `russian`) via a helper, **not** an ISO code — know which, because callers downstream
  often key dicts the other way (see source-of-truth below).
- Guard it with tests: a sweep that renders every prompt and asserts no stray braces,
  **plus** a coverage test that fails if a new prompt file isn't registered. Adding a
  prompt then means editing the test too — that coupling is deliberate (a dropped-in
  prompt silently escapes the brace sweep otherwise).

## The literal-leak / negative-instruction anti-pattern

An LLM treats a **concrete example sentence in the prompt as a format template to copy
verbatim**, not as content to translate or adapt. A hard-coded result template leaks: the
Russian label «Совет —» appeared in English answers because it was written literally in
`spread_daily_guidance.txt` (double-anchored at ~line 112 in the length-constraints block
**and** ~line 144 in the JSON example), so the model copied it as a mandatory prefix.

- **Fix:** describe the output structure **abstractly** and bind every field positively to
  the target language ("write every word in {language}"). Remove the literal example, or
  make the example itself parameterized.
- **Do NOT add a negative instruction that names the leaked literal** ("do not use the
  word „Совет"") — mentioning the literal, even in a prohibition, **re-anchors** it and
  the leak persists or worsens.
- Find these by **diffing all prompt files against each other**: the leaking prompt is
  the one carrying a concrete literal where its siblings use abstract placeholders.

## One source of truth for the active language

A classic bug: the setter/context stores **codes** (`'ru'`) while a getter returns **full
names** (`'russian'`), so any dict keyed by code and looked up by name silently always
misses (English users got a Russian section header; labels fell back to hardcoded
Russian). **Make the code-valued context the single source of truth**, drop the
name-returning getter, and derive the full name (e.g. via `iso639`) in exactly one place.

## Scope localization correctly — AI content is free

Adding a language feels like it should touch the LLM path; usually it does **not**:
- The `{language}`-into-prompt indirection means AI-generated content (clarifying
  questions, readings) localizes for **any** ISO code with zero translation work.
- `normalize_language` should accept any ISO code and fall back to `en`.
- So the real work is only **static** strings: the UI catalog, the `TranslatedText`
  schema, and YAML catalogues — not the prompts.

## Domain terms are canon, not free translation

Proper nouns and domain vocabulary have **canonical published forms** per language (tarot:
The Fool = El Loco / O Louco / Der Narr / Le Mat / Il Matto; Spanish minors use number
**words**, not digits). Don't machine-translate them — look up the canonical form and
**web-verify against ≥2 independent sources** (e.g. Wikipedia + a publisher). Watch for
attested regional variants and exact glyphs (apostrophes, accents).

## Gotchas

- The leak and the brace `KeyError` are both invisible until a specific language/value
  hits them — render every prompt in CI for every registered language, don't eyeball.
- When you split or rename prompt files, re-run the coverage test; an unregistered file
  passes manual review but is uncovered.
- For the iOS/App-Store side of the same product, the string-catalog fan-out and
  register rules live in the `ios-localization` skill — keep the language list identical
  across backend and client (it's a contract, not a per-repo choice).

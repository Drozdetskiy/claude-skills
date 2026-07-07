---
name: llm-structured-outputs-hardening
description: Harden an LLM layer built on OpenAI (or an OpenAI-compatible provider) Structured Outputs — enforce array cardinality in the schema instead of with retries, catch the SDK exceptions that bypass APIError, survive model-version reasoning_effort drift, run an asymmetric per-finish-reason resample, set a real client timeout, and use latency as the tell that a graceful fallback is masking an outage. Use when building or reviewing code that calls chat.completions.parse with a Pydantic response_format, when an LLM returns wrong-shaped output, or when a "graceful degradation" path hides a 100%-broken feature.
---

# LLM Structured Outputs hardening (schema-shape, SDK traps, fallback tells)

Battle-tested playbook (a production backend, 2026-06: a code-review
and a prod "9 of 10 cards → 502" incident). Every item below is a bug that shipped to
prod or survived a green test suite — Structured Outputs *looks* like it guarantees a
shape it does not, and the OpenAI SDK *looks* like it funnels every error through one
base class it does not.

## Why this shape

Structured Outputs is **grammar-constrained decoding**: the model can only emit tokens
the JSON schema permits, so it enforces types and required keys — but **not array
cardinality, not value ranges, not cross-field invariants**. And the SDK splits failures
into *transport* (retried by `max_retries`) vs *semantic* (refusal, length, content
filter, validation — never retried, and some bypass `APIError` entirely). Most LLM bugs
here come from treating one of those guarantees as broader than it is.

## Fix output-shape bugs in the schema, not with retries

- A plain `list[Card]` lets the model return N-1 / N+1 items — the root cause of the
  prod "9 of 10 cards → 502" (downstream `zip(..., strict=True)` then raises forever).
  **Encode the count**: generate the response model dynamically per request with
  `min_length == max_length == N`, cached by N (e.g. spread sizes 3/7/10).
- **Strict-mode fallback** when the provider rejects `minItems`/`maxItems` under strict:
  `pydantic.create_model` with N named required fields `card_0 … card_{N-1}` — strict
  mode forces every key into `required`, which pins the count.
- **Verify at runtime, not by faith**: assert the provider's `to_strict_json_schema`
  *accepts* the generated model before committing — strict acceptance is version-specific.
- Resample/retry is a **backstop only** for what a schema can't express (refusal,
  `ValidationError`), never the primary fix for a shape bug.

## The SDK exception hierarchy is a trap

- `LengthFinishReasonError` and `ContentFilterFinishReasonError` **do NOT inherit from
  `openai.APIError`** (MRO ends `… → OpenAIError → Exception`). `.parse()` raises them
  when `finish_reason` is `length`/`content_filter`; code that catches only `APIError`
  lets them bubble as detail-less 500s. **Catch `openai.OpenAIError` as the base.**
- Constructors are quirky: `LengthFinishReasonError.__init__` is keyword-only
  `(self, *, completion)`; `ContentFilterFinishReasonError.__init__` is `(self)`.
- Transport hierarchy: `APITimeoutError → APIConnectionError → APIError`.
- **`max_retries` (default 3) covers transport/HTTP only** — refusal, count mismatch and
  `ValidationError` get zero SDK retries and need an app-layer resample loop.
- Don't trust *any* SDK's class tree from memory — print `SomeError.__mro__` in the
  project's real venv before writing the `except`.

## Asymmetric per-finish-reason resample

One retry policy per failure class, not one blanket retry:
- **refusal / ValidationError** → 1 retry with a correcting prompt.
- **Length** → 1 retry with a **DOUBLED** `max_completion_tokens` (the output was
  truncated; a same-budget retry truncates again).
- **ContentFilter** → **terminal, no retry** (a retry burns money to fail identically).

## Model-version config drift

- Reasoning-effort enums change between model versions. `gpt-5.4-mini` **dropped
  `'minimal'`**; valid values are `none / low / medium / high / xhigh`. A `'minimal'`
  value 400s with `unsupported_value` at **param-validation time** (before any
  generation) — it fails 100% deterministically, and the symptom is whatever your
  fallback does, not an obvious error. Use `'none'`; pin the value in config with a
  comment naming the model version it's valid for.
- On a provider swap (OpenAI-compatible `base_url`/`api_key`/`model` override), re-check
  the enum: e.g. Gemini's OpenAI-compat endpoint maps `reasoning_effort` onto
  `thinking_level` and has no `minimal` (it maps to `low`). The provider must support
  Structured Outputs with Pydantic to be a drop-in at all.

## Set a real client timeout

No explicit OpenAI client timeout means the **SDK default 600s** holds a worker for ten
minutes on a hung call, starving the pool under load. Set an explicit timeout and a
deadline (`asyncio.wait_for`) on any latency-budgeted path.

## Graceful degradation hides outages — latency is the tell

A `try: <llm> except (TimeoutError, LLMError): return <static/cached>` path returns
plausible data, so a **100%-broken** call looks healthy and ships past the release gate
(pytest mocks the LLM; smoke deliberately accepts both AI and fallback output so a
transient outage doesn't fail releases). Distinguish real vs fallback by **latency**
(fallback ~0.2–1.2 s vs real LLM ~1.0–1.4 s) and **output invariance** (identical order
across different inputs ⇒ you're on the cheap path). When in doubt, probe prod live with
a minted token rather than trusting tests.

## Gotchas

- A regex/string JSON scraper (`content.replace('\n','')` + brace-matching) is a third,
  separate shape-failure class — replace it by wiring the existing Pydantic models to
  `parse` + `response_format`, don't patch the scraper.
- Keep security lint rules that touch this layer ON (e.g. ruff `S311`/`S105`) — they
  catch real bugs; suppress per-line with a reason, not globally.
- See [llm-prompt-i18n] for the prompt-text side (brace escaping, literal leaks) and
  [postgres-async-concurrency] for the DB-side fallout (an overfilled row that 500s the
  generate call forever).

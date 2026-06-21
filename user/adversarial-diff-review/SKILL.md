---
name: adversarial-diff-review
description: Multi-agent adversarial review of a branch diff — parallel lens reviewers (correctness, security, client contract, spec/decision compliance), each finding then sent to an independent verifier prompted to refute it. Use before merging a large PR or right after implementing an agreed plan/review-fix batch, when a single-pass review would miss bugs or drown you in false positives.
---

# Adversarial diff review (lenses + per-finding refutation)

Battle-tested playbook (a production repo, 2026-06: 24 agents over a ~60-file diff → 12 confirmed findings incl. 2 majors fixed before merge; 8 plausible-sounding findings refuted with line-level evidence). Runs on the Claude Code `Workflow` tool.

Reviewers and verifiers run as the library's named agents (`diff-reviewer`,
`finding-refuter` — `agents/user/`, linked by `install.sh --user`): the agent
files carry the role discipline, the prompts below carry the diff-specific
pointers. If the agents are not installed, drop the `agentType` options — the
prompts are self-sufficient.

## Why this shape

- **Lenses, not redundancy.** N identical "find bugs" reviewers converge on the same obvious things. One perspective per reviewer (concurrency, security, client contract, compliance-with-the-agreed-plan) surfaces disjoint findings.
- **Every finding gets an adversarial verifier.** A separate agent is told to *refute* the finding by reading the actual code, defaulting to not-real. In practice ~40% of plausible findings die here (e.g. "advisory lock leaks on request cancellation" — refuted by reading uvicorn/SQLAlchemy sources in `.venv`). You fix only what survives.
- **The decision log is part of the prompt.** When implementing an agreed plan, reviewers must know what was *deliberately* decided and rejected — otherwise they re-litigate settled choices and bury you in noise.

## The script (paste into the Workflow tool, fill placeholders)

```js
export const meta = {
  name: 'adversarial-review',
  description: 'Adversarial multi-lens review of the branch diff',
  phases: [{ title: 'Review' }, { title: 'Verify' }],
}

const ROOT = '<absolute repo path>'

const FINDINGS_SCHEMA = { type: 'object', properties: { findings: { type: 'array', items: {
  type: 'object', properties: {
    title: { type: 'string' }, file: { type: 'string' },
    severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
    description: { type: 'string' },
  }, required: ['title', 'file', 'severity', 'description'] } } }, required: ['findings'] }

const VERDICT_SCHEMA = { type: 'object', properties: {
  isReal: { type: 'boolean' }, reasoning: { type: 'string' } }, required: ['isReal', 'reasoning'] }

const COMMON = `Repo: ${ROOT}, branch <branch> (<N> commits on top of main). Inspect with
'git diff main...HEAD' and 'git log main..HEAD'; read full files where the diff needs context.
The change implements <plan/decision-log doc> — read its decisions section; do NOT report
deliberate decisions as bugs. Explicitly rejected items: <list them>. Tests pass; no style nits.
Report only findings you can ground in specific lines. Note: docs may be mid-update in the
working tree — check 'git status' before claiming something is missing.`

const LENSES = [
  { key: 'correctness', prompt: `${COMMON}\nLENS: correctness/concurrency. <pointed list of the riskiest new mechanisms: retry/resample logic, transactions/rollback paths, locks and their leak paths, caching, races>.` },
  { key: 'security', prompt: `${COMMON}\nLENS: security. <secrets/PII in logs, authz bypasses, removed endpoints really gone, validation, error handlers not leaking internals>.` },
  { key: 'client-contract', prompt: `${COMMON}\nLENS: client contract. Compare implemented behavior against <contract docs>: status codes, machine detail codes, response-shape backward compatibility for OLD clients, OpenAPI annotations vs actual behavior.` },
  { key: 'compliance', prompt: `${COMMON}\nLENS: decision-log compliance. Go through EVERY accepted item in <plan doc> and verify each is implemented AS AGREED. Report anything missing, partial, or implemented differently.` },
]

const results = await pipeline(
  LENSES,
  l => agent(l.prompt, { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS_SCHEMA, agentType: 'diff-reviewer' }),
  (review, lens) => parallel((review?.findings ?? []).map(f => () =>
    agent(`${COMMON}
A reviewer (lens: ${lens.key}) reported this finding. Adversarially VERIFY it — try to refute it
by reading the actual code (including installed deps under .venv when the claim is about
framework behavior). Default to isReal=false if the code already handles it, if it contradicts
an agreed decision, or if it is speculative without a concrete failure scenario.
FINDING: ${f.title} [${f.severity}] in ${f.file}\n${f.description}`,
      { label: `verify:${f.title.slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: 'finding-refuter' })
      .then(v => ({ ...f, lens: lens.key, verdict: v }))))
)

const all = results.filter(Boolean).flat().filter(Boolean)
return {
  confirmed: all.filter(f => f.verdict?.isReal),
  refuted: all.filter(f => !f.verdict?.isReal).map(f => ({ title: f.title, why: f.verdict?.reasoning })),
}
```

## Lens design

- Point each lens at the **specific new mechanisms** in the diff ("the pg advisory lock block in api/v1/reading.py: lock leak paths, pooling semantics"), not generic "find bugs". Specific pointers double the hit rate.
- The **compliance lens is the cheapest high-value one** when implementing an agreed plan: it caught "decision 2.5 applied to two of three endpoints" — a class of bug no correctness lens finds because the code is locally fine.
- The contract lens must check **old-client backward compatibility** explicitly (extra response fields ok; removed/renamed fields and changed details are not).

## Verifier design

- Refutation framing + `isReal` default-false is what filters noise. Without it verifiers rubber-stamp.
- Verifiers must read **installed dependency sources** (`.venv/...`) to kill framework-behavior claims ("Starlette cancels handlers on disconnect" — it doesn't; proven by reading the installed version).
- Keep the same `COMMON` preamble so verifiers know the rejected-decisions list too.

## Aftermath

1. **Dedupe confirmed findings** — the same root cause surfaces through several lenses (count them as one fix).
2. Fix confirmed ones, rerun the full test suite and gates, commit as a separate `fix(...)` commit ("post-implementation review findings") — don't smear fixes across the original commits if they're already pushed.
3. Paste the confirmed-vs-refuted summary into the PR body: refuted findings with reasons are *evidence of review depth*, not noise.

## Pitfalls

- **No decision-log exclusions in COMMON ⇒ noise.** Reviewers will "find" everything you deliberately chose (no payload comparison on replay, kept commit semantics, …). List rejected items verbatim.
- **Committed-range blindness.** Reviewers diff `main...HEAD` and miss in-flight working-tree changes (we got a false "docs not updated" finding while docs sat uncommitted). Tell them to check `git status`.
- **Don't skip the verify phase to save tokens.** The 2 majors here came with 8 refuted findings; acting on all 20 raw findings would have wasted hours on non-bugs and diluted attention from the real ones.
- **Severity from the reviewer is a prior, not a verdict** — a "minor" compliance finding (sub used as DB id) was actually a major after verification. Let the verifier reasoning recalibrate.

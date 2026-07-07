---
name: adversarial-diff-review
description: Multi-agent adversarial review of a branch diff — parallel lens reviewers (correctness, substrate-contract, security, client contract, spec/decision compliance), each finding then sent to an independent verifier prompted to refute it. Use before merging a large PR or right after implementing an agreed plan/review-fix batch, when a single-pass review would miss bugs or drown you in false positives. Invoke with "light" for a budget three-lens run (correctness, substrate-contract, spec-compliance) on small diffs or re-reviews.
---

# Adversarial diff review (lenses + per-finding refutation)

Battle-tested playbook (a production repo, 2026-06: 24 agents over a ~60-file diff → 12 confirmed findings incl. 2 majors fixed before merge; 8 plausible-sounding findings refuted with line-level evidence). Runs on the Claude Code `Workflow` tool.

Reviewers and verifiers run as the library's named agents (`diff-reviewer`,
`finding-refuter` — `agents/`, linked by `install.sh`): the agent
files carry the role discipline, the prompts below carry the diff-specific
pointers. If the agents are not installed, drop the `agentType` options — the
prompts are self-sufficient.

## Modes

- **full** (default) — every lens below. For large multi-file features and anything
  that adds an attack surface or touches an external client contract.
- **light** (invoked as `/adversarial-diff-review light`) — three lenses only:
  `correctness`, `substrate-contract`, `spec-compliance`; roughly half the agents.
  For small diffs (≲500 lines), re-reviews after a fix pass, and budget-constrained
  runs. Do NOT go light when the diff adds endpoints, authz, PII handling, or changes
  a client-facing contract — those need their dedicated lenses.
- Subagents inherit the session model unless a lens carries a `model` override. The
  checklist lenses (`security`, `client-contract`, `spec-compliance`) run one tier down
  (`sonnet`): their finder mistakes are either false positives (filtered by the refuter
  net) or misses (prevented by the compliance lens's per-item schema). The judgment
  lenses (`correctness`, `substrate-contract`) and ALL refuters stay on the session
  tier. For deeper budget cuts launch the whole review from a cheaper-tier session and
  spend the top tier on reading the report, not on the fan-out.

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

// Per-item verdicts for the compliance lens: an item cannot be silently skipped.
const COMPLIANCE_SCHEMA = { type: 'object', properties: { items: { type: 'array', items: {
  type: 'object', properties: {
    item: { type: 'string' },                       // the accepted-plan item, quoted
    status: { type: 'string', enum: ['implemented', 'partial', 'divergent', 'missing'] },
    evidence: { type: 'string' },                    // file:line grounding the verdict
  }, required: ['item', 'status', 'evidence'] } } }, required: ['items'] }

const COMMON = `Repo: ${ROOT}, branch <branch> (<N> commits on top of main). Inspect with
'git diff main...HEAD' and 'git log main..HEAD'; read full files where the diff needs context.
The change implements <plan/decision-log doc> — read its decisions section; do NOT report
deliberate decisions as bugs. Explicitly rejected items: <list them>. Tests pass; no style nits.
Report only findings you can ground in specific lines. Note: docs may be mid-update in the
working tree — check 'git status' before claiming something is missing.`

const LENSES = [
  { key: 'correctness', prompt: `${COMMON}\nLENS: correctness/concurrency. <pointed list of the riskiest new mechanisms: retry/resample logic, transactions/rollback paths, locks and their leak paths, caching, races>.` },
  { key: 'substrate-contract', prompt: `${COMMON}\nLENS: substrate contract. Verify every use of an external engine/framework/SDK API in the diff against the INSTALLED sources (.venv/..., node_modules/...): argument order, sync-vs-async variants, config keys, and the installed version's ACTUAL behavior vs what the code, its comments, or the PR body assume. Never trust memory of dependency APIs. <point at the specific dependency APIs the diff touches>.` },
  { key: 'security', model: 'sonnet', prompt: `${COMMON}\nLENS: security. <secrets/PII in logs, authz bypasses, removed endpoints really gone, validation, error handlers not leaking internals>.` },
  { key: 'client-contract', model: 'sonnet', prompt: `${COMMON}\nLENS: client contract. Compare implemented behavior against <contract docs>: status codes, machine detail codes, response-shape backward compatibility for OLD clients, OpenAPI annotations vs actual behavior.` },
  { key: 'spec-compliance', model: 'sonnet', schema: COMPLIANCE_SCHEMA, prompt: `${COMMON}\nLENS: spec/decision-log compliance. Go through EVERY accepted item in <plan doc>; the schema forces a verdict per item — implemented / partial / divergent / missing, each with file:line evidence, no item skipped. 'implemented' means implemented AS AGREED, not merely present.` },
]

// Mode flag — 'light' keeps the three core lenses (see Modes above), 'full' runs everything.
const MODE = '<full|light>'
const ACTIVE = MODE === 'light'
  ? LENSES.filter(l => ['correctness', 'substrate-contract', 'spec-compliance'].includes(l.key))
  : LENSES

const results = await pipeline(
  ACTIVE,
  l => agent(l.prompt, { label: `review:${l.key}`, phase: 'Review',
    schema: l.schema ?? FINDINGS_SCHEMA, model: l.model, agentType: 'diff-reviewer' }),
  (review, lens) => {
    // Compliance per-item verdicts → findings: everything not 'implemented' goes to a refuter.
    const findings = review?.findings ?? (review?.items ?? [])
      .filter(i => i.status !== 'implemented')
      .map(i => ({ title: `plan item ${i.status}: ${i.item}`.slice(0, 120), file: i.evidence,
                   severity: i.status === 'missing' ? 'major' : 'minor',
                   description: `Accepted item "${i.item}" judged ${i.status}. Evidence: ${i.evidence}` }))
    // Refuters take no model override: never below the finder's tier (see Verifier design).
    return parallel(findings.map(f => () =>
      agent(`${COMMON}
A reviewer (lens: ${lens.key}) reported this finding. Adversarially VERIFY it — try to refute it
by reading the actual code (including installed deps under .venv when the claim is about
framework behavior). Default to isReal=false if the code already handles it, if it contradicts
an agreed decision, or if it is speculative without a concrete failure scenario.
FINDING: ${f.title} [${f.severity}] in ${f.file}\n${f.description}`,
        { label: `verify:${f.title.slice(0, 40)}`, phase: 'Verify', schema: VERDICT_SCHEMA, agentType: 'finding-refuter' })
        .then(v => ({ ...f, lens: lens.key, verdict: v }))))
  }
)

const all = results.filter(Boolean).flat().filter(Boolean)
return {
  confirmed: all.filter(f => f.verdict?.isReal),
  refuted: all.filter(f => !f.verdict?.isReal).map(f => ({ title: f.title, why: f.verdict?.reasoning })),
}
```

## Lens design

- Point each lens at the **specific new mechanisms** in the diff ("the pg advisory lock block in api/v1/reading.py: lock leak paths, pooling semantics"), not generic "find bugs". Specific pointers double the hit rate.
- The **substrate-contract lens pays for itself whenever the diff wraps an external engine**: diff-only reviewers rubber-stamp plausible claims about what the dependency does (a durability PR's "a resumed workflow is never picked up in-process" survived every code-only read and died to one look at the installed engine's queue thread plus a live probe). It is also the lens that runs live probe scripts against the installed dependency when reading the source is not conclusive.
- The **compliance lens is the cheapest high-value one** when implementing an agreed plan: it caught "decision 2.5 applied to two of three endpoints" — a class of bug no correctness lens finds because the code is locally fine.
- The contract lens must check **old-client backward compatibility** explicitly (extra response fields ok; removed/renamed fields and changed details are not).

## Verifier design

- Refutation framing + `isReal` default-false is what filters noise. Without it verifiers rubber-stamp.
- **A refuter never runs below the tier of the finder it judges.** Its verdict is terminal — nothing downstream checks it — and default-to-not-real is only safe when the refuter can actually confirm a real mechanism; a weaker one silently converts the hardest findings into refuted and rubber-stamps plausible noise. Lens `model` downgrades therefore never apply to the verify phase.
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

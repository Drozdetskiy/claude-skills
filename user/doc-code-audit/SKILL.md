---
name: doc-code-audit
description: Multi-agent audit of a planning doc (tech-debt list, architecture doc, migration plan) against the actual codebase — per-section claim verifiers, cross-cutting lenses (contradictions, ordering, coherence), adversarial adjudication of every finding. Use before executing a multi-task plan, or when a doc has lived long enough that its claims may have drifted from the code.
---

# Doc-vs-code audit (verify → cross-lens → adjudicate)

Battle-tested playbook (a production iOS app's `TECH_DEBT.md`, 2026-06: 8 verifiers over
27 claims found 5 inaccurate; 3 lenses produced 21 cross-findings; skeptics confirmed
7 unique real ones — including a prescribed fix that, executed as written, would have
shipped a user-visible data bug). Runs on the Claude Code `Workflow` tool.

## Why this shape

- **Plans drift.** A doc written against last month's code confidently names types,
  files, and mechanisms that have since changed. Per-section verifiers check every
  claim against the code with file:line evidence — `accurate / stale /
  partially-accurate / could-not-verify`, never trusting the doc.
- **Tasks contradict each other.** No single-section check sees that task A carefully
  refactors what task B deletes, or that "safe now" silently depends on task C's
  timing. Cross-cutting lenses (contradictions / ordering-and-wasted-work / internal
  coherence) read ALL verified facts at once — this is one of the rare places a
  barrier between workflow stages is genuinely justified.
- **Plausible findings lie.** Roughly half of cross-findings die under an adversarial
  adjudicator told to refute them with code evidence and to default to "doesn't hold"
  for pedantic or already-acknowledged points. You report only what survives.

## The script (paste into the Workflow tool, fill placeholders)

```js
export const meta = {
  name: 'doc-code-audit',
  description: 'Verify doc claims against code and hunt cross-task contradictions',
  phases: [{ title: 'Verify' }, { title: 'Cross-check' }, { title: 'Adjudicate' }],
}

const REPO = '<absolute repo path>'
const DOC = '<absolute path to the doc>'

const VERIFY_SCHEMA = { type: 'object', properties: {
  section: { type: 'string' },
  claims: { type: 'array', items: { type: 'object', properties: {
    claim: { type: 'string' },
    status: { type: 'string', enum: ['accurate', 'stale', 'partially-accurate', 'could-not-verify'] },
    evidence: { type: 'string', description: 'what the code actually shows, file:line' },
  }, required: ['claim', 'status', 'evidence'] } },
  extraObservations: { type: 'string', description: 'adjacent things the doc gets wrong or misses; empty if none' },
}, required: ['section', 'claims', 'extraObservations'] }

const CROSS_SCHEMA = { type: 'object', properties: { findings: { type: 'array', items: {
  type: 'object', properties: {
    title: { type: 'string' }, sections: { type: 'array', items: { type: 'string' } },
    kind: { type: 'string', enum: ['contradiction', 'ordering-dependency', 'wasted-work', 'stale-claim', 'internal-inconsistency'] },
    detail: { type: 'string' }, severity: { type: 'string', enum: ['high', 'medium', 'low'] },
  }, required: ['title', 'sections', 'kind', 'detail', 'severity'] } } }, required: ['findings'] }

const VERDICT_SCHEMA = { type: 'object', properties: {
  holds: { type: 'boolean' }, reasoning: { type: 'string' },
  correction: { type: 'string', description: 'fixed version if directionally right; empty otherwise' },
}, required: ['holds', 'reasoning', 'correction'] }

const COMMON = `You are auditing a planning document against the real codebase.
Document: ${DOC} (read it FIRST in full). Repo: ${REPO}.
For EVERY claim listed below, inspect the actual code and classify it
(accurate / stale / partially-accurate / could-not-verify). Cite file paths and
line numbers. Be skeptical — do NOT assume the doc is right.`

// One entry per doc section; quote the concrete claims so verifiers can't skim.
const SECTIONS = [
  { key: '<section-slug>', section: '<section title>', claims: `1. <claim>\n2. <claim>` },
  // ...
]

phase('Verify')
const verified = (await parallel(SECTIONS.map(s => () =>
  agent(COMMON + '\n\nYour section: "' + s.section + '"\nClaims to verify:\n' + s.claims,
        { label: 'verify:' + s.key, phase: 'Verify', schema: VERIFY_SCHEMA })
))).filter(Boolean)

// Barrier justified: every lens needs ALL verified facts.
const LENS_COMMON = `You are reviewing a planning document for cross-task problems.
Document: ${DOC}. Repo: ${REPO}.
Below are code-verified facts from a prior phase — treat them as ground truth where
they cite evidence, and read the code yourself wherever you need more depth.
Report ONLY findings that would change what an executor should do. Empty is valid.

Verified facts:\n` + JSON.stringify(verified, null, 1)

const LENSES = [
  { key: 'contradictions', prompt: LENS_COMMON + `\n\nYour lens: CONTRADICTIONS — fixes that conflict, one task invalidating another (e.g. refactoring code another task deletes), violated preconditions. Check every pair of sections.` },
  { key: 'ordering', prompt: LENS_COMMON + `\n\nYour lens: ORDERING and WASTED WORK — hidden sequencing the doc doesn't state, tasks that should merge, tasks that become no-ops after another lands, "safe now" claims that depend on timing.` },
  { key: 'coherence', prompt: LENS_COMMON + `\n\nYour lens: INTERNAL COHERENCE — prose vs checklist conflicts, references to files/types/tasks that don't exist, statuses conflicting with described state.` },
]

phase('Cross-check')
const findings = (await parallel(LENSES.map(l => () =>
  agent(l.prompt, { label: 'lens:' + l.key, phase: 'Cross-check', schema: CROSS_SCHEMA })
))).filter(Boolean).flatMap(r => r.findings)

const seen = new Set()
const unique = findings.filter(f => {
  const k = f.kind + '|' + (f.sections || []).slice().sort().join(',')
  if (seen.has(k)) return false
  seen.add(k); return true
})

phase('Adjudicate')
const judged = await parallel(unique.map((f, i) => () =>
  agent(`You are an adversarial skeptic. A reviewer claims an inconsistency in a
planning doc. Document: ${DOC}. Repo: ${REPO}. Read both and try to REFUTE it.
holds=true ONLY if it is real, code-grounded, and would change what an executor
does. Pedantic, speculative, or already-acknowledged-by-the-doc points get
holds=false. Directionally right but wrong in details → holds=true + correction.

Finding:\n` + JSON.stringify(f, null, 1),
        { label: 'judge:' + (i + 1) + ':' + f.kind, phase: 'Adjudicate', schema: VERDICT_SCHEMA })
    .then(v => (v ? { ...f, verdict: v } : null))
))

const confirmed = judged.filter(Boolean).filter(x => x.verdict.holds)
return { claimAudit: verified, confirmed, refuted: judged.filter(Boolean).filter(x => !x.verdict.holds).map(r => ({ title: r.title, why: r.verdict.reasoning })) }
```

## Lessons (each observed on a real run)

- **`extraObservations` catches gold.** Verifiers told only to check claims still
  notice adjacent facts (a fourth consumer of the state being consolidated, types
  missing from a sweep list, an inverted error-handling branch). Keep the field and
  read it — several doc corrections came from there, not from the claims.
- **The dedupe key (kind + sorted sections) is imperfect.** Different lenses report
  the same problem under different kinds; expect to merge duplicates again during
  synthesis. Don't tighten the key — losing a distinct finding is worse than judging
  a duplicate twice.
- **The `correction` field is where half the value lives.** Many findings survive as
  "directionally right, details wrong" — the adjudicator's corrected version (with
  its own file:line evidence) is what actually goes into the doc fix.
- **Deliverable = report first, then fix the doc as a separate approved step.**
  Corrections should land in the doc with the evidence (file:line) so the next audit
  can re-verify them; mark refuted findings too — they show what was considered.
- **Mind doc-priority races.** If the doc has an upstream source (e.g. a backend
  contract file), re-check which copy is authoritative before fixing wording the
  audit flagged — the flagged phrasing may have been superseded.

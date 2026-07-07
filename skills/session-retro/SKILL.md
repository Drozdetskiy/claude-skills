---
name: session-retro
description: Mine Claude Code session transcripts for reusable knowledge — analyze the current session, a named session, or all recent sessions, and propose what to capture as a new SKILL or an auto-memory entry. Extracts the human-typed prompts with jq instead of reading whole transcripts, filters out programmatic sdk-cli runs, clusters recurring asks, and checks every candidate against the existing skill library so it never proposes a duplicate. Use at the end of a working session, when you notice you keep re-asking for the same multi-step thing, or periodically to harvest the last day or two of sessions.
---

# Session retro (mine sessions → skill + memory candidates)

Battle-tested: distilled from the recurring "проанализируй сессию — что вынести в скил
или память?" ask, which recurred across ~10 sessions in two days (and is the workflow
this skill replaces). The output is **skill candidates + memory entries only**.

## Two modes

| Mode | Input | Answers |
|---|---|---|
| **retro** (default) | the current session, or one session id | "what from THIS session is worth a skill or a memory?" |
| **mine** | a date range and/or a set of project dirs | "what recurring patterns ACROSS sessions are skill candidates?" |

## Where the transcripts live

`~/.claude/projects/<slug>/<session-uuid>.jsonl`, where `<slug>` is the working
directory with `/`→`-` (e.g. `-Users-me-Development-foo`); the current session's dir is
the slug of `cwd`. Top-level `*.jsonl` files are the sessions — ignore the nested
`subagents/`, `tool-results/`, `wf_*/`, `*/journal*.jsonl`: those are orchestration
internals, not conversations. Enumerate a window with
`find ~/.claude/projects -mindepth 2 -maxdepth 2 -name '*.jsonl' -newermt '<date>'`.

## Method — read prompts, not transcripts

Transcripts run to megabytes; never `Read` them whole. Pull just the signal:

- **Human prompts** (what the user actually asked):
  `jq -rc 'select(.type=="user") | .message.content' FILE` — keep plain-string / text
  entries, drop `tool_result` arrays and the `<command-name>` / `<local-command-stdout>`
  / caveat wrappers. The first human prompt is the session's PURPOSE; the rest are the
  recurring asks. (`lastPrompt` fields also mark user turns.)
- **Filter out non-human sessions.** Programmatic runs (Agent-SDK workers, loops) are not
  user workflows and skew the counts: `jq -r '.entrypoint' FILE | head -1` — `sdk-cli` =
  programmatic (skip), `cli` = interactive. (In one project 54 of 57 files were `sdk-cli`
  wiki-worker runs — counting them would have invented a phantom pattern.)
- **What was already automated:** `attributionSkill` and the `Skill`/`Agent` `tool_use`
  calls show what ran via existing skills vs by hand — a pattern already driven by a skill
  is saturated, not a candidate.
- **Scale via fan-out.** For a `mine` over dozens of sessions, partition by project and
  spawn read-only agents (Explore / general-purpose), each extracting and clustering its
  cluster's prompts and returning a compact summary — then synthesize. Don't pull every
  prompt into the main context.

## Judging a candidate

- **It must recur** — appear in ≥2 sessions, or be one heavy multi-step workflow re-driven
  by hand. A one-off is not a skill (it is usually a memory entry).
- **Check the existing library first** (`~/.claude/skills` and the `~/Development/skills`
  repo). If a skill already covers it, it is saturated — name the covering skill instead
  of proposing a duplicate.
- **Route each finding to the right home, not reflexively to a new skill:**
  - recurring multi-step workflow with real gotchas → **new skill**;
  - the workflow exists only because a generator/template ships incomplete (the same fix
    re-applied per repo) → **fix the template**, not a new skill;
  - an "always do X" rule → **CLAUDE.md / a rule**;
  - a durable, non-obvious fact about the user or a project → **an auto-memory entry**.
- **Separate symptom from cause.** Repeated manual fixes across sibling repos usually mean
  the bootstrap is wrong — propose hardening the source, with a repair companion at most.

## Output

A ranked list of candidates — each with name, one-line description, evidence (session ids
+ the recurring ask), the routing verdict (new skill / fix template / rule / memory), and
whether an existing skill already covers it. Plus drafted **memory entries** in the
auto-memory file format for the durable facts. **Propose; don't auto-create.** Write a new
`SKILL.md` only after the user approves the candidate; memory entries you may write per the
memory rules. This skill finds and frames — it does not ship a skill unilaterally.

## Gotchas

- **Don't read whole transcripts** — jq the human prompts; a 2.5 MB session is ~5 turns of
  signal buried in tool-result noise.
- **`sdk-cli` sessions aren't workflows** — filter by `entrypoint`, or a loop of identical
  machine-authored opening prompts reads as a "pattern."
- **A candidate that's really a template gap is a trap** — a skill papering over an
  incomplete generator leaves the generator broken; fix forward.
- **Recurrence is the bar** — a single-session retro yields memory entries far more often
  than skills; don't manufacture a skill from one session.

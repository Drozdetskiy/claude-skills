---
name: expo-to-native-ios-port
description: Port an Expo / React Native app to native SwiftUI feature-for-feature — Firebase auth via the REST API (not the iOS SDK), per-feature Route factory files that let parallel agents port screens without merge conflicts, a single networking choke point for headers and 401-refresh, and treating the frozen RN app as the contract. Use when porting an RN/Expo app to native iOS, or wiring auth/networking/navigation for such a port. For new-repo scaffolding/TestFlight see ios-app-bootstrap.
---

# Expo / React Native → native SwiftUI port (1:1, parallel-agent-friendly)

Battle-tested playbook (a production iOS app, 2026-06: a full feature-for-feature port from
a frozen Expo app, done in phases — design system + networking + auth, then exemplar
screens, then a parallel fan-out porting ~9 screens each in its own git worktree with
adversarial parity review and per-screen PRs). The frozen RN app is the **spec**; this
skill captures the decisions that aren't obvious from either codebase.

## Firebase auth via REST, not the iOS SDK

The Expo app uses the Firebase **web SDK, which is a thin REST client** — so the native app
hits the **same Firebase Auth REST API** with the **same public web API key**, and needs
**no** `FirebaseAuth` SPM package and **no** `GoogleService-Info.plist`.

- Anonymous sign-up: `accounts:signUp`; refresh via the `securetoken` endpoint.
- Store the Firebase **refresh token + uid in the Keychain** → a stable `uid` across
  launches → the **same backend user and history**.
- The default instinct (add the FirebaseAuth pod, register an iOS app in the console, ship
  a plist) is wasted work — skip the whole SDK + console-config dependency.

## Per-feature Route factories (so agents don't collide)

Invert the usual single central navigation `switch`. The shared `Route` enum lists all
cases, but **each screen's `navigationDestination` is built by its own
`<Name>Route.swift` factory file, owned solely by that screen**.

- This lets N agents port N screens in **parallel git worktrees** without touching a
  shared dispatcher — the only structural merge conflict is each branch's own factory.
- Give shared-dependency surfaces a **single owner**: e.g. the question screen owns the
  speech recognizer + voice button + mic-permission Info.plist edits; the history screen
  owns the shared history card. Two agents editing one shared file is the conflict you're
  designing out.

## One networking choke point

Funnel every request through one method (e.g. `LiveAPIClient.sendRaw`) and inject
cross-cutting concerns **there, once**, not per-endpoint:

- `Accept-Language` set once covers all ~15 endpoints.
- The **401 → refresh → retry → re-auth** recovery ladder lives at the same choke point,
  so even `deleteReading` gets it for free.
- When a brief says "verify X for ALL endpoints", audit the choke point + **one**
  propagation test — not N per-endpoint changes.

## The frozen reference app is the contract

- Port **1:1**. The RN app is frozen; it is the source of truth for behavior, copy, and
  flow — don't redesign mid-port.
- A **backend feature with no RN/Expo counterpart** is a deliberate deviation — flag it
  explicitly in the PR rather than silently inventing UX.
- Cite the RN origin in ported files (`// Port of src/store/history.ts`) so a reviewer can
  diff against the spec.

## Cross-stack semantic traps

Swift's value/optional/number semantics differ from JS/TS and from the backend's Python —
re-derive, don't transliterate:

- Decode backend payloads **tolerantly** (optional/defaulted fields, unknown-case enums)
  so a backend addition doesn't crash an old build.
- Map RN accessibility and layout intent (not pixel structure) onto SwiftUI; verify with
  snapshot baselines rather than assuming parity.

## Workflow & gotchas

- Drive the port as a fan-out: one agent per screen in its own worktree → an **adversarial
  parity reviewer** ([adversarial-diff-review]) → a per-screen PR ([task-pipeline]).
- Keep the language list **identical** to the backend's (it's a contract); the string
  catalog + register rules live in the `ios-localization` skill.
- Don't reach across the port boundary: if the backend needs a change, spec it for the
  backend session ([task-handoff-spec]) instead of editing two stacks at once.

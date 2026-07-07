---
name: postgres-async-concurrency
description: Audit and design concurrency and idempotency in an async SQLAlchemy + asyncpg + Postgres service — the EvalPlanQual FOR UPDATE trap under READ COMMITTED, get_or_create that lies about `created` under races, non-blocking advisory locks for idempotent replay, position-bearing array ordering, and event-loop-bound pool disposal in tests. Use when writing or reviewing row-locking, get-or-create, idempotency, or any code that "passes every test but races in prod".
---

# Postgres async concurrency & idempotency (the traps that pass tests)

Battle-tested playbook (a production backend, 2026-06: a 24-agent adversarial diff
review + several prod race incidents). Every item passed the full test suite — these bugs
only appear under concurrency, so a green run proves nothing. Pair this with the
`concurrency` lens of [adversarial-diff-review].

## The EvalPlanQual FOR UPDATE trap (READ COMMITTED)

A `SELECT … FOR UPDATE` that **also reads joined/related rows in the same statement** is
unsafe under READ COMMITTED. When the lock holder commits and a waiting txn wakes, Postgres
re-reads **only the locked row** (EvalPlanQual) and keeps its **stale snapshot of the
join**. So two racers both pass an "is it already full?" guard computed from the join,
both insert, and the collection overfills to N+1 — after which a downstream
`zip(..., strict=True)` (or any exact-count consumer) **500s forever** on that row.

- **Adding unique/idempotency indexes does NOT fix this** — the team thought it had.
- **Fix by eliminating the race, not locking harder**: do the work atomically at creation
  (e.g. draw all N items when the parent is created) instead of incrementally under a
  lock. Keep the legacy incremental path, if needed, behind a separate post-lock `SELECT`
  + `IntegrityError → 409`, until old clients age out.

## get_or_create lies about `created` under races

A `BaseCRUD.get_or_create` that sets `created = True` unconditionally is wrong: with
`on_conflict_do_nothing`, when a parallel txn won the insert, this txn inserts nothing,
fetches the existing row, and **still reports `created=True`**. Any caller that branches on
the flag (send welcome email, grant quota, update profile on first login) misfires under
load. **Key `created` off the RETURNING result**:
`inserted = (...).scalar(); obj = inserted or await self.get(...); created = inserted is not None`.

## Non-blocking advisory locks for idempotent replay

For an expensive idempotent endpoint (long LLM generation, payment), guard with a
**non-blocking** `pg_try_advisory_lock(key)`:

- The second concurrent caller gets the lock refused → return **503 + Retry-After**, and
  it **never holds a DB connection** for the ~90 s generation (a blocking lock would).
- Replay is safe **only because the endpoint is idempotent**: a lost response just replays
  and returns the already-generated row — **no second paid call**. The client retry
  contract (503 auto-retry; 502 manual; 500 never) is coupled to that idempotency; write
  it down, it isn't visible in code.
- **But unique-index idempotency ignores the payload**: the same key with a *different*
  body silently returns the **old** result. If the body matters, hash it into the key or
  validate it on replay.

## Position-bearing arrays need an explicit ORDER BY

If `array[i]` carries meaning (position i) and there is **no position column**, the read
path must `ORDER BY` the deal/insert key. A create path that returns insertion order, plus
a `get`/replay path with **no `ORDER BY`** (e.g. `LEFT JOIN` + `contains_eager`,
`lazy='noload'`), lets Postgres return rows in **index-scan order** (a `(parent_id,
child_id)` unique index ⇒ `child_id` order) — so replay (200) and fresh-create (201)
**scramble positions** relative to each other. Order by `id` (deal order) and add a
regression test that asserts replay returns the same set **in the same order**.

## Identity resolution must not diverge by mode

Two endpoints resolving "the current user" by **different keys** (one trusts `token.sub`
as the DB id, another `get_or_create`s by `external_id`) coincide in normal auth (where
`sub == DB id`) but **diverge in `auth_disabled`/local-dev** against a non-empty DB —
giving a 404 on your own row. Use **one** `get_db_user` dependency that resolves identity
the same way everywhere; never use `sub` as a DB id.

## Test harness for un-mocked async SQL

- TestClient + real asyncpg: each TestClient request runs in **its own event loop**, and
  asyncpg connections are **loop-bound** — a pooled connection reused across requests
  raises a cryptic `Task … attached to a different loop`. Fix with an autouse fixture
  calling `engine.sync_engine.dispose(close=False)` around each test (`close=False` avoids
  improperly closing the cross-loop connection).
- Give each create-flow test a **distinct lock key** (e.g. `user_spread_id` 101–114) so
  advisory-lock state never collides between tests.
- `LazyService` proxies **can't be patched directly** — patch the underlying class method
  (`patch.object(SpreadService, 'get_spread', …)`). Assert the single-owning-transaction
  protocol at the mock level: nested creates take `commit=False` + a shared `session=`,
  one `session.commit()` at the end.

## Gotchas

- 404 (not 403) for foreign/missing/already-deleted rows avoids leaking existence; enforce
  ownership **inside** the fetch condition (`id == x & user_id == me`), not as a second
  query.
- Deleting a row that anchors a paid idempotency key must delete that key's row **in the
  same transaction**, or a stale client replay silently regenerates it (a paid call).
- None of the above is caught by the existing suite — write the adversarial test
  (concurrent calls, replay with a mutated body, replay ordering) that fails when someone
  "simplifies" the guard away.

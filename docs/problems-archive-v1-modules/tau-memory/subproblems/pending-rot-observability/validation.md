---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: withstood
revision_triggered: none
---

# Validation: In-process `handle_info(:check_pending_age)` timer inside `Store.SQLite`

## Overview

The revised solution proposes a self-rescheduling timer inside the existing
`Tau.Memory.Store.SQLite` GenServer that queries stale `embedding_status =
'pending'` rows from `memory_entries` (joining the existing `created_at`
column for age arithmetic), emits `[:tau, :memory, :pending_rot, :detected]`
telemetry, logs a structured warning, and reschedules. Five distinct
checkable propositions are extracted from the Recommendation and
"What changes / What does not change" sections. Each receives a full
six-component Toulmin treatment; falsification is attempted with a named
strategy per claim (dependency check, counter-example construction, edge-case
enumeration, integration check, type-level check). All five claims withstand
falsification. Two outstanding doubts (compile-time-only thresholds and
absence of an `(embedding_status, created_at)` index) are recorded for the
parent validator without falsifying the solution.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This validation enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: the detection query reads the existing `created_at` column on `memory_entries` (no schema migration required)

- **Claim (C):** "The detection query reads the existing `created_at` column
  on the `memory_entries` table … `created_at` is the row's insertion
  timestamp, stored as ISO-8601 UTC via the SQLite default
  `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')`, which makes
  `julianday(created_at)` arithmetic well-defined" (solution.md §Recommendation).
- **Grounds (G):** `lib/tau/memory/migrations.ex:35-48` defines
  `memory_entries` with `created_at TEXT NOT NULL DEFAULT
  (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))` (line 45). `lib/tau/memory/store/sqlite.ex`
  references `e.created_at` in five distinct queries (lines 480, 498, 641,
  655, plus the row-projection list at 668-688). No `inserted_at` symbol
  appears anywhere under `lib/` or `test/` (`grep -rn "inserted_at"` returns
  empty). Migration `20260518_002_memory_entries` is the only migration that
  creates this table; no later migration renames or drops `created_at`
  (migrations.ex:35-86).
- **Warrant (W):** A SQL query against a column that the schema defines
  with a `NOT NULL DEFAULT` of an ISO-8601-formatted `strftime` expression
  can safely be passed to `julianday(...)` because SQLite's date-and-time
  functions accept ISO-8601 strings as inputs and return Julian Day numbers
  (https://www.sqlite.org/lang_datefunc.html). Pre-existing column with a
  bounded value space means no migration is needed to materialise the
  data dependency.
- **Qualifier (Q):** Holds for the current schema as defined by migration
  `20260518_002_memory_entries`. Holds across all rows because the column
  is `NOT NULL` with a default — every row created via `do_write/2`
  (sqlite.ex:392-414) or any future writer will populate it.
- **Rebuttal (R):** If a future migration drops or renames `created_at`,
  or if a row is inserted via a path that bypasses the default (e.g. a
  raw `INSERT … (id, …, created_at) VALUES (…, NULL)` — though `NOT NULL`
  would reject this), the query fails. Mitigated by the `NOT NULL`
  constraint; future-mitigated by the append-only migration discipline
  documented as invariant C-007 in `migrations.ex:11`.
- **Backing (B):** SQLite date/time functions reference
  (https://www.sqlite.org/lang_datefunc.html). Append-only migration
  invariant C-007 (`lib/tau/memory/migrations.ex:11-13`). Spec
  `docs/spec/SPEC-MEMORY-STORE.md` (D-047) requires migrations to be
  idempotent and append-only.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify that the schema state the claim
  depends on (column `created_at` on table `memory_entries`, ISO-8601
  default) holds in the current codebase.
- **Attempt:** Read `lib/tau/memory/migrations.ex` directly (every
  migration body inspected). Grep the entire `lib/` and `test/` trees for
  the symbol `inserted_at` (none found) and for the prior incorrect table
  name `memory` as a standalone reference (`FROM memory ` returns no hits
  outside the proposals directory). Confirm `created_at` is referenced
  from existing production queries in `store/sqlite.ex` (semantic search
  SELECT list, FTS search SELECT list, row-projection helper).
- **Outcome:** Withstood. The schema dependency the claim names is the
  schema the codebase actually has.
- **Action:** None. The revision from `inserted_at` → `created_at` and
  `memory` → `memory_entries` is correct.

### Claim 2: a `handle_info(:check_pending_age, …)` clause can be added without conflicting with any existing `handle_info` clause in `Store.SQLite`

- **Claim (C):** Implicit in solution.md §What changes ("New
  `handle_info(:check_pending_age, state)` clause") and explicit in §Open
  questions ("Does the `:check_pending_age` message name conflict with any
  existing `handle_info` clause in `Store.SQLite`? Verify before
  landing.").
- **Grounds (G):** `grep -n "handle_info" lib/tau/memory/store/sqlite.ex`
  returns exactly two matches: line 295
  (`handle_info({ref, _result}, state) when is_reference(ref)`) and line
  300 (`handle_info({:DOWN, _ref, :process, _pid, _reason}, state)`).
  Both patterns are structurally disjoint from the atom `:check_pending_age`:
  one matches a two-tuple whose first element is a reference, the other
  matches a four-tuple beginning with `:DOWN`. The new clause matches a
  bare atom — no overlap.
- **Warrant (W):** Erlang/Elixir GenServer dispatches `handle_info/2` by
  pattern-matching the incoming message against clauses in source order
  (Elixir compilation order semantics; documented in
  https://hexdocs.pm/elixir/Kernel.html#def/2). Disjoint patterns cannot
  match the same message, so clause ordering does not matter for
  correctness. Therefore a new clause for a distinct pattern is additive.
- **Qualifier (Q):** Holds as long as the new clause is placed in the
  module (any position is correct since the patterns are disjoint).
- **Rebuttal (R):** None pertaining to clause ordering, given disjoint
  patterns. If a future commit adds a `handle_info(:check_pending_age,
  state)` clause elsewhere in the module before this validation is
  acted on, the new clause would shadow or be shadowed by the addition —
  but that is a conflict-on-merge issue, not a present-state defect.
- **Backing (B):** Elixir function clause matching semantics, Erlang
  `gen_server:handle_info/2` callback contract
  (https://www.erlang.org/doc/man/gen_server.html#Module:handle_info-2).

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — enumerate existing
  `handle_info` clauses and check whether any could match the atom
  `:check_pending_age`.
- **Attempt:** The two existing clauses' patterns are `{ref, _result}`
  with a reference guard, and `{:DOWN, _ref, :process, _pid, _reason}`.
  Neither matches a bare atom. Construct a message: send
  `:check_pending_age` to the GenServer — neither pattern matches, so the
  message would fall through (currently producing an "unexpected message"
  warning from `:gen_server` default behaviour). Adding the new clause
  captures this fall-through with no shadowing risk.
- **Outcome:** Withstood. The solution's open-question hedge ("Verify
  before landing") is addressable by inspection: no conflict exists in
  the current source.
- **Action:** None. The open question may be retired as part of
  implementation by the implementer simply observing the same `grep`
  result.

### Claim 3: the change satisfies the acceptance criterion — operators can detect pending rot without querying the database directly

- **Claim (C):** The handle_info clause "emits `[:tau, :memory,
  :pending_rot, :detected]` telemetry with `%{count: non_neg_integer()}`
  measurements and `%{entry_ids: [binary()], oldest_age_ms:
  non_neg_integer()}` metadata, logs a structured warning, and reschedules
  itself" (solution.md §Recommendation), which the §Selected-from rationale
  asserts "satisfies the acceptance criterion with the lowest code surface."
- **Grounds (G):** The AC reads (problem.md §Acceptance criterion): "An
  operator can determine — without querying the database directly —
  whether any memory entries have been in `embedding_status: 'pending'`
  longer than the embedding timeout, via a telemetry event or structured
  log line that fires when such entries are detected." The solution emits
  BOTH a telemetry event (`[:tau, :memory, :pending_rot, :detected]`)
  AND a structured `Logger.warning/1` log line when stale rows are found.
  `@stale_threshold_ms = 35_000` is `> @request_timeout_ms = 30_000`
  (embedding_worker.ex:37) plus a 5 s grace, so "longer than the embedding
  timeout" is mechanically satisfied. The check runs every
  `@check_interval_ms = 60_000`, so the detection latency is bounded by
  one minute after a row crosses the threshold.
- **Warrant (W):** The AC is satisfied iff at least one of {telemetry
  event, structured log line} fires when stale entries exist. Emitting
  both is sufficient. The threshold-on-age comparison happens inside
  SQL (the `WHERE` clause), so an operator observing the telemetry knows
  every reported row is past the embedding timeout by definition.
- **Qualifier (Q):** Holds for a long-running node (the timer fires while
  the process is alive). Detection latency is bounded by
  `@check_interval_ms + @stale_threshold_ms` from the moment a row enters
  `pending`; nothing in the AC requires lower latency.
- **Rebuttal (R):** If `Store.SQLite` crashes and restarts at the exact
  moment a check would have fired, the next check is delayed by one full
  `@check_interval_ms` from the restart. This is bounded and consistent
  with the AC. If the timer message is dropped (which is impossible
  within a single Erlang node — `Process.send_after` is reliable
  intra-node), detection would silently stop. Outside the AC's scope
  because the AC does not specify availability under message loss.
- **Backing (B):** Problem.md §Acceptance criterion (verbatim);
  OTP non-negotiable #5 (`.claude/rules/otp-non-negotiables.md`):
  "Telemetry events MUST cover everything user-visible or perf-sensitive";
  problem.md §Context references this rule explicitly.

#### Falsification attempt for claim 3

- **Strategy:** Edge-case enumeration — list the conditions under which
  a stale `pending` row could exist yet the operator would not see it.
- **Attempt:** Enumerate:
  1. Row entered pending more than 60 s ago, process alive: caught by
     next timer tick (≤ 60 s from threshold crossing).
  2. Row entered pending less than 35 s ago: correctly NOT reported
     (within timeout). Matches AC's "longer than the embedding timeout".
  3. Row entered pending 40 s ago, then `Store.SQLite` crashed and
     restarted: on restart, `init/1` reschedules the timer, so detection
     resumes at most 60 s later. Bounded, AC-satisfied.
  4. Telemetry handler not attached at the application level: the
     telemetry event is still emitted, and the structured `Logger.warning`
     log line is also emitted. AC mentions "telemetry event OR structured
     log line"; either alone suffices.
  5. Query fails (DB lock, schema corruption): the `Logger.error` branch
     in the handler logs the failure — an operator sees that detection
     itself is broken, which is a stronger signal than silent absence.
- **Outcome:** Withstood. No enumerated case falsifies the AC.
- **Action:** None.

### Claim 4: the change adds no new module, no new supervised child, and no new public API on the store

- **Claim (C):** "No new module, no new supervised child, no new public
  API on the store" (solution.md §Recommendation); §What does not change
  lists `lib/tau/memory/supervisor.ex` (no new child), `lib/tau/application.ex`
  (no changes), and `lib/tau/memory/store/sqlite.ex` public API
  (no new exported functions).
- **Grounds (G):** The added definitions per §What changes are: two
  module attributes (`@check_interval_ms`, `@stale_threshold_ms`), one
  module attribute holding SQL (`@sql_stale_pending`), one private
  function (`query_stale_pending/2`), one `handle_info/2` clause, and
  one `Process.send_after/3` call inside `init/1`. None of these are
  exported (`@spec`/`def` for a public function is absent; the new
  function is `defp`). `lib/tau/memory/supervisor.ex` (verified inline:
  one child, `Tau.Memory.Store.SQLite`) is not modified. The supervision
  topology is unchanged.
- **Warrant (W):** OTP non-negotiable #3: "MUST NOT wrap stateless logic
  in a GenServer." The detection logic is inherently tied to the existing
  GenServer's owned db reference; collocating it inside the existing
  process honours this principle and avoids the "Manager / Service
  GenServer for shared state" anti-pattern called out in the same
  rule. Adding a private helper plus a new `handle_info` clause to an
  existing GenServer extends behaviour without enlarging the public
  surface.
- **Qualifier (Q):** Holds for the as-described implementation. If the
  implementer were to additionally expose a `get_stale_pending/1` public
  function (not in solution.md), this claim would be partially falsified
  — but the solution explicitly does not.
- **Rebuttal (R):** None within the described scope.
- **Backing (B):** OTP non-negotiables #3 and #8 ("Pure functions are the
  default; processes are the exception"); `.claude/rules/otp-non-negotiables.md`.

#### Falsification attempt for claim 4

- **Strategy:** Integration check — confirm that no other module in the
  codebase would need to change to make the new behaviour observable, and
  that the supervision tree need not be touched.
- **Attempt:** The detection runs in the existing `Store.SQLite` process,
  which is already supervised by `Tau.Memory.Supervisor` and started by
  `Tau.Application` (per the supervisor's `@moduledoc`). Telemetry events
  are received by any attached telemetry handler without explicit
  registration — the receiver side (a `:telemetry.attach/4` call) lives
  outside the memory subsystem and would attach to the event whether or
  not the supervisor topology changes. `Logger.warning/1` requires no
  registration. Therefore the supervision tree is correctly untouched.
- **Outcome:** Withstood.
- **Action:** None.

### Claim 5: the change is reversible by deleting the three definitions and the `init/1` call; no schema rollback is required

- **Claim (C):** "The change is reversible by deleting the three
  definitions and the `init/1` call; no schema rollback is required"
  (solution.md §Migration sketch).
- **Grounds (G):** The change adds private code only (per Claim 4). It
  introduces no migration entry to `@migrations` in `migrations.ex`
  (per solution.md §What does not change: "Database schema — no
  migration required"). Reversal requires removing the additions; no
  pre-existing rows depend on the new code.
- **Warrant (W):** A change that only adds private code inside a single
  GenServer and emits a new telemetry event is reversible by deleting the
  added code, provided no on-disk state was created. Append-only
  migrations (`migrations.ex` C-007) mean any unrolled migration would
  require a new compensating migration; this change adds none, so this
  concern does not apply.
- **Qualifier (Q):** Holds before any downstream consumer of the new
  telemetry event is wired in (e.g. an OTel exporter rule, a dashboard
  alert). Once consumers exist, deletion of the emitter would silently
  break them; reversibility of the change in `Store.SQLite` would still
  be mechanical, but coordinator-level coordination would be required
  to manage consumers.
- **Rebuttal (R):** If an operator attaches a telemetry handler and
  comes to rely on the event between landing and rollback, "reversibility
  is mechanical" understates the operational impact. The code change is
  reversible; the operational expectation may not be.
- **Backing (B):** Reversibility heuristic in the proposal scoring
  rubric (solution.md §Scoring table) is consistent with the
  decomplecting depth being "Surface" (no data model change, no
  topology change).

#### Falsification attempt for claim 5

- **Strategy:** Type-level / static check — enumerate what the change
  touches and what would need to be undone.
- **Attempt:** Inventory of additions per §What changes:
  (a) `@check_interval_ms` module attribute,
  (b) `@stale_threshold_ms` module attribute,
  (c) `@sql_stale_pending` module attribute,
  (d) `defp query_stale_pending/2`,
  (e) `def handle_info(:check_pending_age, state)`,
  (f) one `Process.send_after/3` call at the tail of `init/1`.
  Removing all six restores the prior code. No `@migrations` entry, no
  schema artefact, no ETS table, no Application.env key, no supervisor
  child to remove. Code-level reversibility is mechanical.
- **Outcome:** Withstood at the code level. Partially qualified at the
  operational level (Qualifier already narrows this).
- **Action:** Qualifier already states the operational scope; no
  further revision needed.

## Cross-claim consistency

The five claims do not conflict:

- Claims 1, 3 (correctness of detection) depend on Claim 2 (clause
  addition is safe). Claim 2's falsification confirmed no conflict, so
  the chain holds.
- Claims 4 (no new module / API / child) and 5 (mechanical reversibility)
  are mutually reinforcing — minimal surface implies minimal undo.
- The §Open questions in solution.md (compile-time vs runtime threshold;
  optional index; clause-conflict check) raise three points; Claim 2
  resolves the third, and the first two are flagged below as outstanding
  doubts rather than as defects.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `created_at` exists; ISO-8601 default; `julianday` arithmetic valid | Dependency check | Withstood | None |
| 2 | New `handle_info(:check_pending_age, …)` clause is conflict-free | Counter-example construction | Withstood | Retire open question |
| 3 | Telemetry + log satisfies AC for long-running node | Edge-case enumeration | Withstood | None |
| 4 | No new module / supervised child / public API | Integration check | Withstood | None |
| 5 | Reversible without schema rollback | Type-level / static check | Withstood (qualifier narrowed in place) | None |

## Revision required

None. All claims withstood falsification. The revision-1 correction from
`inserted_at` to `created_at` and from `memory` to `memory_entries`
resolves the prior validator's falsification on Claim 1.

- **Target file:** n/a
- **Revision kind:** n/a
- **Rationale:** n/a

## Outstanding doubts

These doubts do not falsify any claim — they remain for the parent
validator's awareness as candidate qualifiers when this leaf's solution is
synthesised upward.

- Compile-time-only thresholds (`@check_interval_ms`, `@stale_threshold_ms`)
  bake the SLA into a recompile. Solution.md §Open questions acknowledges
  this. Not a defect because the AC does not require runtime tuning, but
  a future operator may prefer `Application.get_env/3` indirection. If
  the embedding timeout changes (`@request_timeout_ms` in
  `embedding_worker.ex:37`), `@stale_threshold_ms` must be hand-edited
  in lockstep — a coupling worth surfacing in the parent's Qualifier.
- The absence of an `(embedding_status, created_at)` index is appropriate
  for current row volumes but becomes a performance hazard at scale. A
  follow-up index migration is anticipated in solution.md §Open questions
  and §Migration sketch. Not a defect at landing but a known scaling
  qualifier.
- The detection latency upper bound (~95 s = `@check_interval_ms` +
  `@stale_threshold_ms` − `@request_timeout_ms`) is implicit in the
  configuration and not stated as a contract anywhere. The parent
  problem (`tau-memory`) may want to make this explicit if downstream
  sub-problems (e.g. `retry-recovery-path`) depend on it.

---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 0
---

# Solution: Thread `instance_id` through `Application.start/2`; derive all names via `Tau.Names`; store in `:persistent_term`

## Recommendation

Adopt Proposal 2 in full. Introduce `Tau.Names` — a plain struct module with a
`compute/1` function that derives the complete set of process and ETS table names
from a single `instance_id` atom — and store the result once in `:persistent_term`
at `Application.start/2`. Every call site that currently references `Tau.PubSub`,
`Tau.Providers.Finch`, or a named registry by bare atom is updated to read
`Tau.Names.get().field` instead. `CircuitBreaker.Store` and `Cost.Tracker` each
gain a five-line change to accept `name:` and `table:` opts; `Tau.Registries`
is updated to thread per-name opts to its seven `Registry` children. The
`:default` instance id preserves every existing atom name, so deployed
configurations require no migration and all existing tests that do not start a
second instance are unaffected by the call-site rewrite.

## Selected from

- **Chosen:** `proposals/proposal-2.md`
- **Why chosen:** See scoring table below. Proposal 2 is the only proposal that
  achieves deep decomplecting (deployment topology fully separated from process
  identity), satisfies all three acceptance-criterion sub-questions in one
  atomic change, and does so at a bounded, mechanical cost with no
  performance regression on hot paths. Proposal 1 satisfies only the
  test-fixture scenario, leaves the production collision latent, and relies on
  `Application.put_env/3` — an OTP-NN §1 violation that also races under
  parallel test runs. Proposal 3 adds a GenServer hop on every hot-path name
  resolution, increasing render-loop latency without offering capabilities that
  `:persistent_term` does not already provide for a read-mostly name store.
  Proposal 4 structurally eliminates atom registration (deepest decomplecting)
  but at High migration cost and introduces a bootstrapping uncertainty
  (`Registry` self-naming via `{:via, ...}`) that would require a prototype
  before commitment; the irreversibility of its API-breaking `start_link/1`
  changes makes it poorly suited to land first.

### Scoring table

| #  | Fit        | Decomplecting depth | Migration cost | Risk   | Reversibility |
|----|------------|---------------------|----------------|--------|---------------|
| 1  | Partially  | Surface             | Low            | Medium | Easy          |
| 2  | Yes        | Deep                | Medium         | Low    | Easy          |
| 3  | Yes        | Substantial         | Medium         | Medium | Easy          |
| 4  | Yes        | Deep                | High           | Medium | Hard          |

**Proposal 1 — Partially/Surface:** Eliminates the test-fixture collision only;
the production multi-tenant collision remains. `Application.put_env/3` for
runtime name state violates OTP-NN §1 and races under async ExUnit. The
`Tau.Names` module it introduces is also needed by Proposal 2, so its useful
subset is a subset of P2.

**Proposal 2 — Yes/Deep:** `Tau.Names.compute/1` is a pure derivation; the
`:persistent_term` store is set once at startup and read at O(1) cost; the
`:default` clause preserves all existing atoms. Both the test-fixture and
production multi-tenant scenarios are resolved. Call-site churn (~30 locations)
is entirely mechanical and verifiable with `grep`.

**Proposal 3 — Yes/Substantial:** Names are held in a GenServer; every hot-path
dispatch adds a mailbox hop unless callers cache the map at `init/1`. This
trades a trivial `:persistent_term` read for per-process state management with
no benefit over P2 for a read-mostly store. The "monitored crash cascades"
argument is correct OTP reasoning but the blast radius (names crash → all
sessions crash) is higher than desired; `:persistent_term` is appropriate for
data that does not need supervised lifecycle.

**Proposal 4 — Yes/Deep, but Hard reversibility:** Pure structural fix — no atom
names except one. Deferred because: (a) the bootstrapping question (can
`Tau.Registries` children start under `{:via, ...}` names supplied by
`Tau.Instance.Registry`?) requires a prototype to resolve; (b) API-breaking
`start_link/1` changes are difficult to revert if the bootstrapping answer is
"no"; (c) Medium migration cost is an underestimate given the test-suite changes
needed. P4 is the right long-term destination; P2 lands cleanly on the path to
it — `Tau.Names.compute/1` can be replaced by a `{:via, ...}` derivation in a
future PR without affecting any call sites.

## What changes

- **New file `lib/tau/names.ex`** — `Tau.Names` struct + `compute/1` + `get/0`
  + `get/1`. ~70 lines. `compute(:default)` returns the existing module atoms
  unchanged; `compute(id)` appends `".#{id}"` or `"_#{id}"` per convention.
- **`lib/tau/application.ex`** — `start/2` reads `instance_id` from args
  (default `:default`), calls `Tau.Names.compute/1`, stores result in
  `:persistent_term` under `:tau_names` (and `{:tau_names, instance_id}` for
  non-default), then threads `names.*` fields into every named child's
  `start_link/1` opts. The supervisor itself is named `names.supervisor`.
- **`lib/tau/circuit_breaker/store.ex`** — `start_link/1` and `init/1` accept
  `name:` and `table:` opts with defaults `__MODULE__` and `:tau_circuit_breakers`.
- **`lib/tau/cost/tracker.ex`** — same pattern as `CircuitBreaker.Store`.
- **`lib/tau/registries.ex`** — `start_link/1` and `init/1` accept a `names:`
  struct and pass `names.<role>_registry` to each of the seven `Registry`
  children.
- **~30 call sites in `lib/`** — each bare `Tau.PubSub`, `Tau.Providers.Finch`,
  and registry-module-atom reference replaced by `Tau.Names.get().<field>`.
  Verifiable with `grep -rn "Tau\.PubSub\|Tau\.Providers\.Finch\|Tau\.Tools\.Registry\|Tau\.Sessions\.Registry"`.
- **D-044 note** — document in the PR description that the ETS table name is not
  part of the circuit-breaker row schema; `@schema_version` does not need a
  bump.

## What does not change

- All `start_link/1` external signatures remain backward-compatible for the
  `:default` instance (all defaults match the current atoms).
- The `Tau.Provider` behaviour, all provider adapters, and the session FSM logic
  are untouched.
- `Tau.Registries` supervisor strategy and child count.
- `Tau.Sessions.Supervisor` registration mechanism (it receives its `name:` from
  the application; internal session pids continue using the sessions Registry).
- Test files that do not start a second instance compile and pass without change.
- `docs/spec/SPEC-CIRCUIT-BREAKER.md` D-044 schema version — no row-layout change.

## Migration sketch

1. Land `lib/tau/names.ex` with `compute/1` and `get/0`/`get/1`. No callers yet;
   purely additive. Verify `compute(:default)` round-trips identical atoms in an
   `iex -S mix` session.
2. Update `CircuitBreaker.Store` and `Cost.Tracker` to accept `name:` / `table:`
   opts with defaults. `mix test` must still be green (defaults preserve existing
   atoms).
3. Update `Tau.Registries` to accept `names:` struct and thread registry names to
   children. Add `names: Tau.Names.compute(:default)` to its `Application.start/2`
   entry to pass the regression baseline.
4. Update `Application.start/2` to call `Tau.Names.compute/1` and store in
   `:persistent_term`. Thread all `names.*` fields to children. `mix test` green.
5. Sweep ~30 call sites from bare atoms to `Tau.Names.get().<field>`. `grep`
   post-sweep confirms zero residual bare references. `mix compile --warnings-as-errors`
   and `mix test` green.
6. Add a one-test property asserting that `Tau.Names.compute(:default)` returns
   the historically-expected atoms (regression guard).

## Open questions

- Does any call site hold a reference to `Tau.PubSub` as a compiled-in constant
  in a match spec (e.g. in an ETS `match_spec` or a `with`-pattern on a returned
  atom)? The `grep` sweep in step 5 would catch raw module references but not
  indirect ones stored in structs at compile time. Manual audit of
  `CircuitBreaker.Store` and `Cost.Tracker` match specs is recommended.
- `Tau.Memory.Supervisor` and `Tau.Extensions.Loader` — neither is in the named
  children list today, but `embedding_worker.ex:106` holds a Finch name mismatch
  (noted as out of scope). After this change, `Tau.Names.get().finch` is the
  canonical resolution; the embedding worker's mismatch should be fixed as a
  follow-on in the tau-memory audit.
- `:persistent_term.put/2` in `Application.start/2` leaves an orphaned term if
  the supervisor tree fails to start mid-way. Documented as benign (no sessions
  can form), but a `try/after` guard could clean it up. Out of scope for this PR;
  worth a follow-up if the startup failure mode becomes a test concern.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Test-isolation shim via `Application.put_env/3`
  (narrowly satisfies test-fixture scenario; OTP-NN §1 violation; superseded by P2)
- `proposals/proposal-2.md` — Thread `instance_id` through `Application.start/2`;
  `:persistent_term` name store **(selected)**
- `proposals/proposal-3.md` — `Tau.Instance` GenServer holds name-set; names
  resolved via `GenServer.call` (correct OTP reasoning; hot-path mailbox hop
  unnecessary for a read-mostly store)
- `proposals/proposal-4.md` — Eliminate atom names entirely; `{:via, Registry, ...}`
  everywhere (deepest fix; deferred pending bootstrapping prototype; P2 is on
  the path to this)

## Revision history

- (revision 0 — initial)

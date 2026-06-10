---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from: [subproblems/merge-invariant-properties/solution.md, subproblems/schema-exception-as-flow/solution.md, subproblems/watcher-exit-catch/solution.md]
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: Three orthogonal, file-disjoint corrections to `Tau.Settings` landed as independent commits

## Recommendation

Land each child solution as an independent commit on a single PR, in
the order **schema → watcher → loader**. Each commit touches a single
production file plus its tests, with no cross-commit coupling: (1)
replace `Schema.to_known_module/1`'s `try/rescue ArgumentError` binary
clause with a `case Map.fetch(@known_provider_names, str)` over a
compile-time map derived from `@known_providers`; (2) delete
`Settings.Watcher.maybe_start_watcher/1`'s `try/rescue/catch` block in
favour of a plain `case` on `FileSystem.start_link/1`'s return value
AND add `Process.monitor/1` + a `handle_info({:DOWN, ...})` clause so
post-startup `FileSystem` crashes transition the Watcher to degraded
mode at runtime; (3) refactor `Loader` to expose a `@merge_rules`
module attribute and `merge_rules/0` accessor, then add a standalone
`test/tau/settings/loader_property_test.exs` with a prose `@moduledoc`
contract and three algebraic-law properties (associativity,
idempotency, scalar override) plus one rule-table property keyed off
`merge_rules/0`. Collectively this eliminates both OTP NN
violations (#7 in Watcher, #6 in Loader's property coverage) and the
exception-as-control-flow defect in Schema, with no behaviour change
visible to any existing caller and zero regressions in the existing
test suite.

## Selected from

- **Synthesised from:** child solutions at
  `subproblems/merge-invariant-properties/solution.md`,
  `subproblems/schema-exception-as-flow/solution.md`,
  `subproblems/watcher-exit-catch/solution.md`.
- **Composition rationale:** the three sub-problems were decomposed
  along the **concern** axis (parent `problem.md` §Decomposition
  strategy) and the children's recommendations confirm the
  decomposition was clean: each child names a distinct production file
  (`schema.ex`, `watcher.ex`, `loader.ex`) with no overlapping
  callsites, no shared support modules (the merge-invariant child
  explicitly rejects a shared `test/support/settings_generators.ex`),
  and no shared public API. There is no interface between the
  children's recommendations and no conflict to resolve. The
  composition is direct: applying all three children's `What changes`
  sections yields the parent acceptance criterion as a logical
  conjunction — (a) the `catch :exit` site in Watcher is eliminated,
  (b) `Loader.merge/2` gains property coverage, and (c) Schema's
  rescue-based control flow is replaced with explicit conditional
  logic, all without breaking any currently-passing test. The
  selection method is `synthesis` because the parent solution is
  ordering + commit hygiene the children individually cannot specify;
  no child solution is dropped or altered.

## What changes

The full enumeration is the union of the three children's `What
changes` sections, re-grouped per commit:

**Commit 1 — Schema (`subproblems/schema-exception-as-flow`):**

- `lib/tau/settings/schema.ex`: add `@known_provider_names` module
  attribute computing
  `Map.new(@known_providers, fn mod -> {Atom.to_string(mod) |> String.replace_prefix("Elixir.", ""), mod} end)`.
- `lib/tau/settings/schema.ex`: replace the binary clause body of
  `to_known_module/1` (the `try ... rescue ArgumentError` block) with
  `case Map.fetch(@known_provider_names, str) do {:ok, mod} -> {:ok, mod}; :error -> {:error, {:unknown_provider, str}} end`.

**Commit 2 — Watcher (`subproblems/watcher-exit-catch`):**

- `lib/tau/settings/watcher.ex`: delete the `try/rescue/catch` block
  in `maybe_start_watcher/1`; replace with a plain
  `case FileSystem.start_link(dirs: dirs)` with `{:ok, pid}` and
  `other ->` arms.
- `lib/tau/settings/watcher.ex`: in `init/1`, after
  `maybe_start_watcher/1` returns `{:ok, pid}`, call
  `Process.monitor(pid)` and store the reference as `watcher_mon` in
  state (default `nil` in the degraded branch).
- `lib/tau/settings/watcher.ex`: add
  `handle_info({:DOWN, ref, :process, _pid, reason}, %{watcher_mon: ref} = state)`
  emitting `[:tau, :settings, :watcher_degraded]` telemetry with
  `%{reason: {:fs_exit, reason}}` and setting
  `watcher: nil, watcher_mon: nil`.
- `lib/tau/settings/watcher.ex`: extract telemetry emission into a
  private `emit_degraded_telemetry/1` shared between the
  startup-failure and runtime-crash paths.

**Commit 3 — Loader (`subproblems/merge-invariant-properties`):**

- `lib/tau/settings/loader.ex`: replace `list_keys/0` (hardcoded list)
  with a `@merge_rules` module attribute (`%{atom() => :concat}`)
  covering the same 7 keys; add `def merge_rules/0` returning
  `@merge_rules`; rewrite `merge_value/3`'s list-dispatch clause to
  use `Map.get(@merge_rules, k, :override)`. Retain `list_keys/0` as
  `def list_keys, do: Map.keys(@merge_rules)` only if external
  callsites reference it; otherwise delete.
- `test/tau/settings/loader_property_test.exs` (new file): `@moduledoc`
  with prose contract (associativity, list-key concatenation, scalar
  override, idempotency; explicitly states commutativity is NOT an
  invariant); `@moduletag :property`; one `describe "rule-table contract"`
  property iterating `Loader.merge_rules()` over `:concat` keys; one
  `describe "algebraic laws"` block with three properties
  (associativity, idempotency, scalar override) using a local
  `coherent_triple/0` generator.

## What does not change

- `Settings.Cache` GenServer behaviour (publish/reload lifecycle).
- `Settings.Vault` backends and `vault/env_test.exs`.
- `Schema.@known_providers`, `@schema`, `json_schema/0`, the atom
  clause of `to_known_module/1`, and `resolve_fallback_chains/1`.
- `Settings.Schema` public API surface (no new public functions; no
  `provider_from_string/1`).
- `Settings.Watcher`'s debounce timer, `relevant?/1` path filter, and
  public API signatures.
- The Watcher's supervision-tree entry and restart strategy (the
  Watcher remains supervised; `FileSystem` remains monitored, not
  supervised under the Watcher).
- `Loader.load/1`, `Loader.paths/1`, source-tracking, cascade layer
  ordering, and file path resolution.
- `Loader.list_keys/0`'s observable behaviour (derived from
  `@merge_rules`; identical key set).
- `test/tau/settings/loader_test.exs` — the four existing example
  tests remain untouched.
- `test/tau/settings/schema_test.exs` — existing tests cover the
  changed path without modification.
- `mix.exs` — `ExUnitProperties` and `StreamData` are already
  available; no new dependency.
- No shared `test/support/settings_generators.ex` module is added.

## Migration sketch

A single PR with three commits in dependency-free order:

1. **Schema commit.** Edit `lib/tau/settings/schema.ex` as in Commit
   1 above. Run `mix test test/tau/settings/schema_test.exs`; then
   `mix compile --warnings-as-errors`. Smallest, safest, lowest-risk
   change — sequenced first so a failure here can be reverted without
   touching the larger Watcher/Loader work.
2. **Watcher commit.** Apply Commit 2's two phases as a single
   commit: (a) replace the `try` block with the plain `case`; (b) add
   `Process.monitor` in `init/1`, the `watcher_mon` state field, the
   `handle_info({:DOWN, ...})` clause, and the
   `emit_degraded_telemetry/1` helper. Run the existing Watcher
   tests; add a `send/2`-driven unit test of the `{:DOWN, ...}`
   handler if practical, otherwise file as the follow-up the child
   solution recommends.
3. **Loader commit.** Apply Commit 3's production refactor and new
   property file together. Run
   `mix test test/tau/settings/loader_test.exs` (examples unchanged),
   then `mix test --only property test/tau/settings/loader_property_test.exs`
   (new properties pass), then `mix test` (full suite green).
4. **Final.** `mix compile --warnings-as-errors` and `mix credo
   --strict` on the merged tree. Open the PR with body citing the
   parent `problem.md`'s acceptance criterion as advanced by these
   three commits collectively.

The order schema → watcher → loader is chosen for blast-radius
minimisation: Schema's change is the smallest and most local; the
Watcher's change touches OTP signal handling and is therefore
medium-risk and worth landing in isolation; the Loader's change
includes a new test file and is the largest single commit. The order
is **not load-bearing** — the three commits are file-disjoint and
could land in any order, but this order makes review easier and a
mid-PR revert cleaner.

## Open questions

- (Inherited from Schema child) **Provider name format.** The
  `@known_provider_names` map strips `"Elixir."`. Verify
  user-facing documentation does not describe short-form provider
  names (e.g. `"Anthropic"`); the rescue-based implementation has the
  same constraint silently. A grep of `docs/` and any settings
  reference material before implementation is sufficient.
- (Inherited from Schema child) **Future deeper namespaces.** A
  provider at `Tau.Providers.Foo.Bar` produces the key
  `"Tau.Providers.Foo.Bar"`. The key-derivation convention should be
  commented in the attribute definition.
- (Inherited from Watcher child) **Supervisor restart strategy.** A
  synchronous `:exit` from `FileSystem.start_link/1` now propagates
  through `init/1`; whether the Watcher's spec should be `:transient`
  vs `:temporary` is a supervision-tree question outside the parent
  scope but worth confirming before landing.
- (Inherited from Watcher child) **`rescue` arm removal vs library
  contract.** The hybrid removes the `rescue e` arm. The child judges
  this acceptable on the basis that `FileSystem` uses return values
  and exits rather than raises; this is not verified against the
  pinned version. A two-line grep of the pinned `file_system`
  dependency suffices.
- (Inherited from Watcher child) **`{:DOWN, ...}` handler test
  coverage.** The acceptance criterion does not require it; the child
  recommends a follow-up issue.
- (Inherited from Loader child) **`list_keys/0` external callsites.**
  Grep needed before deciding whether `list_keys/0` is kept derived
  or deleted entirely.
- (Inherited from Loader child) **`stream_data` API surface.**
  Confirm the pinned `stream_data` version supports
  `StreamData.fixed_map/1` and `StreamData.tuple/1` as used in the
  `coherent_triple/0` generator.
- (Parent-level) **PR shape.** Whether to land as one PR with three
  commits (recommended for review coherence) or three single-commit
  PRs (better blast-radius isolation if any commit pivots) is a
  workflow call; the factory-loop conflict check
  (`.claude/rules/factory-loop.md`) confirms the three are
  parallelisable so either shape is admissible.

## Linked sub-problems / proposals

- `subproblems/merge-invariant-properties/` → "Combine proposal-4's
  production data-shape change (`@merge_rules` attribute +
  `merge_rules/0`) with proposal-2's standalone
  `loader_property_test.exs` carrying a prose `@moduledoc` contract
  and three algebraic-law properties plus one rule-table property."
- `subproblems/schema-exception-as-flow/` → "Replace
  `to_known_module/1`'s `try/rescue ArgumentError` binary clause with
  a `case Map.fetch(@known_provider_names, str)` over a compile-time
  map derived from `@known_providers`."
- `subproblems/watcher-exit-catch/` → "Delete the `try/rescue/catch`
  in `maybe_start_watcher/1` in favour of a plain `case` on
  `FileSystem.start_link/1`'s return; add `Process.monitor/1` +
  `handle_info({:DOWN, ...})` to handle post-startup `FileSystem`
  crashes."

## Revision history

- (revision 0 — initial)

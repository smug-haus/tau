---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: root
synthesised_from:
  - subproblems/error-swallowing-rescues/solution.md
  - subproblems/run-loop-raw-receive/solution.md
  - subproblems/wizard-data-fidelity/solution.md
  - subproblems/reflective-module-dispatch/solution.md
selection_method: synthesis
mode: non-leaf
revision: 0
---

# Solution: tau-cli — four-PR module-wide correctness pass with one NN amendment

## Recommendation

The four child sub-problems compose directly: each owns a disjoint file set
and a disjoint concern, so they land as four independent PRs whose only shared
artefact is a one-time amendment to `.claude/rules/otp-non-negotiables.md` rule
#7 (the targeted-`catch :exit` carve-out required by the error-swallowing
fix). Order is determined by two real coupling edges, not by perceived
priority: (1) the NN #7 amendment must land first because the rescues PR
depends on it being in effect; (2) the run-loop and reflective-dispatch PRs
both touch `lib/tau/cli.ex` and must serialize against each other to avoid
mechanical merge conflicts. The wizard-data-fidelity PR is independent of all
others (touches `lib/tau/cli/init.ex`, `lib/tau/commands/builtin/logout.ex`,
`lib/tau/settings/schema.ex`, and the new `lib/tau/providers/catalog.ex`).
The resulting sequence is: **PR-0** (NN #7 amendment, doc-only) → **PR-1**
(rescues + targeted catches in `Tau.CLI.Extensions` / `Tau.CLI.MCP`) → **PR-2**
(run-loop `stream_from` + pure `classify_event/2` in `lib/tau/cli.ex`) →
**PR-3** (reflective-dispatch registries in `lib/tau/cli.ex`), with **PR-4**
(wizard `Catalog` extraction + `enabled_providers` schema key) parallelisable
against PR-1 and PR-2 once PR-0 has landed. The module-wide acceptance criterion
is the conjunction of the four child ACs; no child weakens another, and no
gap requires a new sub-problem.

## Selected from

- **Synthesised from:**
  - `subproblems/error-swallowing-rescues/solution.md` — hybrid of proposals 1+2: delete `safe_list/0` / `safe_reload/0`; targeted `rescue _` + `catch :exit, {:noproc, _}` + `catch :exit, reason` at the command-handler boundary; amend NN #7 with a targeted-form carve-out in the same PR family.
  - `subproblems/run-loop-raw-receive/solution.md` — hybrid of proposals 1+3: introduce `Tau.Session.stream_from/3` (no-op setup; already-subscribed); drive the headless drain via `Enum.reduce_while` over a pure `classify_event/2` reducer with `render_event/1` for `ToolStart`/`ToolEnd` side effects; delete `drain_run_loop/2` and `drain_session_end/2`.
  - `subproblems/wizard-data-fidelity/solution.md` — single (proposal 2): extract `Tau.Providers.Catalog` as the compile-time single source of truth for provider key/label/env-var/string-key; derive `Init.@providers` and `Logout.@credential_map` from it; persist the multi-selection set under a new top-level `"enabled_providers"` array key (not `"providers"`, which collides with ADR-0012 fallback chains).
  - `subproblems/reflective-module-dispatch/solution.md` — single (proposal 2): replace `resolve_provider/1` / `resolve_coding_agent/1` tail clauses with `@provider_registry` and `@coding_agent_registry` static maps in `lib/tau/cli.ex`; unknown strings produce `{:error, :unknown_*, name, known_list}`; the `Module.concat` / `String.capitalize` paths are deleted.
- **Composition rationale:** the four solutions are mutually disjoint in code
  ownership — Extensions/MCP CLI handlers, the `Tau.Session` stream surface +
  `cli.ex` drain, the wizard + logout + schema, and `cli.ex` resolver
  attributes — and mutually disjoint in concern: error isolation, OTP-compliant
  event consumption, persisted-data fidelity, and atom-safety of dispatch. The
  only real coupling is mechanical:
  - **NN #7 amendment ⇒ rescues PR.** The rescues child solution names the
    targeted-`catch :exit` carve-out as a precondition for its `catch :exit,
    {:noproc, _}` clauses to satisfy the literal reading of NN #7. Resolving
    this in a separate doc-only PR (PR-0) lets PR-1 ship without conflating
    a rule change with a code change.
  - **`lib/tau/cli.ex` shared file.** Both run-loop (PR-2) and
    reflective-dispatch (PR-3) edit `lib/tau/cli.ex`. They touch distinct
    regions (`drain_run_loop`/`drain_session_end` at lines 427–497 vs
    `resolve_provider`/`resolve_coding_agent` at lines 782–814) so are not
    semantically coupled, but the factory-loop conflict check requires
    serialization on a shared file. Land PR-2 first because its diff is
    larger and its rebase cost on a registry refactor is higher.
  - **No conflicts.** No child solution proposes a change that another
    contradicts. No child requires data or interfaces that another removes.
    The wizard solution adds a new module under `lib/tau/providers/`; the
    reflective-dispatch solution adds module attributes inside
    `lib/tau/cli.ex` and does NOT consult `Tau.Providers.Catalog` (Open
    questions §3 in the wizard solution flags the future cross-derivation
    of `Schema.@known_providers` from `Catalog` as a separate concern; the
    same flag now also applies to `cli.ex`'s `@provider_registry`, which
    could derive from `Catalog` in a follow-up — see Open questions below).

## What changes

PRs and files, in landing order:

- **PR-0 — NN #7 carve-out amendment (doc-only).**
  - `.claude/rules/otp-non-negotiables.md` — amend rule #7 to add: a targeted
    `catch :exit, {:noproc, _}` (or other named exit-reason shape) at a CLI /
    TUI command boundary is permitted as an OTP-recommended availability
    escape hatch; precedent `lib/tau/providers/rate_limiter.ex:86`.
  - No code changes.

- **PR-1 — Error-swallowing rescues in `Tau.CLI.Extensions` / `Tau.CLI.MCP`.**
  - `lib/tau/cli/extensions.ex` — delete `safe_list/0` and `safe_reload/0`;
    wrap `list/1` and `reload/1` in `try` blocks with `rescue _ -> stderr; N`
    and `catch :exit, {:noproc, _} -> stderr; N` / `catch :exit, reason ->
    stderr; N` arms; remove the dead `{:error, _}` arm in `reload/1` (callee
    is `GenServer.cast`); widen `@spec list/1` from `0` to `0 | 1`; keep
    `@spec reload/1` as `0 | 2`.
  - `lib/tau/cli/mcp.ex` — identical shape across `list/1`, `status/1`,
    `reload/1`; widen `@spec` for `list/1` and `status/1`; keep `reload/1`
    spec.

- **PR-2 — Run-loop raw-receive elimination in `lib/tau/cli.ex` +
  `Tau.Session`.**
  - `lib/tau/session.ex` — add `stream_from/3` (no-op setup;
    `:already_subscribed` sentinel) backed by `Stream.resource/3`; same
    receive body as `stream/2` with `after timeout -> {:halt, :ok}`.
  - `lib/tau/cli.ex` —
    - extract `classify_event/2` (pure: `struct() × map() →
      {:continue, map()} | {:halt, 0 | 1}`; fallback clause `Logger.debug`s
      unknown structs);
    - extract `render_event/1` and `render_event/2` (pure side-effecting:
      `ToolStart` / `ToolEnd` progress; `ToolEnd` takes `tool_names` as
      second arg);
    - replace `drain_run_loop/2` call in `run_cmd/1` with
      `Tau.Session.stream_from(session_id, :already_subscribed, timeout:
      10_000) |> Enum.reduce_while({%{}, 1}, fn e, {names, _} ->
      render_event(e, names); classify_event(e, names) end) |> elem(1)`;
    - delete `drain_run_loop/2` (lines 427–486) and `drain_session_end/2`
      (lines 489–497).
  - Tests — pure unit tests over `classify_event/2`; integration tests over
    `stream_from`.

- **PR-3 — Reflective-dispatch registries in `lib/tau/cli.ex`.**
  - `lib/tau/cli.ex` — add `@provider_registry %{String.t() => module()}`
    and `@coding_agent_registry %{String.t() => module()}`; replace all
    `resolve_provider/1` clauses (`nil` → default, binary →
    `Map.fetch(@provider_registry, name)`, no tail); replace all
    `resolve_coding_agent/1` clauses (`nil`, atom-passthrough, binary →
    `Map.fetch(@coding_agent_registry, name)`, no tail); update internal
    callsites to unwrap `{:ok, mod}` or handle `{:error, :unknown_*, name,
    known_list}` with `halt(1)` + stderr enumerating `known_list`; delete
    the `String.capitalize` limitation comment at lines 807–811.

- **PR-4 — Wizard data fidelity: `Tau.Providers.Catalog` + `enabled_providers`
  schema key.** (Parallelisable with PR-1 and PR-2 once PR-0 has landed.)
  - **New:** `lib/tau/providers/catalog.ex` — pure compile-time data;
    `@entries` with `key`, `label`, `env_var`, `string_key`; expose `all/0`,
    `by_key/1`, `by_string_key/1`, `credential_map/0`.
  - **New:** `test/tau/providers/catalog_test.exs` — property tests on
    uniqueness and non-nil env_var.
  - `lib/tau/cli/init.ex` — delete `@providers`; alias `Catalog`; in
    `drive_flow/1`, persist `"provider"` (first selection, backwards
    compatible) AND `"enabled_providers"` (the full ordered list of
    `Catalog.by_key(&1).string_key`).
  - `lib/tau/commands/builtin/logout.ex` — delete the `@credential_map`
    literal; replace with `@credential_map Catalog.credential_map()`
    (compile-time derivation; map values identical, so the Bedrock key
    drift is structurally eliminated).
  - `lib/tau/settings/schema.ex` — add `"enabled_providers" => %{"type" =>
    "array", "items" => %{"type" => "string"}}` to the top-level
    `"properties"` map. MUST NOT reuse `"providers"` (line 121 — ADR-0012
    fallback-chain object).
  - `test/tau/cli/init_test.exs` — assert written settings carry both
    `"provider"` (first) and `"enabled_providers"` (all).

## What does not change

- `Tau.Session.stream/2` — existing callers untouched; `stream_from/3` is
  additive.
- `Phoenix.PubSub` usage / D-004 subscribe-before-start in `run_cmd/1` — the
  subscription is still established before `Tau.start_session/1`; `stream_from`
  takes the `:already_subscribed` sentinel.
- `try/after` in `run_cmd/1` (telemetry-handler detachment) — explicitly out
  of scope; remains as-is.
- `Tau.Extensions.Loader.list/0` / `Tau.Extensions.Loader.reload_all/0` /
  `Tau.MCP.Reconciler.list/0` / `Tau.MCP.Reconciler.reload/0` — interfaces
  unchanged. The cast-based async reload semantics remain: `tau extensions
  reload` and `tau mcp reload` still return `0` on cast delivery; surfacing
  async-reload failures is out of scope (flagged in Open questions).
- Public function arities of `list/1`, `reload/1`, `status/1` — unchanged
  (only `@spec` ranges widen).
- `lib/tau/provider.ex` behaviour — no new callback.
- Provider modules under `lib/tau/providers/*` — no required change (the
  reflective-dispatch fix lives entirely in `cli.ex`'s module attributes).
- Coding-agent modules under `lib/tau/coding_agents/*` — no change.
- `lib/tau/cli/config.ex` `safe_to_atom/1` / `validate/1`, the rate-limiter's
  own targeted catch, `Tau.CLI.MCP.transport_for/1`,
  `Init.provider_string/1` (may be replaced by `Catalog.by_key/1` lookup but
  not required) — all out of scope per the children.
- The existing `"providers"` (plural) schema key — remains an object for
  ADR-0012 fallback-chain configuration; no shape or semantic change.
- The singular `"provider"` settings key — retained for backwards
  compatibility; a future deprecation pass (rename to `"default_provider"`)
  is flagged in Open questions and out of scope here.
- All items in the root problem's "Out of scope" section
  (`doctor_cmd/0` duplication, Mix-task copy-paste, `run_cmd/1` size
  beyond run-loop, `commands/builtin/` defects outside named files,
  comment cleanup, `main/1` dispatch compression).

## Migration sketch

PR-0 lands first as a doc-only PR; it is small and has no test surface. PR-1
is then unblocked and may proceed concurrently with PR-4. After PR-1 merges,
PR-2 lands (large diff in `lib/tau/cli.ex`); after PR-2 merges, PR-3 lands
(small diff in `lib/tau/cli.ex`, but on the same file so serialised against
PR-2 by the conflict-check rule). Each PR carries its own `mix compile
--warnings-as-errors` and `mix test` pass, including the test rewrites named
in each child solution (Extensions/MCP supervisor-down tests, `classify_event/2`
unit tests, registry-based resolver tests, `init_test.exs` assertions on the
new array key). The full module-wide AC is observable after PR-4 merges:
  - (a) crashed supervised callee → non-zero exit + stderr line (PR-1);
  - (b) headless run loop uses `stream_from`; unknown events log at `:debug`
    rather than being silently dropped (PR-2);
  - (c) `tau init` persists all selected providers under
    `"enabled_providers"`; `init`-side and `logout`-side credential keys for
    Bedrock are derived from the same `Catalog` entry (PR-4);
  - (d) `resolve_provider/1` and `resolve_coding_agent/1` reject unknown
    strings without `Module.concat` / `String.to_atom` on user input (PR-3).

## Open questions

- **NN #7 amendment review risk.** PR-0 is a rule change. If review rejects
  the targeted-`catch :exit` carve-out, the rescues child's documented
  fallback (pure deletion + top-level `Tau.CLI.main/1` rescue, both in PR-1)
  applies. The fallback bounds PR-1's risk but defers the rate-limiter
  precedent's compliance question to a separate cleanup.
- **Async reload failures invisible** (`Tau.Extensions.Loader.reload_all/0`
  and `Tau.MCP.Reconciler.reload/0` are `GenServer.cast`). Both child
  solutions flag this; module-wide it remains out of scope. A follow-up PR
  would convert one or both to `GenServer.call` (changing concurrency
  semantics) or add a telemetry feedback channel.
- **`main/1` top-level safety net.** The error-swallowing child notes that
  `Tau.CLI.main/1` (lines 69–136) has no top-level rescue, so handlers
  outside the four named commands remain exposed to raw BEAM crash dumps
  on uncaught exceptions. This is a sibling sub-problem not covered by any
  of the four children; surface to the root for triage rather than expand
  any PR's scope.
- **Cross-derivation of registries.** The reflective-dispatch child's
  `@provider_registry` and the wizard child's `Tau.Providers.Catalog` are
  two compile-time representations of the same provider set viewed through
  different lenses (CLI dispatch string → module vs wizard short string →
  vault env_var). They can drift on coverage. A future cleanup PR could
  derive `@provider_registry` from `Catalog` (`Map.new(Catalog.all(), fn e
  -> {e.string_key, e.module} end)`) after adding a `:module` field to
  `Catalog.@entries`. Flagged here so the divergence is intentional and
  reviewable, not silent.
- **`Tau.Settings.Schema.@known_providers` drift** — the wizard child's
  Open questions §3 also names this as a separate compile-time list of
  provider modules used by ADR-0012 fallback-chain resolution. It remains
  out of scope here for the same reason; a unified cross-derivation
  (Catalog ↔ `@known_providers` ↔ `@provider_registry`) is a sensible
  M-wide follow-up.
- **`stream_from/3` setup contract visibility.** The run-loop child notes
  that a mis-formed topic causes a silent empty drain. A guard or
  `{:ok, pid} | {:error, :not_subscribed}` setup return would make the
  contract explicit. Deferred to the implementer of PR-2.
- **Singular `"provider"` key deprecation.** Retained for backwards
  compatibility in PR-4; a future PR may rename to `"default_provider"` and
  treat `"enabled_providers"` as the sole list of record.

## Linked sub-problems / proposals

- `subproblems/error-swallowing-rescues/` → "Delete `safe_list/0` /
  `safe_reload/0`; targeted `rescue _` + `catch :exit, {:noproc, _}` at the
  command-handler boundary; amend NN #7 with a targeted-form carve-out."
- `subproblems/run-loop-raw-receive/` → "Add `Tau.Session.stream_from/3`;
  drive the headless drain via `Enum.reduce_while` over pure
  `classify_event/2` + `render_event/1`; delete `drain_run_loop/2` and
  `drain_session_end/2`."
- `subproblems/wizard-data-fidelity/` → "Extract `Tau.Providers.Catalog` as
  single source of truth; persist all selections under a new
  `enabled_providers` array key; derive `Logout.@credential_map` from
  `Catalog` at compile time."
- `subproblems/reflective-module-dispatch/` → "Replace `resolve_provider/1`
  / `resolve_coding_agent/1` tail clauses with `@provider_registry` /
  `@coding_agent_registry` static maps; unknown strings produce
  `{:error, :unknown_*, name, known_list}`."

## Revision history

- (revision 0 — initial root synthesis of four validated child solutions)

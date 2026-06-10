---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md]
selection_method: single
revision: 0
---

# Solution: Central `Tau.Tool.Executor` dispatch wrapper enforces the three contract properties

## Recommendation

Introduce a single dispatch wrapper, `Tau.Tool.Executor.call/4`, between
`Tau.Session.ToolDispatch.run_tool_validated/6` and any tool module's
`execute/2`. The wrapper is the one site responsible for enforcing the three
Tau.Tool contract points: (a) a `try/rescue` around `execute/2` that converts
any raise into `{:ok, Result.error(..., details: %{kind: :raised_exception,
...})}` before the existing outer guard sees it; (b) an `ensure_kind/1` guard
that injects `:unclassified` if a tool's `Result.details` omits `:kind`; and
(c) `[:tau, :tool, <name_atom>, :start]` / `:stop` / `:exception` telemetry
spans around every call. The live raise paths in `Bash.persist_full/3`
(`File.mkdir_p!/1`, `File.write!/1`) are simultaneously rewritten to the
non-raising `File.mkdir_p/1` / `File.write/1` variants so the executor's
rescue is defence-in-depth rather than the sole barrier. The `Tau.Tool`
behaviour, the `Tau.Tool.Result` struct, and every tool's public callback
signature are unchanged.

## Selected from

- **Chosen:** `proposals/proposal-1.md`
- **Why chosen:** Of the four proposals, only Proposal 1 satisfies all three
  acceptance criteria (a, b, c) at a single decomplected enforcement site
  without imposing a high migration cost or a hard-to-reverse change.
  Comparison table:

  | # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
  |---|---|---|---|---|---|
  | 1 | Yes (a, b, c) | Substantial | Low–Medium | Low | Easy |
  | 2 | Partially (b only) | Surface | High | Medium | Hard |
  | 3 | Yes (a, b, c) | Substantial | Medium | Medium | Hard |
  | 4 | Partially (a, b; c at session level only) | Surface | Low | Low | Easy |

  Proposal 2 (typed `Details` structs) decomplects schema visibility but
  re-complects via `Map.from_struct/1` at the `ToolResult` boundary, addresses
  neither no-raise nor per-tool telemetry, and demands an API-breaking
  taxonomy change across all six built-ins. Proposal 3 (`use Tau.Tool` macro)
  delivers the same enforcement scope as Proposal 1 but pays for it with a
  breaking callback rename (`execute` → `do_execute`), a `defoverridable`
  bypass that erodes the guarantee, and macro-injected private helpers that
  can collide with module-local names; reversibility is worse because every
  tool's compile-time shape changes. Proposal 4 (contract test case) is a
  useful regression guard but does not decomplect — each tool still
  independently owns the three properties; CI only catches what tests cover.
  Proposal 1 isolates enforcement to one composable function on the existing
  dispatch path, preserves every public interface, and is removable by
  deleting one module and reverting one line — the strongest score on
  decomplecting depth, reversibility, and composition.

## What changes

- **New file:** `lib/tau/tool/executor.ex` — defines `Tau.Tool.Executor.call/4`
  with the rescue, `ensure_kind/1` injection, and per-tool telemetry spans.
- **Modified:** `lib/tau/session/tool_dispatch.ex` — `run_tool_validated/6`
  replaces its direct `mod.execute(args || %{}, ctx)` call with
  `Tau.Tool.Executor.call(mod, args || %{}, ctx, started)`. The existing
  outer `try/rescue` and `[:tau, :tool, :execute, :start/:stop/:exception]`
  session-level telemetry are retained.
- **Modified:** `lib/tau/tools/builtin/bash.ex` — `persist_full/3` rewritten
  to use `File.mkdir_p/1` and `File.write/1`, returning `nil` on failure
  (truncation-log path is best-effort and degrades silently).
- **New tests:** unit test for `Tau.Tool.Executor.call/4` covering the three
  contract properties (a stub `RaisingTool`, a stub `MissingKindTool`, and a
  conformant stub assert telemetry-event firing); a property test for
  `ensure_kind/1` over arbitrary `Result.details` maps; updated `bash.ex`
  truncation-path tests reflecting the `nil`-on-error degradation.
- **Telemetry naming:** per-tool atom derived from the tool's compile-time
  module name (`String.to_existing_atom(String.downcase(mod.name()))`); for
  runtime-registered tools whose name is not already in the atom table, the
  wrapper falls back to `[:tau, :tool, :dynamic, :start/:stop/:exception]`
  with the tool name in metadata. This preserves observability without
  introducing an atom-table-growth attack surface.

## What does not change

- The `Tau.Tool` behaviour callback signatures (`name/0`, `description/0`,
  `parameters/0`, `execute/2`, `execution_mode/0`, `streams_updates?/0`).
- The `Tau.Tool.Result` struct definition (`content`, `details`, `terminate?`,
  `is_error`); `details` remains typed `map()`.
- Every existing tool module's public API and module shape.
- The session-side `Tau.Message.ToolResult` wire type and JSONL persistence
  format.
- The existing `[:tau, :tool, :execute, :start/:stop/:exception]`
  session-level telemetry events; per-tool events are additive.
- `Tau.Tools.Builtin.Delegate`'s pre-existing `[:tau, :tool, :delegate,
  :start/:stop/:exception]` events; the wrapper's events are emitted in
  addition and operators see a two-level namespace (documented in the
  Executor's moduledoc).
- The MCP `ToolAdapter` and `Tau.Hook` dispatch paths — both out of scope
  per problem.md.

## Migration sketch

Land in one PR. Sequence: (1) introduce `Tau.Tool.Executor` with full unit
test coverage; (2) swap the one-line call in `run_tool_validated/6`; (3)
rewrite `Bash.persist_full/3` to non-raising variants and update its
truncation-path tests; (4) update tool unit tests that assert on
`details` shape if they were relying on the absence of `:kind` (none are
expected — `ensure_kind/1` adds a key only when missing). The change is
behaviour-preserving for all conformant existing tools; tools that already
populate `:kind` see no shape change, and tools that already emit their own
sub-namespace telemetry continue to do so. Reversal is two file deletions
and one revert.

## Open questions

- Should `ensure_kind/1` injection of `:unclassified` emit a
  `Logger.warning/1` in `:dev` and `:test` to surface authoring errors during
  development without failing in production? The proposal is silent; the
  conservative choice is to warn in dev/test and stay silent in prod, but
  this can be deferred.
- For runtime-registered tools (MCP adapters, extensions) whose names are
  not compile-time atoms, the fallback `[:tau, :tool, :dynamic, ...]`
  namespace loses per-tool observability granularity. Is the metadata-tag
  workaround sufficient, or should runtime-registered tools opt into atom
  pre-registration at registration time?
- Should a CI-only contract test (the `ToolContractCase` idea from Proposal
  4) be added as a separate follow-up to guard against future tools
  bypassing the executor by being called outside `run_tool_validated/6`
  (e.g., from a test harness)? Not required for the acceptance criterion
  but a useful defence-in-depth.
- The `Bash.persist_full/3` `nil`-on-error degradation may be observed by
  downstream consumers expecting `details.full_output_path` to be either a
  valid path or absent. Confirm no current consumer treats `nil` as a path.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Central dispatch wrapper in
  `run_tool_validated/6` (chosen).
- `proposals/proposal-2.md` — Typed `Result.Details` structs with a behaviour
  callback (rejected: high cost, addresses only schema, hard to reverse).
- `proposals/proposal-3.md` — `use Tau.Tool` DSL macro that wraps `execute/2`
  at compile time (rejected: breaking callback rename, `defoverridable`
  bypass, macro/private-name collision risk).
- `proposals/proposal-4.md` — Contract-enforcement test suite with shared
  `ToolContractCase` + targeted production fixes (rejected: does not
  decomplect; per-tool telemetry criterion only partially met).

## Revision history

- (revision 0 — initial)

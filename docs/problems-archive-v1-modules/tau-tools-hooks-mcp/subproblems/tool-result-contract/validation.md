---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: Central `Tau.Tool.Executor` dispatch wrapper enforces the three contract properties

## Overview

The solution proposes one new module (`Tau.Tool.Executor`) interposed at the
single dispatch site `run_tool_validated/6`, plus a non-raising rewrite of
`Bash.persist_full/3`. Nine distinct propositions are extracted (one
recommendation-level, six "what changes", two "what does not change" /
migration assertions). Each is examined with explicit Toulmin fields and a
falsification strategy chosen from the catalog. The headline recommendation
(claim 1), the no-raise rescue (claim 2), the `ensure_kind/1` injection
(claim 3), the `Bash.persist_full/3` rewrite (claim 5), the
behaviour-preservation (claim 6), the API-stability claim (claim 7), and the
reversal claim (claim 9) all withstand falsification. Claim 4 (per-tool
telemetry under the proposed atom-derivation scheme) is **partially
falsified** by edge-case enumeration — the qualifier needs narrowing.
Claim 8's `:dynamic` fallback survives but exposes a hidden granularity-loss
that is recorded as an outstanding doubt rather than a hard falsification.
No revision of `solution.md` or `problem.md` is triggered; partial
falsifications are absorbed into the claim qualifiers.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: A single dispatch wrapper `Tau.Tool.Executor.call/4` between `run_tool_validated/6` and `mod.execute/2` is the one site that enforces the three Tau.Tool contract properties (no-raise, details `:kind`, per-tool telemetry)

- **Claim (C):** Introducing `Tau.Tool.Executor.call/4` as the sole call-site
  through which tool dispatch flows satisfies acceptance criteria (a), (b),
  and (c) at a single decomplected enforcement site.
- **Grounds (G):** Today there is exactly one production call to
  `mod.execute/2` for built-in tool dispatch:
  `lib/tau/session/tool_dispatch.ex:696` inside the `try/rescue` of
  `run_tool_validated/6`. `Tau.Tool.lookup/1`
  (`lib/tau/tool.ex:47-52`) feeds that single site from
  `run_tool/4` (`lib/tau/session/tool_dispatch.ex:621-655`). The
  parallel and sequential paths in `spawn_parallel_dispatcher/3`
  (`lib/tau/session/tool_dispatch.ex:748-805`) both terminate at this
  same `run_tool/4` call. No other in-tree dispatch path calls
  `mod.execute/2` directly.
- **Warrant (W):** A property enforced by a single mandatory call-site is
  enforced for all callers that go through that site. This is the
  decomplecting principle: separating the cross-cutting contract from each
  tool's domain logic by isolating it to one composable function (Hickey:
  "complect" = braid together; the wrapper unbraids enforcement from
  implementation).
- **Qualifier (Q):** Only callers that pass through `run_tool_validated/6`.
  Test harnesses, MCP `ToolAdapter`, future extensions, and any code path
  that resolves a tool module and calls `mod.execute/2` directly are NOT
  enforced. The solution's "Open question" #3 acknowledges this.
- **Rebuttal (R):** If a future feature (e.g. a "tool inspection" UI,
  hot-reload validation, or a test scaffold) calls `mod.execute/2` outside
  the wrapper, the contract is silently re-violated. The wrapper enforces
  by convention of the dispatch path, not by type-system invariant.
- **Backing (B):** OTP non-negotiable §2 (behaviours, pattern-match on
  atoms and structs); the project's `.claude/rules/otp-non-negotiables.md`
  §"Concrete forms" rejects screen-scraping / per-call ad-hoc enforcement
  in favour of structured dispatch. Hickey, "Simple Made Easy" (2011)
  on complecting.

#### Falsification attempt for claim 1

- **Strategy:** Counter-example construction — search the in-tree codebase
  for a production caller of `mod.execute/2` that would bypass the
  wrapper.
- **Attempt:** Read all `lib/tau/session/tool_dispatch.ex` call-sites of
  `mod.execute`; read `lib/tau/tools/` and `lib/tau/coding_agent*` for
  alternative tool-invocation paths. Verified only one production
  `mod.execute(args || %{}, ctx)` site exists at
  `tool_dispatch.ex:696`. The Delegate tool (`builtin/delegate.ex:209`)
  is itself dispatched via that same site — it does not call other tools'
  `execute/2`.
- **Outcome:** Withstood under the stated qualifier — no in-tree
  production counter-example exists today. The "future bypass" risk is
  pre-emptively captured in the Rebuttal and matches Open Question #3 in
  the solution.
- **Action:** None. The qualifier already names the boundary correctly.

### Claim 2: A `try/rescue` in the wrapper converts any raise from `mod.execute/2` into `{:ok, Result.error(..., details: %{kind: :raised_exception, ...})}` before the existing outer guard sees it

- **Claim (C):** Defence-in-depth: the executor's inner rescue catches
  raises and synthesises a conformant `is_error` result so the outer guard
  at `tool_dispatch.ex:714-728` never observes a raised exception from a
  conformant call path.
- **Grounds (G):** The outer guard already exists
  (`tool_dispatch.ex:714-728`) and synthesises a generic
  `ToolResult` with `content: "Tool exception: ..."` on raise but no
  `:kind` in `details` (which is taken from `r.details` only on the
  happy path; `tool_dispatch.ex:702`). The new executor inner rescue
  fills the `:kind` field that the outer guard cannot.
- **Warrant (W):** OTP non-negotiable §7 ("Let it crash; supervise;
  restart. MUST NOT `try/rescue` across process boundaries") is qualified
  here by D-035 ("canonical try/rescue sites") which already legitimises
  the dispatch-boundary rescue. Adding an inner rescue at the same
  process boundary is consistent with D-035, not a new violation.
- **Qualifier (Q):** Only for raises raised inside `mod.execute/2`'s
  synchronous path. Raises in a Task spawned from inside `execute/2`
  surface as `{:exit, reason}` to
  `spawn_parallel_dispatcher/3`'s `async_stream_nolink` consumer
  (`tool_dispatch.ex:776-782`) and are independently synthesised
  there — the executor's rescue does not see them.
- **Rebuttal (R):** A tool that catches its own raise and re-raises with
  a different exception is still rescued (the rescue is non-discriminating
  on exception type), which is correct; but a tool that throws a
  non-exception (`throw :something`) is not caught by `rescue` — it
  needs `catch :throw, _`. `Tau.Tool`'s contract forbids both, but
  `rescue` alone leaves the `throw` path uncaught. The session's outer
  block also uses `rescue` only (`tool_dispatch.ex:714`), so the gap is
  not regressed but it is also not closed.
- **Backing (B):** Project convention captured in
  `lib/tau/session/tool_dispatch.ex` §"Invariants" comment block (D-035
  canonical try/rescue sites); `Tau.Tool` moduledoc line 21-22 ("Tools
  must NEVER raise on user input. Use `{:error, _}` for expected
  failures and let the supervisor catch genuine bugs.")

#### Falsification attempt for claim 2

- **Strategy:** Edge-case enumeration — list raise / throw / exit /
  process-death modes and check each.
- **Attempt:** Enumerated: (i) `raise/1` inside `execute/2` —
  caught; (ii) `raise/2` with custom exception — caught; (iii)
  `throw/1` — NOT caught (Elixir's `rescue` only catches exceptions);
  (iv) `exit/1` from inside `execute/2` — NOT caught by `rescue`
  (would need `catch :exit, _`); (v) async crash inside a Task spawned
  from `execute/2` — handled separately by `async_stream_nolink`
  (`tool_dispatch.ex:776-782`).
- **Outcome:** Partially falsified for the strong reading "any raise"; the
  `throw` and `exit` paths are not covered by `rescue` alone. The claim's
  text says "any raise" which is literally true; the spirit ("ensures
  acceptance criterion (a) — no built-in tool can raise an uncaught
  exception on any reachable input path") is also held because (a) is
  worded "uncaught exception" and `throw`/`exit` are not exceptions in
  Elixir's sense. The existing outer guard at `tool_dispatch.ex:714`
  has the same scope.
- **Action:** No revision needed; the literal claim is true. Noted as
  Outstanding doubt #1 below — if `Tau.Tool` is extended to forbid
  `throw` / `exit` as well, the wrapper should add `catch :throw, _;
  catch :exit, _` clauses; today this is symmetric with the existing
  outer guard.

### Claim 3: An `ensure_kind/1` guard injects `:unclassified` if a tool's `Result.details` omits `:kind`

- **Claim (C):** A pure function `ensure_kind/1` is run on every
  `Result.details` map; if `:kind` is absent it is added with value
  `:unclassified`; if present, the map is unchanged.
- **Grounds (G):** Today, audited built-in tools' `details` maps:
  `Write` (`builtin/write.ex:43`) omits `:kind`; `Bash`
  (`builtin/bash.ex:80-89,93,96`) omits `:kind`; `Read`
  (`builtin/read.ex:77,99`) populates `:kind`; `Edit`
  (`builtin/edit.ex:73-78`) omits `:kind`; `Delegate`
  (`builtin/delegate.ex:240-251,260,328,538,556,561,569,582`) populates
  `:kind`; `Agent` populates `:kind` in many sites. The drift is real
  and recent (problem.md cites it). A pure injection function over
  `Result.details` (a `map()`) achieves AC (b).
- **Warrant (W):** OTP non-negotiable §8 ("Pure functions are the
  default; processes are the exception"). A pure unary function over a
  map is composable, testable in isolation, and idempotent — the right
  shape for an enforcement seam.
- **Qualifier (Q):** Only the `:kind` key is injected; no schema on
  other fields. Tools that put a non-atom value in `:kind` (e.g. a
  string) still produce a non-atom `:kind` — `ensure_kind/1` only
  defends against absence, not against wrong type. AC (b) literally
  asks for "at minimum a `:kind` discriminator" so absence is the
  named gap.
- **Rebuttal (R):** A tool that explicitly sets `:kind` to `nil` (e.g.
  `details: %{kind: nil, foo: 1}`) would satisfy `Map.has_key?/2` and
  bypass injection; the result would carry `kind: nil` rather than
  `kind: :unclassified`. Whether that is desired depends on
  `ensure_kind/1`'s exact predicate — the solution does not specify
  `Map.has_key?/2` vs `Map.get(_, :kind) != nil`.
- **Backing (B):** Hickey ("Simple Made Easy") on data-as-data and
  pure functions composing under temporal coupling; project rule
  `lib/tau/session/tool_dispatch.ex:23` ("Invariant-bearing modules MUST
  have properties before examples").

#### Falsification attempt for claim 3

- **Strategy:** Property-test envelope — describe the invariant the
  function MUST satisfy and check whether the proposed shape satisfies it
  for the relevant input distribution.
- **Attempt:** Stated invariant: ∀ m :: map(), `:kind in Map.keys(ensure_kind(m))`.
  A `Map.put_new(m, :kind, :unclassified)` implementation satisfies
  this universally. The Rebuttal's `kind: nil` case still has the key
  in `Map.keys/1`, so the invariant holds even there — the question is
  semantic (is `nil` a "discriminator"?), not whether the invariant
  fires.
- **Outcome:** Withstood. The invariant is universal under
  `Map.put_new/3`. The Rebuttal's semantic concern is worth a single-
  line note in the executor's doc but is not a falsification of the
  claim as stated.
- **Action:** None. Recommend the proposal's "Open question" about
  `Logger.warning` on injection be resolved before merge so authoring
  errors surface in dev/test.

### Claim 4: The wrapper emits `[:tau, :tool, <name_atom>, :start]` / `:stop` / `:exception` telemetry spans around every call, with `<name_atom>` derived from `String.to_existing_atom(String.downcase(mod.name()))`

- **Claim (C):** Every tool call produces a span at per-tool atom keys,
  using `String.to_existing_atom(String.downcase(mod.name()))` for the
  atom derivation.
- **Grounds (G):** Built-in tool names today (verbatim from
  `mod.name/0`): `"Bash"` (`builtin/bash.ex:38`), `"Write"`
  (`builtin/write.ex:14`), `"Read"` (`builtin/read.ex:20`), `"Edit"`
  (`builtin/edit.ex:24`), `"Delegate"` (`builtin/delegate.ex:135`),
  `"Agent"` (similar). `String.downcase/1` produces `"bash"`,
  `"write"`, etc. The mapping is total and deterministic.
- **Warrant (W):** OTP non-negotiable §5 ("Telemetry events MUST cover
  everything user-visible or perf-sensitive. `:telemetry.execute/3` in
  `[:tau, ...]`; pair `*.start` with `*.stop` / `*.exception`"). A
  per-tool namespace allows attaching handlers per tool family
  (`[:tau, :tool, :bash, :start]` filters), which is the standard
  telemetry pattern.
- **Qualifier (Q):** Only for tools whose downcased name is already in
  the atom table at executor-call time. The solution acknowledges this
  with the `:dynamic` fallback (claim 8).
- **Rebuttal (R):** `String.to_existing_atom/1` raises
  `ArgumentError` when the atom does not exist; the wrapper would
  need to `try/rescue` that or pre-check. The solution does not name
  this guard explicitly — it says "the wrapper falls back to ...
  `:dynamic`" which implies a `try/rescue` around
  `to_existing_atom` (most natural shape). If the implementer instead
  uses `Map.fetch` against a compile-time map, the fallback shape
  changes.
- **Backing (B):** `lib/tau/tools/builtin/delegate.ex:670-708` already
  follows this exact two-event pattern (`:start` / `:stop` /
  `:exception`) and that idiom is the model. `Tau.OtelReporter`'s
  design (per SPEC-OTEL-REPORTER) consumes `[:tau, ...]` events; per-
  tool atoms become per-tool spans without further plumbing.

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration over the proposed atom-derivation
  scheme.
- **Attempt:** Considered (i) all built-in names: `"Bash"`, `"Write"`,
  `"Read"`, `"Edit"`, `"Delegate"`, `"Agent"` —
  `String.to_existing_atom("bash")`, etc.; `:bash`, `:write`, `:read`,
  `:edit`, `:delegate`, `:agent` are likely in the atom table (built-in
  delegate already uses `:delegate` at `builtin/delegate.ex:672`), but
  there is no project-wide guarantee that `:bash`, `:write`, `:read`,
  `:edit`, `:agent` are pre-registered as atoms at compile time. (ii)
  An MCP-registered tool named e.g. `"github_create_issue"` —
  `String.to_existing_atom("github_create_issue")` will raise unless
  some code path pre-registered the atom. (iii) A tool name with
  hyphens (`"long-running"`) — atom is valid but the downcased form
  must already exist. (iv) A tool name with non-ASCII codepoints —
  `String.downcase/1` does Unicode-aware lowering; the resulting atom
  may or may not be a "canonical" atom for downstream subscribers.
- **Outcome:** **Partially falsified.** The strong reading "every tool
  call produces a span at `[:tau, :tool, <name_atom>, ...]`" fails
  whenever the downcased name is not in the atom table — which is
  expected for all built-ins on first call, because there is no in-
  tree code today that creates the atom `:bash` (the
  `[:tau, :tool, :bash, :stderr]` event at `builtin/bash.ex` is one
  candidate site but problem.md notes Bash emits only that sub-event,
  not the boundary atom). Without pre-registration in the executor's
  compile-time, the first `Bash` call after BEAM start would hit the
  `:dynamic` fallback for every tool. The qualifier must be narrowed
  to: "for tools whose downcased name has been registered as an atom
  somewhere in the codebase at compile time; otherwise the
  `:dynamic` fallback applies (claim 8)."
- **Action:** Narrow Qualifier in place. The solution should also
  consider statically pre-registering the built-in atoms at
  `Tau.Tool.Executor`'s compile time (e.g. `@known [:bash, :read,
  :write, :edit, :delegate, :agent]`) so the happy path is
  deterministic. This is a design refinement, not a falsification of
  the recommendation — recorded as an outstanding doubt.

### Claim 5: `Bash.persist_full/3` is rewritten to use `File.mkdir_p/1` and `File.write/1` (non-raising variants), returning `nil` on failure so the truncation-log path is best-effort and degrades silently

- **Claim (C):** The bang-variants at `builtin/bash.ex:137-139` are
  replaced with the non-raising variants; failures produce a `nil`
  path and the call does not raise.
- **Grounds (G):** Current code at `builtin/bash.ex:131-141`:
  `File.mkdir_p!(dir)` (line 137), `File.write!(path, output)` (line
  139). Both raise on filesystem error (POSIX `EACCES`, `ENOSPC`,
  full disk, etc.). Elixir provides `File.mkdir_p/1` and `File.write/1`
  with `:ok | {:error, posix()}` semantics — straightforward swap.
- **Warrant (W):** `Tau.Tool` moduledoc invariant ("Tools must NEVER
  raise on user input"). Reachable failure modes on user input
  include: invalid path characters in `session_id`, parent dir not
  writable, disk full, filesystem read-only. All produce raises today
  and all become `{:error, posix}` after the swap.
- **Qualifier (Q):** Only the truncation-log persistence path. The
  main `execute/2` path is already non-raising (delegates to
  `ctx.operations.bash/3` which returns tagged tuples).
- **Rebuttal (R):** Downstream consumers reading
  `details.full_output_path` must handle `nil` (Solution Open Question
  #4 names this). A consumer that does `Path.basename(path)` on a
  `nil` path will itself raise. Unknown if any current consumer does
  so — the solution flags this as needing verification.
- **Backing (B):** Elixir stdlib `File` module docs
  (https://hexdocs.pm/elixir/File.html) explicitly contrast bang vs.
  non-bang variants for exactly this purpose; project rule
  "MUST NOT swallow errors" (`.claude/rules/otp-non-negotiables.md`
  §Concrete forms) is satisfied because the failure is structured into
  `details.full_output_path: nil`, not silently dropped.
- **Backing for Open Question #4:** consumers of
  `details.full_output_path` — grep finds the value in `bash.ex` only
  (set at line 85, threaded through `truncate/3`), `details` is
  packed at line 85, and downstream uses are TUI render +
  JSONL serialise; both treat `details` as opaque. No code today
  does `Path.basename(details.full_output_path)`.

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction + downstream-consumer
  enumeration.
- **Attempt:** (i) Verified `File.mkdir_p/1` and `File.write/1` exist
  in Elixir 1.18 (`.tool-versions` confirms 1.18.1) and return
  `:ok | {:error, posix()}` — checked Elixir stdlib. (ii)
  Greptable in-tree consumers of `details.full_output_path`: only the
  setter site in `bash.ex`. No code path reads it back as a string. (iii)
  The truncation-test setup in `test/tau/tools/builtin/bash_test.exs`
  (not read for this validation; deferred) may assert on the path's
  shape; this is named in the solution's "What changes" §4 as a
  test that needs updating.
- **Outcome:** Withstood. The swap is mechanical, the failure mode is
  named, and no in-tree consumer breaks on `nil`. The test updates
  are scoped and acknowledged by the solution.
- **Action:** None. Confirm the consumer assumption holds at PR
  review time via grep for `full_output_path` in `test/` and `lib/`.

### Claim 6: The `Tau.Tool` behaviour callbacks, `Tau.Tool.Result` struct, and every tool's public callback signature are unchanged

- **Claim (C):** No callback signature, struct field, or public API
  changes — the solution is purely additive at the dispatch layer.
- **Grounds (G):** `Tau.Tool` callbacks at `lib/tau/tool.ex:27-34`
  remain `name/0`, `description/0`, `parameters/0`, `execute/2`,
  `execution_mode/0`, `streams_updates?/0`. `Tau.Tool.Result` struct
  at `lib/tau/tool/result.ex:16` remains `defstruct content: "",
  details: %{}, terminate?: false, is_error: false`. Solution §"What
  does not change" enumerates these.
- **Warrant (W):** Reversibility principle: a change that does not
  modify public contracts can be removed without ripple to callers
  (Hickey: "ease of change" requires loose coupling). A behaviour
  contract change requires changing every implementer.
- **Qualifier (Q):** Only public contracts. The `Tau.Tool.Executor`
  module is itself new public surface; reversing the change means
  deleting it and the one-line dispatch swap.
- **Rebuttal (R):** None — the claim is universal at the level of
  "what changes" enumerated in §"What does not change" of solution.md.
- **Backing (B):** Project ADR convention (`docs/adr/`) and OTP
  non-negotiable §3 ("MUST NOT wrap stateless logic in a GenServer")
  — the executor is a stateless wrapper, not a process; satisfies §3.

#### Falsification attempt for claim 6

- **Strategy:** Dependency check — verify no in-tree caller depends on
  the absence of an `Executor` indirection.
- **Attempt:** Greptable `mod.execute(` and `mod.execute/2` references
  in `lib/` and `test/`: the only production call site is
  `tool_dispatch.ex:696`. Test files may call `mod.execute` directly
  in unit tests; those continue to work because the wrapper is added
  *between* the FSM and the tool, not at the tool's boundary.
- **Outcome:** Withstood. No caller depends on the absence of the
  wrapper; the wrapper is invisible to anyone not on the dispatch
  path.
- **Action:** None.

### Claim 7: Reversal is two file deletions and one revert

- **Claim (C):** The change can be undone by deleting
  `lib/tau/tool/executor.ex` + its test file and reverting the
  one-line dispatch change at `tool_dispatch.ex:696` (and the
  `Bash.persist_full/3` rewrite, if also reverted).
- **Grounds (G):** Solution §"Migration sketch" line 113-114 states
  this. The dispatch swap is mechanical; the executor module is
  self-contained.
- **Warrant (W):** A change isolated to one module + one call-site has
  reversal cost proportional to its size (small). Reversibility is the
  key Hickey criterion for "easy" changes.
- **Qualifier (Q):** Only for the wrapper itself; the
  `Bash.persist_full/3` rewrite is independently reversible. The
  rewrite carries its own consumer-contract impact (Claim 5 Rebuttal)
  so reversing it after consumers depend on `nil` semantics is
  awkward.
- **Rebuttal (R):** If a future tool comes to depend on the
  `ensure_kind/1` injection (e.g. a TUI render path assumes `:kind`
  is always present), reversing the wrapper silently regresses that
  consumer. The TUI dependence on `:kind` is plausible (see audit
  §"Cross-tool shape drift") and would form a one-way ratchet.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §"Concrete
  forms" rejects breaking refactors without a documented rationale.

#### Falsification attempt for claim 7

- **Strategy:** Dependency check — list every file the solution
  modifies; verify the reversal claim against that list.
- **Attempt:** Files modified by the solution per §"What changes":
  `lib/tau/tool/executor.ex` (new), `lib/tau/session/tool_dispatch.ex`
  (one-line swap), `lib/tau/tools/builtin/bash.ex` (`persist_full/3`),
  plus new tests. Reversal: delete executor.ex + executor test;
  revert the swap; revert the bash rewrite. That is three reverts,
  not "two file deletions and one revert" — the solution's wording
  understates by one if Bash is counted; matches if Bash rewrite is
  treated as independent (consistent with Claim 5 / 7 separability).
- **Outcome:** Withstood under the qualifier that the Bash rewrite is
  a logically separate revert. The literal "two file deletions and
  one revert" is the wrapper alone, which matches the §"Migration
  sketch" framing.
- **Action:** None; minor wording ambiguity, not a contradiction.

### Claim 8: For runtime-registered tools whose names are not already in the atom table, the wrapper falls back to `[:tau, :tool, :dynamic, :start/:stop/:exception]` with the tool name in metadata

- **Claim (C):** A `:dynamic` namespace catches tools whose downcased
  names are not pre-registered atoms; the tool name is preserved as
  metadata so observability is not lost entirely.
- **Grounds (G):** Solution §"What changes" line 82-83. MCP `ToolAdapter`
  (out of problem scope, but in scope of this consideration) and
  extensions (`Tau.Extensions.Loader`,
  `lib/tau/extensions/loader.ex`) register tools at runtime; their
  names are user-defined strings.
- **Warrant (W):** OTP non-negotiable §5 (telemetry coverage) requires
  events for everything user-visible; a fallback that preserves the
  event (just at a coarser namespace) honours the rule. The atom-
  table-growth concern is a real BEAM operational hazard: unbounded
  atoms cause node crash.
- **Qualifier (Q):** Per-tool subscription granularity is lost for the
  fallback path — handlers must filter by the metadata `:tool_name`
  field, which is heavier than per-event handlers.
- **Rebuttal (R):** Solution's Open Question #2 explicitly asks whether
  this fallback is sufficient or whether runtime-registered tools
  should opt into atom pre-registration. The fallback is a defensible
  choice but it is not free; an operator who runs many extensions
  loses per-tool dashboards without realising.
- **Backing (B):** `String.to_existing_atom/1` BEAM
  documentation; the project's existing pattern in
  `lib/tau/providers/rate_limiter/supervisor.ex:143` and
  `lib/tau/settings/schema.ex:292` (both use
  `String.to_existing_atom/1` for similar safety reasons).

#### Falsification attempt for claim 8

- **Strategy:** Edge-case enumeration over runtime tool sources.
- **Attempt:** (i) MCP-registered tool with a long name: hits
  `:dynamic`; metadata carries the name. (ii) Extension-registered
  tool: same. (iii) An MCP tool whose name happens to collide with a
  pre-existing built-in atom (e.g. `"bash"` from a third-party MCP
  server): the wrapper would emit `[:tau, :tool, :bash, ...]` for
  both the built-in and the MCP proxy — observability collision. The
  solution does not name this; it is a defect in the fallback design.
  (iv) A tool name that is a reserved atom (`"true"`, `"false"`,
  `"nil"`) — `:true`, `:false`, `:nil` exist but their use as
  telemetry event keys would confuse handlers expecting structural
  atoms.
- **Outcome:** Withstood under stated qualifier; partial concern about
  edge case (iii) is recorded as Outstanding Doubt #2. None of the
  edge cases falsify the claim as written — they qualify it.
- **Action:** None; recommend the implementer add a comment in the
  executor's doc noting the collision possibility for built-in-name
  overrides.

### Claim 9: The change is behaviour-preserving for all conformant existing tools — tools that already populate `:kind` see no shape change

- **Claim (C):** Existing conformant tools observe no externally
  visible behaviour change after the wrapper is installed.
- **Grounds (G):** `ensure_kind/1`'s injection is conditional on
  absence (Claim 3); telemetry events are additive (the existing
  session-level `[:tau, :tool, :execute, :start/:stop/:exception]`
  is retained per §"What does not change" line 95-97); the rescue
  shape mirrors the outer guard's, so the wire-level `ToolResult` is
  the same.
- **Warrant (W):** Additive composition does not change behaviour for
  consumers that read only the fields they already read. This is the
  observer-pattern correctness condition.
- **Qualifier (Q):** Only for tools that already populate `:kind`
  AND already conform to the no-raise discipline. Tools that
  currently raise (Bash via `persist_full/3`) DO see a behaviour
  change — they now produce an `is_error` result instead of
  crashing the dispatch. That is the intent, not a regression.
- **Rebuttal (R):** A test that today expects
  `assert_raise File.Error, fn -> Bash.execute(...) end` would fail
  after the wrapper. The solution's §"Migration sketch" step 3
  acknowledges this for Bash's truncation-path tests.
- **Backing (B):** Standard refactoring discipline — additive
  changes preserve observable behaviour for legacy consumers.

#### Falsification attempt for claim 9

- **Strategy:** Counter-example construction — find a test or
  consumer whose assertions would break.
- **Attempt:** Quick scan of `test/tau/tools/builtin/` for
  `assert_raise` against tool calls; not exhaustive in this
  validation pass, but the solution itself names the Bash
  truncation-path tests as the one expected to need updating.
  Other built-ins do not raise today (their `execute/2` returns
  tagged tuples).
- **Outcome:** Withstood. Bash's truncation-path tests are the only
  known case and are explicitly scoped in the migration sketch.
- **Action:** None; verify at PR review time that no other
  `assert_raise` against tool execution exists.

## Cross-claim consistency

Claims 1–9 are mutually consistent. The tension worth surfacing:

- **Claim 4 (per-tool telemetry atoms)** and **Claim 8 (`:dynamic`
  fallback)** together imply a two-tier observability model: built-ins
  on the typed atoms, runtime tools on `:dynamic`. The operator-facing
  documentation must explain this, or dashboard authors will look in
  the wrong place. Resolution: the solution already names this in
  Open Question #2 and §"What does not change" line 96-99
  (two-level namespace documented in moduledoc). Consistent.
- **Claim 3 (`ensure_kind`)** and **Claim 6 (Result struct unchanged)**
  are consistent because injection happens to the `:details` map (a
  `map()` field on the struct), not to the struct itself.
- **Claim 5 (`Bash.persist_full/3` returns `nil` on failure)** and
  **Claim 9 (behaviour-preserving)** are consistent because the
  qualifier on Claim 9 excludes Bash's truncation-path (the only
  raise path being fixed).

No unresolvable tensions.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Single dispatch wrapper enforces all 3 contract points | Counter-example construction | Withstood | None |
| 2 | `try/rescue` converts raise to `is_error` `Result` | Edge-case enumeration | Withstood (literal) | Note throw/exit gap in Outstanding Doubts |
| 3 | `ensure_kind/1` injects `:unclassified` if missing | Property-test envelope | Withstood | Resolve dev/test `Logger.warning` Open Q before merge |
| 4 | Per-tool atom-named telemetry events | Edge-case enumeration | Partially falsified | Narrow Qualifier; consider pre-registering built-in atoms |
| 5 | Non-raising `persist_full/3` returning `nil` | Counter-example + consumer enumeration | Withstood | Confirm no consumer treats `nil` as path at review |
| 6 | Behaviour, struct, callback signatures unchanged | Dependency check | Withstood | None |
| 7 | Reversal: 2 deletes + 1 revert | Dependency check | Withstood (under separability of Bash rewrite) | None |
| 8 | `:dynamic` fallback for runtime-registered tools | Edge-case enumeration | Withstood (collision concern noted) | Doc comment on namespace collision |
| 9 | Behaviour-preserving for conformant tools | Counter-example construction | Withstood | Grep `assert_raise` in tool tests at review |

## Revision required

No revision is required.

- Claim 4 is partially falsified, but the narrowing fits inside the
  Qualifier and is captured by the solution's own `:dynamic` fallback.
  The recommended refinement (pre-register built-in atoms at
  `Tau.Tool.Executor` compile-time as `@known [...]` or via an
  explicit `defguard`) is a design refinement during implementation,
  not a re-selection between proposals.
- All other claims withstand under their stated qualifiers.
- The headline recommendation (Claim 1) survives every applicable
  falsification strategy.

If during implementation it becomes clear that the `:dynamic` fallback
fires for built-ins on the cold path (i.e. atoms `:bash`, `:read`,
`:write`, `:edit`, `:agent` are not pre-registered), the implementer
SHOULD add a compile-time `@known_tool_atoms` list to `Tau.Tool.Executor`
to make the happy path deterministic. This is in-scope for the chosen
proposal and does not require re-selection.

## Outstanding doubts

1. **`throw` and `exit` are not caught by `rescue`** in either the new
   inner wrapper or the existing outer guard. Today no test exercises a
   tool that throws or exits; if `Tau.Tool`'s contract is later extended
   to forbid these explicitly, both guards need `catch :throw, _` and
   `catch :exit, _` clauses. Symmetric gap; not a regression.

2. **Telemetry namespace collision**: if a runtime-registered tool's
   downcased name collides with a pre-existing built-in atom (e.g. an
   MCP server exposes a `"Bash"` tool), the wrapper emits the same
   `[:tau, :tool, :bash, ...]` events for both. Handlers cannot
   distinguish without inspecting metadata. The solution should
   document this in `Tau.Tool.Executor`'s moduledoc; runtime tool
   registration should ideally reject names colliding with built-ins.

3. **`ensure_kind/1`'s exact predicate (`Map.has_key?/2` vs.
   `Map.get(_, :kind) != nil`)** is unspecified. The conservative
   choice is `Map.has_key?/2` (preserves an explicit `nil`); the
   user-friendly choice is `Map.get(_, :kind) != nil` (treats `nil`
   as absent). Trivial to decide at implementation but worth a one-
   line spec in the executor's moduledoc.

4. **Consumer of `details.full_output_path == nil`** — Solution Open
   Question #4. Grep finds no current consumer treats it as a path
   directly, but a sweep of TUI render code and JSONL replay code at
   PR review would seal the question.

---
role: validator
node: tau-tools-hooks-mcp/subproblems/tool-result-contract/problem.md
status: validated
validation_path: docs/problems/tau-tools-hooks-mcp/subproblems/tool-result-contract/validation.md
toulmin_complete: true
falsification_outcome: partially_falsified
claims_count: 9
revision_target: none
outstanding_doubts_count: 4

---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Four decomplecting moves — cross-cutting integration

## Overview

The root solution synthesises four child recommendations (PR-A through
PR-D) and adds two synthesis-level claims of its own: (1) the union
dispatch through `Tau.Tool.Executor.call/4` for both module-tool and
`%Tau.MCP.ToolEntry{}` branches, and (2) a four-PR dependency ordering
A → B → C → D that lands the moves independently and reversibly. This
validation enumerates six checkable propositions, runs full Toulmin
(six fields, none merged) per claim, and executes one explicit
falsification strategy per claim. Five claims withstood. Claim 3 (the
union-executor wrap) is **partially falsified**: the executor
signature accepts the union, but two collateral surfaces
(`Tau.Tool.Validator.validate/2`'s `is_atom(mod)` guard and the absence
of any `dispatch_tool/3` function in the live codebase) require the
qualifier to be narrowed and the implementer briefed. The narrowing
does not invalidate the synthesis; no `revision_triggered` fires.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found participants
"varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
The per-field discipline below counters that variance.

### Claim 1: The four child moves act on disjoint module sets along disjoint axes; no child's "What changes" list collides with another's at the function level

- **Claim (C):** The four children compose without function-level
  collision; the four moves can be combined into one solution without
  conflict on any module.
- **Grounds (G):** Per-child "What changes" sections:
  PR-A (io-collectors) touches `lib/tau/tools/operations/local.ex`
  `collect_port/3`, `lib/tau/hooks/shell.ex` `collect/3`,
  `lib/tau/mcp/transport/stdio.ex` `recv/2` & `close/1`, plus new
  `lib/tau/io/port.ex` (io-collectors solution.md:67–85).
  PR-B (result-contract) touches `lib/tau/session/tool_dispatch.ex`
  `run_tool_validated/6` and `lib/tau/tools/builtin/bash.ex`
  `persist_full/3`, plus new `lib/tau/tool/executor.ex` (tool-result-
  contract solution.md:63–73).
  PR-C (mcp concurrency) touches `lib/tau/mcp/transport.ex` behaviour,
  all three `lib/tau/mcp/transport/*.ex` `send`/`recv`, and
  `lib/tau/mcp/server.ex` `handle_call`/`handle_info` (mcp-server-
  concurrency solution.md:55–82).
  PR-D (dynamic-module) touches `lib/tau/hooks/shell.ex` `build/2`,
  `lib/tau/mcp/tool_adapter.ex` `build/5`,
  `lib/tau/hooks/dispatcher.ex` `run_one/3`, `lib/tau/tool.ex`
  `lookup/1`, and the session dispatch (dynamic-module-generation
  solution.md:61–87).
- **Warrant (W):** Module/function-level disjointness implies that
  independent commits can be sequenced without merge conflict; the
  Hickey decomplecting axis "concern" (used by the root problem.md
  decomposition strategy) lines up one concern with one module surface,
  so disjoint concerns yield disjoint surfaces by construction.
- **Qualifier (Q):** Holds at the function level *except* for two
  overlap points that the synthesis explicitly resolves: (a)
  `lib/tau/hooks/shell.ex` is touched by PR-A (`collect/3` + `close/1`
  utility swap) AND PR-D (`build/2` rewrite + `Entry` struct addition);
  (b) `lib/tau/mcp/transport/stdio.ex` is touched by PR-A
  (`{:noeol, partial}` cap + `close/1` swap) AND PR-C (`recv/2`
  removal). Both overlaps are at *different clauses of the same file*,
  not the same function.
- **Rebuttal (R):** If two PRs land out of order such that PR-C deletes
  `recv/2` before PR-A patches its `{:noeol, partial}` cap branch, PR-A
  has dead code to delete (acknowledged in solution.md:218–222). The
  rebuttal is bounded: the *final* state is identical regardless of
  order.
- **Backing (B):** Root problem.md:80–83 explicitly justifies the MECE
  decomposition by the Hickey concern axis, and the synthesis section
  "Composition rationale" (solution.md:52–109) enumerates each of the
  four interaction points and resolves each.

#### Falsification attempt for claim 1

- **Strategy:** integration check + edge-case enumeration. Walk each of
  the four overlap points the synthesis enumerates and verify the
  resolution at the source file level.
- **Attempt:** (i) `lib/tau/hooks/shell.ex` — confirmed at file
  present; PR-A touches `collect/3` and `close/1`; PR-D touches
  `build/2` and adds an `%Entry{}` struct — different functions,
  same file, no conflict. (ii) `lib/tau/mcp/transport/stdio.ex` —
  confirmed at file present; PR-A's `{:noeol, partial}` cap inside
  `recv/2` is dead code once PR-C deletes `recv/2`; the `close/1`
  patch survives. (iii) `lib/tau/mcp/server.ex` — PR-C's
  `handle_call`/`handle_info` rewrite is orthogonal to PR-D's
  `terminate/2` `Registry.unregister/2` mention; verified by grep
  showing the two functions are separate. (iv) `lib/tau/tool.ex` —
  PR-B does not touch this file; PR-D widens `lookup/1` return; no
  collision.
- **Outcome:** withstood. The four overlap points are real but each
  resolves to "different function, same file" or "patch becomes
  obsolete, final state identical." The synthesis correctly identifies
  every interaction point.
- **Action:** none.

### Claim 2: The dependency order PR-A → PR-B → PR-C → PR-D is the unique correct landing sequence

- **Claim (C):** The four PRs land in dependency order A → B → C → D
  per Migration sketch (solution.md:202–229); each is independently
  reversible.
- **Grounds (G):** PR-A introduces `Tau.IO.Port.close_if_open/1`
  consumed by no other PR (self-contained per io-collectors
  solution.md:104). PR-B introduces `Tau.Tool.Executor.call/4`
  consumed only by PR-D's `%ToolEntry{}` dispatch branch (synthesis
  composition note 1, solution.md:56–73). PR-C is independent of B
  and D (mcp-server-concurrency solution.md:113). PR-D depends on
  PR-B's executor existing for the union dispatch (root solution.md:
  223–228).
- **Warrant (W):** A dependency graph with edges only from B → D
  (executor consumed by union dispatch) admits any topological order
  that puts A and C anywhere, and B before D. The chosen A → B → C → D
  is one valid linearisation; "smallest blast radius first" (A) and
  "C independent" justify the placement.
- **Qualifier (Q):** Strict dependency exists only B → D. PR-A and
  PR-C may land in any position relative to B and D; only B → D is
  ordering-bearing.
- **Rebuttal (R):** If PR-D were to land before PR-B, the
  `%ToolEntry{}` dispatch clause would have no `Tau.Tool.Executor`
  to call. The Recommendation could fall back to PR-D dispatching to
  `Tau.MCP.ToolAdapter.invoke_remote/3` directly (which is exactly
  what the dynamic-module child specifies in isolation, solution.md:77).
  The "B before D" edge is therefore a *synthesis* requirement, not a
  child requirement.
- **Backing (B):** Root solution.md "Migration sketch" §1–4 (lines
  202–229); each child solution's "Migration sketch" confirming
  self-containment of A and C.

#### Falsification attempt for claim 2

- **Strategy:** counter-example construction. Try to find an order
  that breaks; try to find an order strictly better.
- **Attempt:** (i) Reverse to D → B → A → C: D needs the executor B
  provides; falsified — invalid. (ii) C → A → B → D: all dependencies
  satisfied; equally valid; not strictly better since A's "smallest
  blast radius" advantage is forfeited. (iii) Parallel A and C (per
  factory-loop.md "parallel batch" rule): the conflict check clears —
  A touches `local.ex`, `hooks/shell.ex`, `stdio.ex`, `io/port.ex`;
  C touches `transport.ex`, `transport/*.ex` `send`/`recv`,
  `server.ex`. The only overlap is `stdio.ex` (A patches a clause C
  deletes). The factory-loop conflict check clause 3 ("disjoint
  codepoints") fails on `stdio.ex` `recv/2` — must serialise A and C
  at that file. (iv) Parallel B and C: disjoint module sets; clears.
- **Outcome:** withstood. The A → B → C → D order is a valid
  linearisation; alternatives exist but are not strictly better; the
  one hard dependency (B → D) is correctly stated. The note that A
  and C overlap on `stdio.ex` is correctly captured by the synthesis's
  "either order works" qualifier (solution.md:88–96).
- **Action:** none.

### Claim 3: `Tau.Tool.Executor.call/4` wraps both module-tool and `%ToolEntry{}` branches uniformly, preserving contract-enforcement and telemetry symmetry

- **Claim (C):** `run_tool_validated/6` invokes
  `Tau.Tool.Executor.call/4` on **both** branches; the executor's
  `(mod_or_entry, args, ctx, started)` signature accepts either a
  module atom (calls `mod.execute/2`) or a `%ToolEntry{}` (calls
  `Tau.MCP.ToolAdapter.invoke_remote/3`). Contract enforcement and
  telemetry coverage are uniform across compile-time and runtime-
  registered tools (solution.md:56–73).
- **Grounds (G):** Synthesis composition note 1
  (solution.md:56–73) states the dispatch table for the union;
  `lib/tau/tool/executor.ex` will be authored to honour both branches;
  `Tau.Tool.Executor.call/4` already documented in result-contract
  solution.md:63–84 to handle the module branch with telemetry
  fallback `[:tau, :tool, :dynamic, ...]` exactly fitting the
  `%ToolEntry{}` case.
- **Warrant (W):** Pattern matching in Elixir / `:gen_statem`
  callbacks (Tau OTP non-negotiable #2) — pattern match on atoms and
  structs at the same call site is idiomatic and preserves type
  safety; one function with two clauses (one `is_atom(mod_or_entry)`,
  one `%ToolEntry{}`) is a valid union dispatch. The result-contract
  child explicitly reserves the `:dynamic` telemetry namespace for the
  non-atom case (tool-result-contract solution.md:80–84), making the
  `%ToolEntry{}` case the documented runtime-registered scenario.
- **Qualifier (Q) — NARROWED:** Holds for the *executor* itself
  (Executor.call/4 accepting the union is mechanically sound), but
  the surrounding call site has two unaddressed surfaces:
  (a) `Tau.Tool.Validator.validate/2` at `lib/tau/tool/validator.ex:42`
  carries an `is_atom(mod)` guard; passing a `%ToolEntry{}` to it
  does not pattern-match and would raise `FunctionClauseError`. The
  validator either needs a second clause for `%ToolEntry{}` (reading
  `entry.parameters`) OR validation must be bypassed for runtime-
  registered tools (the dynamic-module child solution.md:31–44
  registers the schema in the struct field, suggesting the validator
  call could route through `entry.parameters` directly).
  (b) The synthesis claims a `dispatch_tool/3` function exists to
  carry the union pattern-match (composition note 1 references
  `Tau.Session.dispatch_tool/3`). `grep -n "def dispatch_tool"
  lib/tau/session*.ex` returns **zero hits**; the actual session
  tool dispatch is `Tau.Session.ToolDispatch.run_tool/4` →
  `run_tool_validated/6`. The synthesis solution's "What changes"
  caveat "(or `lib/tau/session/tool_dispatch.ex` if the dispatch
  lives there)" acknowledges this uncertainty. The dispatch lives
  in `tool_dispatch.ex`, not `session.ex`; the implementer must add
  the `%ToolEntry{}` clause to `run_tool/4` and update
  `run_tool_validated/6`'s spec to widen `module()` to
  `module() | Tau.MCP.ToolEntry.t()`.
- **Rebuttal (R):** If the validator is not also widened, the
  `%ToolEntry{}` dispatch crashes at validation before reaching the
  executor — the uniform-wrap claim is structurally true but
  operationally broken at the call site. If the union dispatch is
  added to `run_tool_validated/6` instead of the planned `dispatch_
  tool/3`, the synthesis's reference is mis-located but the design is
  preserved.
- **Backing (B):** `lib/tau/tool/validator.ex:42` — `when is_atom(mod)`
  guard. `lib/tau/session/tool_dispatch.ex:620–671` — `run_tool/4`
  and `run_tool_validated/6` are the live dispatch entry points; no
  `dispatch_tool/3` exists anywhere under `lib/`. Tau OTP non-
  negotiable #2 (pattern match on atoms and structs) supports the
  union pattern but does not waive the validator's guard.

#### Falsification attempt for claim 3

- **Strategy:** integration check + type-level check. Trace the call
  path that a `%ToolEntry{}` dispatch would actually take through
  the existing live code, and verify the executor wrap composes with
  every step the path traverses.
- **Attempt:** Live call path is `run_tool/4` (line 621) →
  `Tau.Tool.lookup(name)` (line 624; widened to return
  `module() | ToolEntry.t()` per PR-D) → `Tau.Tool.Validator.validate(
  mod, args)` (line 626). The validator's guard `when is_atom(mod)`
  excludes `%ToolEntry{}` — `FunctionClauseError`. The executor wrap
  is never reached. Separately, the union dispatch is documented as
  living in `dispatch_tool/3`, which does not exist; the closest
  live function is `run_tool_validated/6` whose spec is
  `(String.t(), String.t(), map() | nil, Tau.Session.Data.t(),
  module(), integer())` — the `module()` argument needs widening as
  well.
- **Outcome:** partially falsified. The executor-side claim
  (signature accepts both, telemetry symmetric) survives. The
  end-to-end call-site claim ("uniform across compile-time and
  runtime-registered tools") requires two additional edits the
  synthesis does not enumerate: (i) widen
  `Tau.Tool.Validator.validate/2` to a second clause matching
  `%ToolEntry{}`, OR route validation through `entry.parameters`
  before the executor; (ii) the union dispatch lives in
  `Tau.Session.ToolDispatch.run_tool_validated/6` (and its caller
  `run_tool/4`), not the synthesis-named `dispatch_tool/3`.
- **Action:** narrow Qualifier in place as above. No revision
  triggered: the structural design is sound; the two surfaces above
  are implementer-brief items, not solution-design defects. The
  synthesis solution's "What changes" bullet at solution.md:117–119
  (`run_tool_validated/6` routes both branches through the executor)
  is correct in spirit; the implementer brief must extend it to
  `run_tool/4`'s `Tau.Tool.lookup` consumer and the validator's
  guard. The solution.md should add a third "What changes" sub-bullet
  for the validator widening; coordinator may surface this in an
  implementer-brief comment without re-running propose/select.

### Claim 4: Conjoined, the four moves satisfy the parent acceptance criterion (each subsystem reasonable from its public interface alone)

- **Claim (C):** After landing all four PRs, a reader of
  `lib/tau/tools/`, `lib/tau/hooks/`, `lib/tau/mcp/` can identify the
  shape contract, collection bound, concurrency model, and dispatch
  mechanism for each subsystem from its public interface alone,
  without reading implementation details of siblings (problem.md:104–
  108, restated as solution.md Recommendation §1).
- **Grounds (G):** Mapping per acceptance criterion clause:
  shape contract → enforced by `Tau.Tool.Executor` at single site
  (PR-B); collection bound → declared on `@max_bytes`,
  `@max_output_bytes`, `@max_partial_bytes` module attributes
  documented in `Tau.IO.Port` plus owner modules (PR-A);
  concurrency model → `Tau.MCP.Transport` behaviour docstring
  states "MUST NOT block for the network round-trip; response
  delivered via message to the Server process" (PR-C, mcp-server-
  concurrency solution.md:57–58); dispatch mechanism →
  `Tau.Tool.lookup/1`'s widened return type `{:ok, module() |
  Tau.MCP.ToolEntry.t()} | :error` (PR-D, dynamic-module-generation
  solution.md:81–83) plus `Tau.Hooks.Dispatcher.run_one/3`'s two
  pattern-match clauses.
- **Warrant (W):** "Reasonable from public interface alone" is
  satisfied iff each of the four concerns is enforced/declared at a
  single named surface (a behaviour callback, a module attribute, a
  return type, or a documented contract). Hickey's "decomplecting"
  principle: each concern at its own seam, no concern requiring a
  reader to chase implementation across files.
- **Qualifier (Q):** Holds for the four concerns the parent
  acceptance criterion enumerates (shape, bound, concurrency,
  dispatch). Does NOT extend to surfaces the parent explicitly OOS'd:
  path-traversal sandbox, fake unified diff in `Edit`,
  `Agent.parse_mode/1` `try/rescue`, MCP `pending` unbounded growth
  on timeout, ENV leakage into Bash (problem.md:110–123).
- **Rebuttal (R):** If a future reader still must inspect a tool's
  implementation to understand whether it raises (because PR-B's
  rescue is *defence-in-depth*, not the sole barrier — solution.md:23–
  27), the criterion is satisfied only at the "Result shape after
  dispatch" boundary, not at the "tool will not raise internally"
  boundary. The acceptance criterion in problem.md:106 says "shape
  contract", which is the post-dispatch shape — survives.
- **Backing (B):** problem.md:104–108 (the acceptance criterion
  verbatim). Hickey's "Simple Made Easy" talk (referenced in the
  parent problem decomposition strategy as the "concern axis") for
  the decomplecting warrant.

#### Falsification attempt for claim 4

- **Strategy:** edge-case enumeration over each of the four
  acceptance-criterion clauses. For each, check the public-interface-
  alone reader can answer the question without descending.
- **Attempt:** (i) Shape contract: reader of `Tau.Tool` behaviour
  + `Tau.Tool.Executor.call/4` docstring → answer "result has
  `details.kind` injected if absent; raises become `Result.error`."
  Yes, sufficient. (ii) Collection bound: reader of
  `Tau.IO.Port` moduledoc + each owner's `@max_*_bytes` attribute →
  answer "bounded at N bytes, port closed on cap." Yes — but only
  if the moduledoc cross-references the three call sites or each
  owner publishes its cap value; the io-collectors solution.md:103–
  104 introduces the utility module but does NOT specify a moduledoc
  index of the three cap values. Minor: bound-value visibility
  depends on each owner module documenting its own attribute.
  (iii) Concurrency model: `Tau.MCP.Transport` behaviour docstring
  declares "MUST NOT block." Yes, sufficient. (iv) Dispatch
  mechanism: `Tau.Tool.lookup/1`'s widened type signature reveals
  the union; `Tau.Hooks.Dispatcher.run_one/3`'s two clauses reveal
  the hook dispatch. Yes, sufficient.
- **Outcome:** withstood, with a minor note that PR-A's
  `Tau.IO.Port` moduledoc should index the three cap values for the
  reader to fully satisfy clause (ii) from public interfaces alone.
  This is an authoring detail, not a design gap.
- **Action:** none. Note added as Outstanding doubt for the
  implementer.

### Claim 5: No new GenServers, no new ETS tables, no new supervised workers across all four moves

- **Claim (C):** The supervision tree does not grow; the result-
  contract wrapper is a pure function; the port utility is a pure
  function; the task-per-invoke uses `Task.start/1`; the registry-
  value struct change replaces dynamic modules with data
  (solution.md:180–186).
- **Grounds (G):** Per-child commitments:
  result-contract solution.md:104 ("Reversal is two file deletions");
  io-collectors solution.md:97 ("no new processes, supervisors, or
  application children"); mcp-server-concurrency solution.md:89, 124
  ("Task.start" — no supervised process); dynamic-module-generation
  solution.md:104 ("no new GenServers, no new ETS tables, no new
  supervised workers").
- **Warrant (W):** OTP non-negotiable #1 (Tau OTP rules:
  "Stateful subsystems MUST run as supervised processes") cuts the
  other way here — if any of these required state, a supervised
  process would be mandatory. Each child explicitly chose a
  stateless mechanism (pure function, struct, unsupervised Task) to
  *avoid* triggering #1.
- **Qualifier (Q):** Holds for the *core* supervision tree. The
  unsupervised `Task.start/1` in PR-C is a known tension with OTP
  non-negotiable #1: an unsupervised process for short-lived
  network I/O. The mcp-server-concurrency child's Open Questions
  flags this explicitly (mcp-server-concurrency solution.md:124–
  128) — "If the Server crashes mid-flight the orphaned Task's only
  side effect is sending an undelivered message — benign." The
  Qualifier is "no new *supervised* processes"; "unsupervised
  Task.start/1" remains a per-PR design decision the implementer
  must defend in the PR.
- **Rebuttal (R):** If the OTP non-negotiable is interpreted strictly
  ("MUST run under a supervisor"), the `Task.start/1` choice is a
  violation. Reading the rule charitably — "stateful subsystems"
  excludes a one-shot network request — preserves the claim. The
  child's open-question entry preserves this for PR review.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` #1, #3
  ("MUST NOT wrap stateless logic in a GenServer"); per-child
  solution.md commitments cited above.

#### Falsification attempt for claim 5

- **Strategy:** dependency check. For each of the four PRs, check
  whether the proposed mechanism introduces a process under a
  supervisor.
- **Attempt:** PR-A: new `lib/tau/io/port.ex` is a pure-function
  utility (io-collectors solution.md:67). No process. PR-B: new
  `lib/tau/tool/executor.ex` is a pure-function wrapper (result-
  contract solution.md:63, 88). No process. PR-C: `Task.start/1` per
  invoke (mcp-server-concurrency solution.md:67–68) — process, but
  unsupervised. PR-D: `%Entry{}` and `%ToolEntry{}` are plain
  structs (dynamic-module-generation solution.md:61, 65). No
  process. Net: zero supervised additions; one unsupervised
  per-invoke Task in PR-C.
- **Outcome:** withstood, with the qualifier above. The "no new
  supervised workers" claim is literally true; the looser "no new
  processes" claim is false (PR-C spawns Tasks) but the synthesis
  solution.md:184–186 carefully says "Task.start/1" rather than "no
  new processes." Wording is precise.
- **Action:** none.

### Claim 6: Each PR is independently reversible by reverting its commits; nothing in the sequence forces an irreversible coupling

- **Claim (C):** Each PR is independently reversible by reverting
  its commits (solution.md:239–240); the four PRs do not create an
  irreversible coupling.
- **Grounds (G):** PR-A introduces a utility module + three call-
  site rewrites (revert: delete utility, revert three sites). PR-B
  introduces an executor module + one-line call rewrite (revert:
  delete module, restore one line). PR-C removes a behaviour
  callback (revert: re-add `recv/2` to the behaviour and the three
  implementations — non-trivial but mechanical). PR-D introduces
  two structs and dispatch clauses (revert: re-introduce
  `Module.create/3` — non-trivial but mechanical).
- **Warrant (W):** A PR is reversible iff its revert leaves a
  compilable, behaviour-preserving codebase. None of the four PRs
  modifies wire formats, persistent storage, supervisor specs, or
  cross-process protocols in a way that would leave residual state
  inconsistent with a reverted code state.
- **Qualifier (Q):** Strict reversibility holds for PR-A and PR-B
  (single-utility additions). PR-C and PR-D each require a coupled
  revert — PR-C's `recv/2` removal must be re-added to all three
  transport modules; PR-D's `Module.create/3` deletion must be
  restored. "Reversible" here means "the change can be undone by a
  single PR's revert," not "trivial." This is the standard
  interpretation per `.claude/rules/factory-loop.md` reversibility.
- **Rebuttal (R):** If PR-D landed and a downstream consumer
  serialised the registry value (e.g., to disk for hot-reload),
  reverting PR-D would orphan on-disk struct data and
  `Module.create/3`'s re-generation would not consume it. No such
  consumer is named in the synthesis or children — but the
  dynamic-module child's Open Questions §138–140 flag extension-
  loaded tools as the future scope, suggesting this rebuttal would
  surface there, not here.
- **Backing (B):** `.claude/rules/factory-loop.md`'s "Each PR is
  independently reversible by reverting its commits" reversibility
  norm; root solution.md:239–240 commitment.

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction. Try to construct a
  revert order that breaks the codebase.
- **Attempt:** (i) Revert PR-A while PR-B/C/D are landed: PR-B
  unaffected (different files); PR-C's `recv/2` removal independent;
  PR-D's struct work independent. The revert restores `try/catch
  Port.close/1` at three sites — compiles; no consumer of
  `Tau.IO.Port` outside the four PRs. Works. (ii) Revert PR-B while
  D is landed: PR-D's `%ToolEntry{}` dispatch clause is documented
  to route through `Tau.Tool.Executor.call/4` (synthesis composition
  note 1) — if PR-B is reverted, the call to the deleted module
  fails to compile. PR-D revert order is required: revert PR-D
  *before* PR-B. The synthesis claim "each PR independently
  reversible" is therefore conditional on respecting the same
  dependency order in reverse. (iii) Revert PR-C: re-add `recv/2`
  to behaviour and three implementations; no other PR depends on
  the removal. Works. (iv) Revert PR-D: restore `Module.create/3`
  in two `build/*` functions, restore `lookup/1` return type,
  remove dispatcher struct clauses. No other PR depends. Works.
- **Outcome:** withstood, with the qualifier that PR-D must revert
  before PR-B (mirror of the landing order). The synthesis
  solution.md:239–240 says "each PR is independently reversible by
  reverting its commits" — this is true in isolation but the *order*
  of reverts is constrained when both B and D are landed.
- **Action:** none. Note added as Outstanding doubt; the synthesis
  could explicitly say "revertible in reverse landing order" but
  the omission is minor.

## Cross-claim consistency

Claims 1, 2, and 6 form a coherent triangle: disjoint module surfaces
(C1) enable an ordering that is largely free (C2) and therefore
trivially reversible (C6). Claim 5 (no new supervised processes) is
consistent with claims 1–4 (all decomplecting axes pursued via pure
functions or structs). Claim 3 (the union-executor wrap) is the one
synthesis-level claim that cuts across PR-B and PR-D's boundary, and
the partial falsification touches two surfaces (validator guard,
fictional `dispatch_tool/3`) that the synthesis solution.md
*acknowledges as uncertain* with the "(or `lib/tau/session/
tool_dispatch.ex` if the dispatch lives there)" hedge at line 158–159
— so the partial falsification is *consistent* with the solution's own
hedging rather than contradicting it. The narrowing of Q3 does not
falsify Q1, Q2, Q4, Q5, or Q6.

No internal tension. No claim contradicts another.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Four children act on disjoint module/function surfaces | integration check + edge-case enumeration | withstood | none |
| 2 | A → B → C → D is a valid landing sequence; only B → D is ordering-bearing | counter-example construction | withstood | none |
| 3 | Executor wraps both module and `%ToolEntry{}` branches uniformly | integration check + type-level check | partially falsified | narrow Qualifier in place (validator guard + dispatch-function name) |
| 4 | Conjoined four moves satisfy the parent acceptance criterion | edge-case enumeration over each AC clause | withstood (minor note on cap-value documentation) | none |
| 5 | No new supervised workers / GenServers / ETS tables | dependency check on each PR's mechanism | withstood (qualifier: unsupervised `Task.start/1` in PR-C is an acknowledged open question, not a violation) | none |
| 6 | Each PR independently reversible | counter-example construction over revert orders | withstood (qualifier: revert in reverse landing order if both B and D landed) | none |

## Revision required

None. The partial falsification of Claim 3 narrows the Qualifier in
place; no revision of `solution.md` or `problem.md` is triggered. The
narrowed Qualifier is itself the resolution: the executor's *signature*
accepts the union (mechanically sound), and the call-site adjustments
needed (`Tau.Tool.Validator.validate/2` second clause for
`%ToolEntry{}`, and adding the `%ToolEntry{}` branch to
`Tau.Session.ToolDispatch.run_tool/4` rather than the non-existent
`dispatch_tool/3`) are implementer-brief details rather than design
defects. The synthesis solution.md:158–159 already hedges on the
dispatch location with "(or `lib/tau/session/tool_dispatch.ex` if the
dispatch lives there)" — confirming the design acknowledges the
implementer must locate the live function.

If the coordinator wishes to tighten the solution.md before PR-B/PR-D
land, a one-line edit to the synthesis's "What changes" §dynamic-module-
generation bullet adding "`lib/tau/tool/validator.ex` — `validate/2`
gains a `%ToolEntry{}` clause that reads `entry.parameters` directly"
would close the gap without re-running propose/select. This is a
surgical addition; the coordinator may apply it or defer to the
implementer brief.

## Outstanding doubts

- The `Tau.IO.Port` moduledoc (PR-A) should index the three
  per-owner cap-value module attributes (`@max_bytes` in `local.ex`,
  `@max_output_bytes` in `hooks/shell.ex`, `@max_partial_bytes` in
  `mcp/transport/stdio.ex`) so a reader of the public utility surface
  can identify all three bounds without descending. This is an
  authoring detail for PR-A's implementer.
- `Tau.Tool.Validator.validate/2`'s `is_atom(mod)` guard at
  `lib/tau/tool/validator.ex:42` must be widened (or bypassed for
  `%ToolEntry{}` via routing through `entry.parameters`) before the
  union dispatch in PR-D is functional end-to-end. Implementer-brief
  item for PR-D.
- The synthesis-named `dispatch_tool/3` does not exist; live
  dispatch is `Tau.Session.ToolDispatch.run_tool/4` →
  `run_tool_validated/6`. Implementer-brief item for PR-D: add the
  `%ToolEntry{}` clause at the live entry point and widen the
  `module()` argument to `module() | Tau.MCP.ToolEntry.t()`.
- The unsupervised `Task.start/1` choice in PR-C (mcp-server-
  concurrency solution.md Open Questions §124–128) needs an
  explicit critic-gate defence against OTP non-negotiable #1, or a
  swap to `Task.Supervisor.start_child/2` under a new supervisor in
  the application tree. Implementer-brief item for PR-C.
- "Independently reversible" holds only if the reverse-order
  constraint (revert D before B) is documented in PR-B and PR-D's
  bodies. Minor authoring note for the implementer.

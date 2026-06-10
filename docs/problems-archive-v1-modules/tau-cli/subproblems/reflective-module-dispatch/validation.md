---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Static registry map replaces reflective tail clauses

## Overview

The solution proposes replacing the `Module.concat([..., String.capitalize(other)])`
tail clauses in `Tau.CLI.resolve_provider/1` and `Tau.CLI.resolve_coding_agent/1`
with compile-time `@provider_registry` / `@coding_agent_registry` maps, returning
`{:ok, module}` or `{:error, :unknown_*, name, known_list}` and deleting the
reflective fallback. This validation extracts six claims spanning AC satisfaction,
file scope, atom-leak elimination, decomplecting depth, single-source-of-truth,
and migration atomicity. The falsification strategies span dependency check,
edge-case enumeration, integration check, counter-example construction, type-level
check, and prior-art counter-case. Five claims withstood; **claim 3 (single-file
change) is partially falsified** — the same defective pattern exists in
`lib/mix/tasks/tau.hello.ex:74`, and the existing test
`test/tau/cli_coding_agent_flag_test.exs:55` will break and must be updated as part
of the same PR. Neither finding falsifies the acceptance criterion; both narrow
claim 3's qualifier in place. No solution or problem revision is triggered.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants found
it difficult to generate Toulmin structures, and their structures varied greatly
even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to counter
that variance.

### Claim 1: The acceptance criterion is fully satisfied — no atoms are created from arbitrary user strings, unknown values are rejected with a clear error, and the `String.capitalize/1` limitation is removed.

- **Claim (C):** "Proposal 2 is the only candidate that simultaneously satisfies
  all three acceptance-criterion requirements in a single PR" (solution.md
  "Why chosen"). Concretely: post-change, `resolve_provider/1` and
  `resolve_coding_agent/1` cannot atom-leak; unknown values produce
  `{:error, :unknown_*, name, known_list}` which callsites translate to a
  human-readable stderr message + `halt(1)`; the `String.capitalize/1` code
  path and its apologetic comment (lines 807–811) are deleted.
- **Grounds (G):** The post-change definitions sketched in
  `proposals/proposal-2.md:36–78` use `Map.fetch/2` against compile-time map
  attributes whose keys are literal strings and whose values are module
  literals. `Map.fetch/2` does not create atoms (it hashes the binary key
  against existing entries). No call to `Module.concat/1` or
  `String.to_atom/1` remains anywhere in the function bodies. The acceptance
  criterion in `problem.md:53–57` enumerates exactly these three
  requirements; each is structurally addressed by the sketch.
- **Warrant (W):** A function whose body is a closed-form map lookup over
  literal keys with no atom-producing call site cannot create atoms from its
  argument. This is the Elixir/Erlang atom-table contract: atoms enter the
  table only via the documented constructors (`String.to_atom/1`,
  `Module.concat/1`, `:erlang.binary_to_atom/2`, source/compile-time
  literals, etc.). Map lookup is not such a constructor.
- **Qualifier (Q):** Holds for all binary inputs to `resolve_provider/1` and
  `resolve_coding_agent/1` after the change lands, given the callsites are
  updated to handle the tagged-tuple return type. Does NOT extend to other
  resolution functions in the codebase (covered by claim 6's out-of-scope
  set).
- **Rebuttal (R):** A maintainer could partially apply the change — e.g.
  add the registries but leave the tail clause as a fallback — recreating
  the leak. The solution's "fully atomic" sequencing (`solution.md` migration
  sketch step 6 — "either both resolution functions are map-based with
  error-returning types, or neither is") addresses this through PR discipline,
  not code structure. The PR must be reviewed as a unit.
- **Backing (B):** Erlang/OTP atom-table semantics (Erlang Efficiency Guide
  §11.2, "Atoms are not garbage-collected"); the `.claude/rules/otp-non-negotiables.md`
  invariant against runtime-derived atoms; `Tau.CLI.Config.safe_to_atom/1`
  in this project (named in problem.md out-of-scope) which adopts
  `String.to_existing_atom/1` for the same reason.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check on the Elixir/Erlang primitive set used in
  the post-change body — does any one of them implicitly create atoms?
- **Attempt:** Enumerated the calls in the sketch:
  `Map.fetch/2`, `Map.keys/1`, function-clause head matching, module-literal
  returns (`Tau.Providers.Anthropic` etc.). Cross-checked each against
  HexDocs / Erlang docs: `Map.fetch/2` performs hash lookup against the
  existing key set with no atom-construction side effect;
  `Map.keys/1` returns the existing map's atom values (no construction);
  function-clause head matching does not construct atoms; module literals
  are interned at compile time. Verified no `Module.concat` / `String.to_atom` /
  `String.capitalize` remain in the sketched bodies.
- **Outcome:** withstood — no atom-creating primitive remains in the proposed
  bodies.
- **Action:** none.

### Claim 2: The registry map is the single source of truth for valid short names — dispatch and error enumeration both read from one inspectable data structure.

- **Claim (C):** "Proposal 2's `@provider_registry` attribute is the single
  source of truth for both dispatch and error enumeration, removing the
  dual-representation risk that Proposal 4 explicitly creates and accepts"
  (solution.md "Why chosen").
- **Grounds (G):** The sketch returns
  `{:error, :unknown_provider, name, Map.keys(@provider_registry)}` from the
  miss branch (`proposals/proposal-2.md:64`). The error-handling callsite
  consumes `known_list` directly (solution.md "What changes"); the list is
  not duplicated. Adding a new entry to the map is the only edit needed for
  it to appear in both dispatch and the error message.
- **Warrant (W):** Hickey's "complect" lens: data and code are decomplected
  when one is not derivable from the other. By making the map the source
  and `Map.keys/1` the projection used for both dispatch and error display,
  the closed set has exactly one representation; any drift between dispatch
  and enumeration becomes structurally impossible.
- **Qualifier (Q):** Holds while callsites use `Map.keys(@provider_registry)`
  (or pass through the `known_list` carried by the error tuple) rather than
  introducing a separately-maintained list in the error formatter.
- **Rebuttal (R):** A future maintainer adding a "short alias" only to the
  error message (e.g. "did you mean 'openai'?") would re-introduce a
  second representation. The shape of the change does not prevent this; only
  reviewer vigilance does.
- **Backing (B):** Rich Hickey, "Simple Made Easy" (Strange Loop 2011) —
  decomplecting closed-set representation from dispatch. ADR convention in
  this repo (per `docs/adr/`) of keeping protocol/dispatch tables as data,
  not as embedded code branches.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a post-change
  callsite shape that requires a second list to be maintained alongside
  the registry.
- **Attempt:** Considered (a) the `--help` enumeration of valid providers;
  (b) error stderr messages; (c) doctor-command provider iteration. In
  case (a), Optimus help text is generated from the option spec — if the
  option spec ever needs an enumerated `validator:` callback, it would
  use `Map.keys(@provider_registry)`, no second list. In (b), the error
  tuple carries `known_list` directly. In (c) (out-of-scope per
  `problem.md`), the doctor command currently iterates its own bespoke
  list. The proposed change does not extend to it; if a future PR
  consolidates, it would naturally use the registry.
- **Outcome:** withstood — no callsite within the proposed change scope
  requires a second representation.
- **Action:** none.

### Claim 3: The change is contained in a single file (`lib/tau/cli.ex`).

- **Claim (C):** "all changes are contained in this single file" (solution.md
  "What changes"). The migration sketch is "Single PR touching only
  `lib/tau/cli.ex`."
- **Grounds (G):** `grep -rn "resolve_provider\|resolve_coding_agent"` over
  `lib/` and `test/` shows: production callsites of `Tau.CLI.resolve_*` in
  `lib/tau/cli.ex` and only two external production sites —
  `lib/tau/session/data.ex:366` and `lib/tau/session/coding_agent_turn.ex:749`,
  both of which call only `Tau.CLI.resolve_coding_agent/1`. Two unrelated
  `resolve_provider/1` functions exist (`lib/tau/session/provider_turn.ex:35`
  and `lib/tau/session.ex:486`), but both already use
  `String.to_existing_atom/1` — they are not subject to the atom-leak and
  are correctly out of scope.
- **Warrant (W):** A change's file scope is the union of (a) the function
  bodies being modified, (b) every callsite whose contract is broken by
  the signature change, and (c) every test that asserts the old behaviour.
- **Qualifier (Q):** Holds for *production* code paths within the
  problem's scope. Does **not** hold once we expand the scope to include
  (i) the existing test at `test/tau/cli_coding_agent_flag_test.exs:53–56`
  which asserts the reflective fallback ("foo" → `Tau.CodingAgents.Foo`),
  and (ii) the duplicate `Module.concat([..., String.capitalize(other)])`
  pattern at `lib/mix/tasks/tau.hello.ex:74` in `Mix.Tasks.Tau.Hello`.
- **Rebuttal (R):** The test file is a legitimate part of the same PR by
  every convention in the repo (tests live with the change they enforce);
  the `mix/tasks/tau.hello.ex` site is a separate `defp resolve_provider/1`
  inside an unrelated Mix task and is explicitly outside the problem's
  scope (`problem.md` names only `Tau.CLI.resolve_provider/1` and
  `Tau.CLI.resolve_coding_agent/1`). Strictly, the "single file" claim is
  read as "of the two functions named in the problem, both live in
  `lib/tau/cli.ex`", which is true.
- **Backing (B):** `problem.md:14–24` explicitly scopes the problem to
  `Tau.CLI.resolve_provider/1` and `Tau.CLI.resolve_coding_agent/1`; the
  `spec-before-code.md` rule treats out-of-scope production sites as
  separate problems requiring their own issue/PR.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction — search the codebase for any
  file outside `lib/tau/cli.ex` that either depends on the existing return
  contract of `Tau.CLI.resolve_*` or duplicates the defective pattern.
- **Attempt:** Ran `grep -rn "resolve_provider\|resolve_coding_agent"` and
  `grep -rn "Module.concat.*String.capitalize"` across `lib/` and `test/`.
  Findings:
  1. `test/tau/cli_coding_agent_flag_test.exs:55` asserts
     `Tau.CLI.resolve_coding_agent("foo") == Tau.CodingAgents.Foo`. This
     test will FAIL after the change (return becomes
     `{:error, :unknown_coding_agent, "foo", ["claude_code", "claudecode", "replay"]}`).
     The test must be updated in the same PR.
  2. `lib/tau/session/data.ex:366` and `lib/tau/session/coding_agent_turn.ex:749`
     call `Tau.CLI.resolve_coding_agent(str)` and assign the result to a
     case-arm value. After the change, both will receive a tagged tuple
     instead of a module atom. These two callsites MUST be updated in the
     same PR to unwrap `{:ok, mod}` and decide what to do on `{:error, …}`.
     Neither is listed in `solution.md`'s "What changes" or
     "What does not change"; the open question in solution.md gestures at
     this risk but does not commit to fixing those sites.
  3. `lib/mix/tasks/tau.hello.ex:74` duplicates the defective pattern
     verbatim (`Module.concat(["Tau", "Providers", String.capitalize(other)])`)
     in a private `resolve_provider/1`. It is in a Mix task module, not
     `Tau.CLI`, and the problem scopes the work to `Tau.CLI` only. The
     defect remains in the codebase after this change.
- **Outcome:** partially falsified — the "single file" claim is true if
  read as "the two named functions live in one file"; it is false if
  read as "the PR touches only one file." At minimum the PR must edit
  `test/tau/cli_coding_agent_flag_test.exs` and update the two external
  callsites in `lib/tau/session/data.ex` and
  `lib/tau/session/coding_agent_turn.ex`. The narrowed claim:
- **Action:** Narrow the qualifier in place. The PR's actual file scope is
  `lib/tau/cli.ex` + `lib/tau/session/data.ex` + `lib/tau/session/coding_agent_turn.ex` +
  `test/tau/cli_coding_agent_flag_test.exs`. The `lib/mix/tasks/tau.hello.ex`
  duplicate is a follow-up issue (same defect class, out of this problem's
  scope per `problem.md:14`). The implementer brief MUST name the three
  additional files; an "Outstanding doubts" entry below tracks the
  hello-task duplicate.

### Claim 4: The change has Substantial decomplecting depth — the closed set becomes data.

- **Claim (C):** "Proposal 2 has Substantial decomplecting depth (the
  closed set becomes data)" (solution.md "Why chosen"); table row:
  Decomplecting depth = Substantial.
- **Grounds (G):** Pre-change, the closed set is encoded as the sequence
  of `defp resolve_provider("anthropic"), do: Tau.Providers.Anthropic`
  clauses at `lib/tau/cli.ex:792–805` and equivalent for coding agents at
  `:782–784`. The set is implicit in function-clause order; introspection
  requires reading source. Post-change, the set is `@provider_registry`
  and `@coding_agent_registry` — first-class data structures inspectable
  via `Map.keys/1`, `Map.values/1`, and usable in error messages,
  validators, and docstrings.
- **Warrant (W):** Hickey's decomplecting principle (Simple Made Easy):
  data is simpler than code that encodes the same information, because
  data composes under standard operators (here: `Map.keys`, `Map.values`,
  `Enum.sort`, `Enum.join`) without modifying its definition. Function-
  clause dispatch entangles "this is a known name" with "this is what
  the name resolves to" with "this is how dispatch fails," because
  enumerating the set requires reading function bodies.
- **Qualifier (Q):** Holds for the dispatch + enumeration pair; does not
  extend to richer reflection (e.g. fetching a behaviour module's
  `__info__/1` from the registry value), which neither the old nor new
  shape supports.
- **Rebuttal (R):** If the resolver ever needs to map a *runtime-derived*
  module to a short name (the inverse direction), the map shape requires
  `Map.new(@provider_registry, fn {k, v} -> {v, k} end)` or a second
  attribute. Proposal 1 (function clauses) has the same problem in
  inverse. Not a differential weakness.
- **Backing (B):** Rich Hickey, "Simple Made Easy" (Strange Loop 2011);
  this project's existing pattern in `lib/tau/tools/builtin/delegate.ex:118–119`
  which uses exactly this idiom (`%{"claude_code" => Tau.CodingAgents.ClaudeCode, "replay" => Tau.CodingAgents.Replay}`)
  as a module-level data registry for adapter lookup.

#### Falsification attempt for claim 4

- **Strategy:** Edge-case enumeration — list the kinds of consumer the
  closed-set might face, and check whether the data form serves each
  strictly better than the function-clause form.
- **Attempt:** Enumerated consumers: (a) dispatch; (b) error enumeration;
  (c) `--help` value-list rendering; (d) tests iterating over all known
  names; (e) docstring auto-generation; (f) telemetry tagging by short
  name. (a) is a tie; (b)–(f) require data. The function-clause form
  cannot serve (b)–(f) without `Tau.CLI.__info__(:functions)` introspection
  and re-deriving the closed set from clause heads — that itself is
  reflection over compile-time information and is fragile.
- **Outcome:** withstood — the data form dominates the function-clause
  form for every consumer except parity-tie dispatch.
- **Action:** none.

### Claim 5: The PR is atomic — either both functions are map-based with tagged-tuple returns, or neither is. No partial-landing intermediate state.

- **Claim (C):** "The PR is fully atomic: either both resolution functions
  are map-based with error-returning types, or neither is. No partial-
  landing state." (solution.md migration sketch.)
- **Grounds (G):** Both functions live in the same file and are modified
  in the same commit. Return-type changes are signature-level (every
  caller breaks at compile time if not updated). The atomicity is
  enforced by the BEAM compiler: a half-converted state cannot pass
  `mix compile --warnings-as-errors`.
- **Warrant (W):** When a signature change is detected by the compiler
  at every callsite, partial-landing is impossible without ignoring
  build errors, which the repo's CI gates (`lint` job:
  `mix compile --warnings-as-errors`) forbid.
- **Qualifier (Q):** Holds as long as CI's `--warnings-as-errors` gate
  is in force (which it is, per `.github/workflows/ci.yml`).
- **Rebuttal (R):** A developer running `mix compile` locally without
  `--warnings-as-errors` could ship a half-updated callsite as a warning,
  not an error. CI catches it before merge.
- **Backing (B):** `.github/workflows/ci.yml` `lint` job;
  `.claude/rules/factory-loop.md` gate-green requirement that
  CI pass before merge.

#### Falsification attempt for claim 5

- **Strategy:** Type-level check — reason about the dialyzer / compile
  warnings the change would produce. Identify any callsite that uses a
  permissive pattern (`_ = result`) that would silently accept the
  changed return.
- **Attempt:** Inspected the three known callsites:
  - `lib/tau/cli.ex:303`: `provider = resolve_provider(parsed.options[:provider])`
    — assigns to a variable and passes to subsequent functions expecting
    a module. Tagged-tuple return creates a compile-clean but
    runtime-failing path UNLESS the next consumer pattern-matches; in
    practice the variable is fed to `Tau.start_session/3` whose typespec
    expects an atom, so dialyzer (if enabled) flags it.
  - `lib/tau/cli.ex:764, 766`: `tui_put(opts, :provider, opts[:provider], &resolve_provider/1)`
    — the transformer's result is `Keyword.put`'d directly. A tagged
    tuple under `:provider` would not be a module atom; the TUI runtime
    would crash on first use.
  - `lib/tau/session/data.ex:366`, `lib/tau/session/coding_agent_turn.ex:749`:
    `str when is_binary(str) -> Tau.CLI.resolve_coding_agent(str)` —
    case-arm value; tagged tuple would propagate as the case result.
  All three sites need updating; none currently use `_ = result`, so
  the type change is visible at compile or test time, not silent.
- **Outcome:** withstood — the type change is visible (test failure or
  dialyzer warning) at every callsite; partial landing fails CI. Note:
  this strengthens claim 5 by relying on the *same* callsites that
  partially-falsify claim 3.
- **Action:** none for claim 5. The callsite list discovered here is
  the same one feeding claim 3's narrowed qualifier.

### Claim 6: Out-of-scope items (other `resolve_provider/1` functions, `transport_for/1`, `safe_to_atom/1`, `Init.provider_string/1`, doctor-cmd resolution) are correctly excluded — they do not have the atom-leak defect.

- **Claim (C):** "What does not change" lists `lib/tau/provider.ex`,
  all provider/coding-agent modules, `MCP.transport_for/1`,
  `Config.safe_to_atom/1`, `Init.provider_string/1`, and the
  `resolve_coding_agent/1` public API signature.
- **Grounds (G):**
  - `lib/tau/session/provider_turn.ex:38–44`: uses
    `String.to_existing_atom/1` inside try/rescue, returning
    `Tau.Provider.default()` on failure — no leak.
  - `lib/tau/session.ex:488–494`: same pattern, no leak.
  - `Tau.CLI.Config.safe_to_atom/1` — explicitly named in `problem.md`
    out-of-scope as "uses `String.to_existing_atom/1` — no atom leak;
    correct pattern".
  - `Tau.CLI.MCP.transport_for/1` — explicitly out of scope per
    `problem.md`: "string-vs-atom key probing (different function, no
    atom-leak concern)".
- **Warrant (W):** A function leaks atoms only if it calls a constructor
  that creates atoms from arbitrary binary input (`String.to_atom/1`,
  `Module.concat/1` over user-derived strings, `:erlang.binary_to_atom/2`).
  Functions using `String.to_existing_atom/1` or static
  `Module.concat/1` over compile-time literals do not leak.
- **Qualifier (Q):** Holds for the named functions today. Holds only as
  long as those functions are not modified to use atom-creating
  constructors in the future.
- **Rebuttal (R):** The duplicate at `lib/mix/tasks/tau.hello.ex:74`
  IS an additional atom-leak site (`Module.concat(["Tau", "Providers",
  String.capitalize(other)])`) that this solution does NOT address.
  It is genuinely out of scope per `problem.md` (which scopes only
  `Tau.CLI.*`), but the defect remains in the repo after the change.
  The "What does not change" list should mention it explicitly as
  "out of scope by problem boundary, not by absence of defect."
- **Backing (B):** `problem.md:60–67` explicit out-of-scope list;
  Erlang Efficiency Guide §11.2 atom-table semantics.

#### Falsification attempt for claim 6

- **Strategy:** Prior-art counter-case + grep — search the codebase
  for any other use of `Module.concat([..., String.capitalize(...)])`
  or similar atom-creating patterns over user input.
- **Attempt:** Ran `grep -rn "Module.concat.*String.capitalize" lib/`.
  Result: two hits — the in-scope `lib/tau/cli.ex` (the target),
  and `lib/mix/tasks/tau.hello.ex:74` (a Mix task duplicate). Also
  ran `grep -rn "String.to_atom\b" lib/`; only safe uses (DSL macro
  contexts, compile-time literals). Verified the named out-of-scope
  functions do not use these constructors.
- **Outcome:** withstood for the items the solution lists; partially
  reinforces claim 3's narrowing (the hello-task duplicate is real
  and unaddressed, but out of *this problem's* scope per `problem.md`).
- **Action:** Surface the hello-task duplicate as an outstanding doubt
  for the parent-level node to convert into a follow-up issue.

## Cross-claim consistency

Claims 1, 2, 4, 5, 6 are mutually consistent and reinforcing.

Claim 3 (single-file change) and claim 5 (atomic PR via compile-time
signature break) interact: the compile-time signature change that makes
claim 5 robust is precisely what forces the additional file edits that
narrow claim 3. The tension resolves cleanly — claim 5 is correctly
"atomic *given* the additional callsites are updated in the same PR,"
and claim 3's qualifier is narrowed in place to enumerate those callsites.

Claim 6 (out-of-scope correctness) and claim 3 (single-file) interact
weakly via the `lib/mix/tasks/tau.hello.ex:74` duplicate: the defect
class is the same, but the problem boundary correctly excludes it.
This is documented as an outstanding doubt for the parent node, not
a falsification of either claim.

No internal inconsistency requires escalation.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | AC fully satisfied | dependency check | withstood | none |
| 2 | Map is single source of truth | counter-example construction | withstood | none |
| 3 | Single-file change | counter-example construction | partially falsified | narrow qualifier; PR scope includes 3 extra files |
| 4 | Substantial decomplecting depth | edge-case enumeration | withstood | none |
| 5 | Atomic PR | type-level check | withstood | none |
| 6 | Out-of-scope items correct | prior-art counter-case | withstood | hello-task duplicate noted as outstanding |

## Revision required

None. Claim 3's narrowed qualifier is documented in place; the implementer
brief derived from this solution MUST name the additional files
(`lib/tau/session/data.ex`, `lib/tau/session/coding_agent_turn.ex`,
`test/tau/cli_coding_agent_flag_test.exs`) as in-scope for the same PR.
No solution or problem revision is triggered.

- **Target file:** n/a — no revision required.
- **Revision kind:** n/a.
- **Rationale:** All partial falsifications are absorbed by qualifier
  narrowing without changing the chosen approach or the acceptance
  criterion. The chosen solution still satisfies the AC.

## Outstanding doubts

- **Hello-task duplicate.** `lib/mix/tasks/tau.hello.ex:74` has the same
  `Module.concat([..., String.capitalize(other)])` defect. It is out of
  scope for this problem (which scopes only `Tau.CLI.*`) but the defect
  class is identical. The parent-level node should convert this into a
  follow-up issue/sub-problem so the codebase-wide cleanup is tracked.
- **Existing test "unknown name fallback" semantics.**
  `test/tau/cli_coding_agent_flag_test.exs:53–56` documents the current
  reflective fallback as a *feature* ("unknown short name falls back to
  Tau.CodingAgents.<X> shape"). The solution deletes that feature
  intentionally. The implementer must update the test to assert the
  new tagged-tuple `{:error, :unknown_coding_agent, …}` return instead.
  This is a behaviour change visible to any external user who was
  relying on the documented fallback; the PR description should call
  it out, even though no in-tree caller depends on it.
- **Default-provider nil return type.** Current
  `resolve_provider(nil), do: Tau.Provider.default()` returns a bare
  module; the sketch changes it to `{:ok, Tau.Provider.default()}`.
  Symmetry with the binary clause is correct, but every nil-default
  callsite (e.g. `lib/tau/cli.ex:303`) must unwrap the same way. This
  is captured by claim 5's type-level check but is worth re-stating
  for the implementer.

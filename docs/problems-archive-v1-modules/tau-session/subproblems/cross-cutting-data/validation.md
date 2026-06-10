---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/6
revision_triggered: none
---

# Validation: Typed accessors + full 101-head struct-match sweep

## Overview

The revised solution makes six checkable propositions: (1) add three typed
accessor functions to `Tau.Session.Data`; (2) eliminate four named
defensive-read / dynamic-key call sites; (3) sweep every `data`-bearing
function head across the nine session sub-modules (101 in total, per a
per-file inventory) to `%Tau.Session.Data{} = data`; (4) the test suite
needs no changes because no test invokes the touched functions via bare-map
arguments; (5) public arities and `@spec`s do not change; (6) the
migration is mechanical and reversible (four conceptual commits, no PLT
rebuild). The validation strategy is dependency-check + counter-example
construction for the load-bearing factual claims (per-file head counts,
named line citations, absence of `alias`, absence of bare-map test calls);
edge-case enumeration for the AC-coverage claim. Five of six claims
withstand; claim 6 is partially falsified by an arithmetic off-by-one in
the migration sketch (101 − 3 heads covered in commit 2, not 101 − 4) —
the narrowing is local and does not require solution or problem revision.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: Add three typed accessor functions `get_queue/2`, `put_queue/3`, `replace_field/3` to `Tau.Session.Data`

- **Claim (C):** "Adopt Proposal 2's typed accessor functions
  (`get_queue/2`, `put_queue/3`, `replace_field/3`) on `Tau.Session.Data`"
  (solution.md §Recommendation, §A).
- **Grounds (G):** `Tau.Session.Data` is a real module with an existing
  `defstruct` and `@type t :: %__MODULE__{}` (verified at
  `lib/tau/session/data.ex:20` (`@enforce_keys`), `:41` (`@type t`), `:96`
  (`defstruct`)). Adding three module-level functions with `@spec` is a
  standard, low-cost extension. The two-clause shape of `get_queue/2` /
  `put_queue/3` mirrors the only two queue tiers actually accessed
  (`:steering` / `:followup`) at the only caller, `queue.ex:43, 63`
  (verified by direct read).
- **Warrant (W):** OTP non-negotiable #2 ("Extensibility seams MUST be
  behaviours; pattern match on atoms and structs"). A struct-owning module
  is the right home for its own typed accessors; this localises the
  field-shape contract to one module rather than leaving it implicit at
  every call site.
- **Qualifier (Q):** Universal within the stated scope (the three
  accessor functions, on the existing `Data` struct, called from the four
  named sites in §B). Does NOT extend to nested-map accessors (e.g. into
  `data.tool_loop_state`, `data.tools_in_flight`, `data.metadata`,
  `data.coding_agent_state`) — those are explicitly out of scope.
- **Rebuttal (R):** Would not hold if `Data` did not already have a
  `defstruct`; the problem.md statement asserts no `defstruct` exists,
  but inspection shows one does (`lib/tau/session/data.ex:96`). The
  problem.md framing is partially obsolete on this point — the solution
  correctly works from current code state.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` §2; the
  existing `Tau.Session.Meta` precedent (cited in problem.md as a
  comparable in-module struct contract).

#### Falsification attempt for claim 1

- **Strategy:** Dependency check — verify the modules and shapes the
  accessors depend on actually exist.
- **Attempt:** Ran `grep -nE "defstruct|@enforce_keys|@type t "
  lib/tau/session/data.ex`: results at lines 20, 41, 96 confirm `Data`
  already has the full struct shape. Verified §B citations exist
  (`queue.ex:43` shows `Map.get(data, queue_field)`, `:63` shows
  `Map.put(data, queue_field, new_queue)` — both match the solution's
  text verbatim).
- **Outcome:** withstood. The accessors land in a real, struct-bearing
  module against real callers.
- **Action:** none.

### Claim 2: Replace four named defensive-read / dynamic-key call sites

- **Claim (C):** Four edits — `queue.ex:43, 63` → typed queue accessors;
  `provider_turn.ex:179` → `replace_field/3`; `provider_turn.ex:337` →
  `data.persona_lifetime` direct access; `model_swap.ex:94` →
  `replace_field/3` (solution.md §B).
- **Grounds (G):** All four line citations verified by direct read:
  - `queue.ex:43`: `queue = Map.get(data, queue_field)`.
  - `queue.ex:63`: `new_data = Map.put(data, queue_field, new_queue)`.
  - `provider_turn.ex:179`: `def maybe_replace(data, key, value), do:
    Map.put(data, key, value)`.
  - `provider_turn.ex:337`: `if msg.stop_reason == :end_turn and
    Map.get(data, :persona_lifetime, :turn) == :turn do`.
  - `model_swap.ex:94`: `def maybe_replace(data, key, value), do:
    Map.put(data, key, value)` (verbatim parity with `provider_turn.ex:179`).
- **Warrant (W):** Hickey decomplecting principle as cited in the
  problem's complecting hypothesis: defensive `Map.get(..., default)`
  reads exist only because the shape is not statically enforced; once
  the struct match holds at the head, the default becomes dead defence
  and obscures real intent.
- **Qualifier (Q):** Holds for the four cited sites; the solution
  explicitly excludes nested-map reads via `data.<sub>` (e.g. into
  `tool_loop_state`, `tools_in_flight`, `metadata`,
  `coding_agent_state`), which inspection at `coding_agent_turn.ex:112,
  504`, `tool_dispatch.ex:79, 501, 869`, `slash_command.ex:359`
  confirms are still `Map.get(...)` reads and remain so by design.
- **Rebuttal (R):** Would not hold if any of the four lines named a
  function head whose body already destructures the field in a way the
  edit would break. Verified by reading the surrounding context: each
  edit substitutes one expression for an equivalent one, with no body
  invariant disturbed.
- **Backing (B):** ADR-0012 / ADR-0013 / ADR-0015 (referenced in the
  `provider_turn.ex:337` neighbourhood) constrain the surrounding
  control flow, not the persona_lifetime read itself; the read's
  default of `:turn` matches the struct's documented default, so direct
  field access is semantically identical.

#### Falsification attempt for claim 2

- **Strategy:** Counter-example construction — try to construct a
  runtime state where each of the four edits changes behaviour.
- **Attempt:**
  - `queue.ex` accessors: `Data.new/1` populates both
    `steering_queue` and `followup_queue` at init (per problem.md context
    line 33–34: "the struct that `Data.new/1` fully populates"); no code
    path nils them; therefore `Map.get` and a struct-field access return
    the same value.
  - `provider_turn.ex:179` / `model_swap.ex:94` `maybe_replace/3`: both
    are identical one-liners; replacing `Map.put` with
    `Data.replace_field/3` (which wraps `struct!/2`) changes only the
    failure mode for an unknown key (`struct!/2` raises `KeyError`
    instead of silently widening the struct shape with a stray atom
    key). Stricter failure is the desired outcome (fast-fail at the
    boundary, as the solution acknowledges in §Migration sketch).
  - `provider_turn.ex:337`: `data.persona_lifetime` has default
    `:turn` per the struct (the `Map.get` default matches); behaviour
    is identical for the struct case.
- **Outcome:** withstood. No counter-example found within current code
  shape.
- **Action:** none.

### Claim 3: The per-file head inventory of 101 `data`-bearing function heads is accurate

- **Claim (C):** "Per-file head inventory (verified by `grep -cE
  '^\s*defp?\s+\w+\(.*\bdata\b'`): tool_dispatch.ex 16,
  coding_agent_turn.ex 22, provider_turn.ex 20, model_swap.ex 11,
  compaction.ex 7, queue.ex 7, slash_command.ex 6, skill_activation.ex 6,
  journal.ex 6, total 101" (solution.md §C).
- **Grounds (G):** Re-ran the exact regex against each file:
  - `tool_dispatch.ex: 16`
  - `coding_agent_turn.ex: 22`
  - `provider_turn.ex: 20`
  - `model_swap.ex: 11`
  - `compaction.ex: 7`
  - `queue.ex: 7`
  - `slash_command.ex: 6`
  - `skill_activation.ex: 6`
  - `journal.ex: 6`
  - Sum: 16+22+20+11+7+7+6+6+6 = **101**.
  Every per-file count matches the table to the integer.
- **Warrant (W):** A grep with a fixed regex is deterministic over a
  fixed file set; reproducing the same query on the same files yields
  the same count.
- **Qualifier (Q):** Holds at HEAD (`main` at `origin/main` as of this
  validation). A later commit that adds or removes a `data`-bearing
  head invalidates the table — but the solution will be implemented
  before that drift accumulates, and the grep is fast to re-run.
- **Rebuttal (R):** The regex `^\s*defp?\s+\w+\(.*\bdata\b` matches any
  head where `data` appears as a *word* anywhere after the opening
  paren. A head with `metadata` (containing the substring `data`) and
  no `data` parameter could in principle match; `\b` excludes that
  (`\bdata\b` requires word boundaries on both sides). A head with
  `data` as a non-first parameter would still match — which is the
  correct semantics (any head receiving `data` should be swept). No
  false positive identified.
- **Backing (B):** Standard POSIX ERE semantics; `git grep` /`grep -E`
  documented determinism.

#### Falsification attempt for claim 3

- **Strategy:** Dependency check — re-execute the cited grep and
  compare to the published table, entry by entry.
- **Attempt:** Executed `for f in tool_dispatch coding_agent_turn
  provider_turn model_swap compaction queue slash_command
  skill_activation journal; do count=$(grep -cE
  '^\s*defp?\s+\w+\(.*\bdata\b' lib/tau/session/$f.ex); echo "$f.ex:
  $count"; done`. Output matched the published per-file table on every
  line. Also verified the five widened-map line citations
  (`coding_agent_turn.ex:42, 46, 383`, `provider_turn.ex:97, 777`) by
  direct `sed -n` read: every cited line is a `def` or `defp` head with
  a bare-map destructure of `data`, exactly as the solution describes.
- **Outcome:** withstood. Per-file counts match to the integer; total
  is 101.
- **Action:** none.

### Claim 4: No `alias Tau.Session.Data` exists in any of the nine sub-modules today

- **Claim (C):** "each sub-module gains `alias Tau.Session.Data` at the
  top (currently absent across all nine files; verified by `grep -nE
  "alias\b.*Data" lib/tau/session/*.ex` returning zero matches)"
  (solution.md §C).
- **Grounds (G):** Re-ran `grep -nE "alias\b.*Data" lib/tau/session/*.ex`:
  zero matches. The eight sub-modules (plus `data.ex` itself, which
  needs no alias to its own type) all currently reference `data` only
  as a parameter name; none alias the module.
- **Warrant (W):** A `grep` over a closed file set returning zero
  matches is direct evidence of absence; for this narrow proposition
  no further inference is required.
- **Qualifier (Q):** Holds at HEAD. Adding an `alias` to any one of
  the nine files between this validation and the implementing PR would
  not invalidate the solution — the §C migration commits the alias
  edits with idempotent intent; the grep would then return one match
  instead of zero, which is the post-migration steady state.
- **Rebuttal (R):** The regex `alias\b.*Data` is permissive — it would
  match `alias Foo.Bar.Data`, `alias Data`, `alias Tau.Session.Data`,
  etc. Zero matches against this permissive regex is therefore strong
  evidence; a more restrictive regex would only further confirm.
- **Backing (B):** Standard `grep -E` semantics.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check — re-execute the cited grep.
- **Attempt:** Ran `grep -nE "alias\b.*Data" lib/tau/session/*.ex`:
  empty output (zero matches).
- **Outcome:** withstood.
- **Action:** none.

### Claim 5: No test in `test/` invokes the touched functions with a bare-map argument; therefore no test changes are required

- **Claim (C):** "A grep over `test/` for bare-map calls into the
  modified functions (`grep -rnE
  "(enqueue|maybe_replace|dispatch_tools|finish_permission_round|run_tool|handle_tool_done)\(%\{"
  test/`) returns zero matches; tests use real `Data.new/1`-built
  structs throughout" (solution.md §What does not change).
- **Grounds (G):** Re-ran the exact grep: zero matches.
- **Warrant (W):** Adding `%Tau.Session.Data{} = data` to a function
  head changes the matching set only if a caller passes a value that is
  not a `Tau.Session.Data` struct. If no test invokes the function with
  a bare map literal, no test is broken by the tightened head pattern.
- **Qualifier (Q):** Holds for the named function set. Does NOT prove
  that other tests don't pass *plain maps built by other means* (e.g. a
  test helper that returns a map). The grep is necessary but not fully
  sufficient — see Rebuttal.
- **Rebuttal (R):** A test that constructs `data` via a helper function
  returning `map()` rather than `%Tau.Session.Data{}` (e.g.
  `build_test_data()` returning a plain map) would not be caught by the
  literal `%{` grep. The solution acknowledges this gap implicitly by
  citing the grep as the test of choice; a broader audit of test/
  helpers is the residual doubt.
- **Backing (B):** Convention in this repo's test suite, evidenced by
  `Tau.Session.Meta` being constructed via real structs throughout
  (Validator Claim 5 in the prior revision's history; the residual
  doubt was carried forward into this revision's §What does not change).

#### Falsification attempt for claim 5

- **Strategy:** Counter-example construction — search for test helpers
  that might return a non-struct map for the `data` argument.
- **Attempt:** Ran the cited grep over `test/`: zero matches. (A wider
  audit of `test/support/` for helper functions returning a non-struct
  `data` map was not exhaustively performed within this validation; the
  solution treats this as residual doubt rather than a closed
  question.)
- **Outcome:** withstood for the cited grep; the residual doubt about
  non-literal test-helper construction remains and is noted in
  Outstanding doubts below.
- **Action:** none for solution; flagged in Outstanding doubts for the
  parent validator's awareness.

### Claim 6: The migration sketch's commit decomposition is accurate (four commits; commit 4 covers 97 heads = 101 − 4)

- **Claim (C):** "Full head sweep (§C). Add `%Data{} = data` to the
  remaining 97 heads (101 total − 4 already covered in commit 2)
  across the nine files" (solution.md §Migration sketch step 4).
- **Grounds (G):** Commit 2 names four edits (per solution §B):
  `queue.ex:enqueue/4`, `provider_turn.ex:179`, `provider_turn.ex:337`,
  `model_swap.ex:94`. Inspection shows three of these are function
  heads: `queue.ex:enqueue/4` (head; widened-map style at the existing
  `enqueue/4` head), `provider_turn.ex:179` (head of `maybe_replace/3`),
  `model_swap.ex:94` (head of `maybe_replace/3`). The fourth,
  `provider_turn.ex:337`, is a *body* expression inside a larger
  function (the `if msg.stop_reason == :end_turn and Map.get(data,
  :persona_lifetime, :turn) == :turn do` clause); it does not add a
  struct match to a head.
- **Warrant (W):** Arithmetic on a closed set: the head-sweep total of
  101 is established (Claim 3); commit 2 covers exactly the heads that
  contain the §B edits; a non-head edit does not advance the head
  sweep.
- **Qualifier (Q):** The 101 figure stands. The arithmetic "101 − 4 =
  97 heads in commit 4" is off by one: only 3 of the §B edits are
  head-level. Commit 4 therefore covers **98** heads, not 97.
- **Rebuttal (R):** One could interpret commit 2 as "implicitly adding
  the struct match to *the head containing* the `provider_turn.ex:337`
  body edit as well" — but the §B text does not promise that, and
  doing so would expand commit 2 beyond its stated four-line scope.
  The conservative reading is the arithmetic, not the intent, is off.
- **Backing (B):** Direct line read at `provider_turn.ex:337` shows an
  `if` clause inside a function body (indent level matches an interior
  block, not a head).

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction — locate any commit-2 edit
  whose line is not at function-head depth.
- **Attempt:** Read line 337 of `provider_turn.ex`: it is an interior
  `if` expression inside a larger function body. Therefore commit 2
  covers 3 (not 4) heads; commit 4 must cover 98 (not 97).
- **Outcome:** partially_falsified. The 101-head total is correct
  (Claim 3); the migration-sketch sub-arithmetic is off by one. The
  solution's substantive content (sweep all 101 heads) is unaffected
  — the off-by-one is in the breakdown across commits 2 and 4. The
  Qualifier narrows the claim from "97 in commit 4" to "98 in commit
  4" (or, equivalently, "97 plus the one head whose body §B touches at
  line 337"); no body of the solution changes.
- **Action:** Narrow the Qualifier in place. Note for the implementer:
  treat commit 4 as covering all heads not already head-matched in
  commit 2 (3 heads), i.e. 98 heads. No revision of solution.md or
  problem.md is required; the implementer's commit-4 line-count
  estimate will match reality if they compute it as 101 minus
  whatever commit 2 head-matched, rather than copying "97" from the
  prose.

## Cross-claim consistency

Claims 1–5 are mutually consistent: claim 1 introduces the accessors;
claim 2 wires them into four call sites; claim 3 establishes the head
inventory; claim 4 establishes the alias absence (which §C migration
step 3 will repair); claim 5 establishes that no test rework is
needed. Claim 6 is the only inconsistency — its arithmetic does not
match the substance of claims 2 and 3 — and the resolution narrows
claim 6's Qualifier rather than disturbing the others.

A second cross-cutting observation: problem.md asserts "no `defstruct`
or `@type t :: %Tau.Session.Data{}`" (lines 21–22), but
`lib/tau/session/data.ex` already has both (`:20, :41, :96`). The
solution correctly works from the present code state and meets the AC
("`Tau.Session.Data` exports a `defstruct` with `@enforce_keys` for
every required field and an `@type t :: %__MODULE__{}` spec; `Data.new/1`
returns `{:ok, %Tau.Session.Data{}}` ...") trivially — the AC's first
three clauses are *already* satisfied; clause (d) ("all sub-modules
pattern-match on `%Tau.Session.Data{}` in their function heads") is the
only outstanding work and is the focus of this revision. This is not a
contradiction in the solution; it is a staleness in problem.md's Context
section that does not require revision (problem.md's AC remains the
correct target; the Context prose merely undercounts what is already
done). Flagged in Outstanding doubts.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---------------|----------|---------|--------|
| 1 | Add `get_queue/2`, `put_queue/3`, `replace_field/3` to `Data` | dependency check | withstood | none |
| 2 | Four defensive-read / dynamic-key edits at named sites | counter-example construction | withstood | none |
| 3 | Per-file head inventory totals 101 | dependency check (grep re-run) | withstood | none |
| 4 | No `alias Tau.Session.Data` exists in nine sub-modules | dependency check (grep re-run) | withstood | none |
| 5 | No test invokes touched functions with bare-map args | counter-example construction | withstood (residual doubt on helper-built maps) | flag in Outstanding doubts |
| 6 | Commit 4 covers 97 heads (= 101 − 4 in commit 2) | counter-example construction | partially falsified — should be 98 | narrow Qualifier in place; note for implementer |

## Revision required

None. Claim 6's partial falsification is a documentation off-by-one in
the migration sketch's sub-arithmetic; it does not invalidate the
solution's substantive scope (sweep all 101 heads), does not change any
recommendation, and does not require re-running propose/select.

- **Target file:** n/a
- **Revision kind:** n/a (narrowed Qualifier recorded here)
- **Rationale:** The off-by-one is local to a commit-decomposition
  sentence; the implementer can compute the residual head count
  directly from the per-file table (Claim 3) without consulting the
  off-by-one prose. Triggering a full solution revision for a
  one-integer arithmetic note would be disproportionate; the
  partial-falsification log here is the correct response per validate.md
  §5 ("Partially falsified → narrow Qualifier in place; no revision
  needed").

## Outstanding doubts

- **Test-helper-built maps.** The grep in Claim 5 covers literal `%{`
  call sites only; it does not exhaustively rule out test helpers that
  return a non-struct `data` map (e.g. a `build_data/0` helper in
  `test/support/`). An implementer should re-run `mix test` after the
  head sweep and treat any `FunctionClauseError` failure as a
  test-helper that needs to be ported to `Tau.Session.Data.new/1`. The
  failure would be loud and local, not silent.
- **problem.md Context staleness.** Problem.md lines 21–22 claim "no
  `defstruct` or `@type t :: %Tau.Session.Data{}`", but
  `lib/tau/session/data.ex` already has both at lines 20, 41, 96. The
  AC clauses (a)/(b)/(c) are therefore already met; only clause (d) is
  outstanding (and is the focus of this solution). The discrepancy
  does not change the AC or the work scope; it does affect how a
  reader sizes the change. A future amendment to problem.md to mark
  clauses (a)–(c) as "already satisfied at HEAD" would be accurate but
  is not required for the solution to land.
- **`replace_field/3` audibility.** Carried over from solution Open
  Questions: `replace_field/3` accepts `atom()` for `key`; Dialyzer
  cannot verify at the call site that `key` names a valid struct
  field. The "single auditable escape hatch" property (one function to
  grep for `replace_field`) is the intended trade-off, not a bug. The
  parent validator should note this as a known weakness inherited from
  this sub-tree.

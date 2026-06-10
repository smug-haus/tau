---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-2.md]
selection_method: hybrid
revision: 1
---

# Solution: Typed accessors on Data + full struct-match expansion across every sub-module head touching session data

## Recommendation

Adopt Proposal 2's typed accessor functions (`get_queue/2`, `put_queue/3`,
`replace_field/3`) on `Tau.Session.Data` and Proposal 1's surgical callsite
fixes (`persona_lifetime` dot-access; `model_swap.ex:maybe_replace/3` parity
with `provider_turn.ex`). Combine these with the work the prior revision
disclaimed: add `%Tau.Session.Data{} = data` to EVERY public-and-private
function head that names `data` as a parameter across the nine session
sub-modules — 101 heads in total — so that AC clause (d) ("all sub-modules
pattern-match on `%Tau.Session.Data{}` in their function heads") holds by
inspection on a single grep. The expansion is mechanical: each head's
existing `data` parameter is rewritten as `%Tau.Session.Data{} = data`,
with the four heads that already destructure via a bare map pattern
(`%{field: ...} = data`) widened to `%Tau.Session.Data{field: ...} = data`.
No body changes, no API changes, no new modules.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-2.md` (accessor functions) and
  `proposals/proposal-1.md` (direct callsite fixes), with scope expanded
  beyond what either proposal stated to include a full struct-match sweep of
  every `data`-bearing function head across `lib/tau/session/*.ex`.
- **Why chosen:** Proposal 2 owns the field-access contract from `Data`
  itself (deepest decomplecting at low cost). Proposal 1 contributes the
  surgical fixes for `persona_lifetime` and for the `model_swap.ex`/
  `provider_turn.ex` `maybe_replace/3` duplication. Proposal 3 (sub-structs)
  was rejected on migration cost, irreversibility, and atomic-PR conflict
  with sibling sub-problems. Proposal 4 (behaviour + validator) was rejected
  as disproportionate to the AC and in tension with OTP non-negotiables §2.
  The prior revision selected the same proposals but added the struct-match
  to only two heads (`enqueue/4`, `provider_turn.maybe_replace/3`) and
  explicitly disclaimed the rest — falsifying AC clause (d). This revision
  closes that gap by committing to the full sweep, with the per-file head
  inventory below.

### Scoring table

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|--------------------:|:--------------:|:----:|:-------------:|
| 1 | Yes | Surface             | Low            | Low  | Easy          |
| 2 | Yes | Substantial         | Low-Medium     | Low  | Easy          |
| 3 | Yes | Deep                | High           | Medium | Hard        |
| 4 | Partially | Surface      | Low            | Low  | Easy          |

Proposal 2 is rescored at Low-Medium cost (versus the prior revision's Low)
to reflect the full-head sweep this revision commits to: ~105 head edits
across nine files rather than two. The work remains mechanical and
reversible; it is not High-cost.

## What changes

### A. New accessor functions in `lib/tau/session/data.ex` (additions)

- `get_queue/2 :: (t(), :steering | :followup) -> :queue.queue()` — two
  pattern-matched clauses on `%__MODULE__{}` destructuring the queue field.
- `put_queue/3 :: (t(), :steering | :followup, :queue.queue()) -> t()` —
  two pattern-matched clauses producing struct-updated `t()`.
- `replace_field/3 :: (t(), atom(), term()) -> t()` — wraps `struct!/2`;
  documented as the single auditable escape hatch for dynamic-key updates.

### B. Defensive-read / dynamic-key elimination (3 fixes)

- `lib/tau/session/queue.ex:43, 63` — replace `Map.get(data, queue_field)`
  / `Map.put(data, queue_field, new_queue)` with
  `Tau.Session.Data.get_queue(data, tier)` /
  `Tau.Session.Data.put_queue(data, tier, new_queue)`.
- `lib/tau/session/provider_turn.ex:179` — replace
  `Map.put(data, key, value)` with
  `Tau.Session.Data.replace_field(data, key, value)`.
- `lib/tau/session/provider_turn.ex:337` — replace
  `Map.get(data, :persona_lifetime, :turn)` with `data.persona_lifetime`.
- `lib/tau/session/model_swap.ex:94` — replace
  `Map.put(data, key, value)` with
  `Tau.Session.Data.replace_field(data, key, value)` (parity with
  `provider_turn.ex:179`; closes Validator Claim 4's partial falsification).

### C. Full struct-match sweep across every sub-module function head taking `data`

Add `%Tau.Session.Data{} = data` to every `def` / `defp` head that names
`data` as a parameter. Where a head currently destructures `data` via a
bare map pattern (`def f(%{field: x} = data, ...)`), widen to the struct
form (`def f(%Tau.Session.Data{field: x} = data, ...)`).

Per-file head inventory (verified by
`grep -cE '^\s*defp?\s+\w+\(.*\bdata\b'`):

| File | Heads taking `data` | Notes |
|------|--------------------:|-------|
| `lib/tau/session/tool_dispatch.ex` | 16 | All currently bare `data` |
| `lib/tau/session/coding_agent_turn.ex` | 22 | 3 use `%{...} = data` (lines 42, 46, 383) → widen to `%Tau.Session.Data{...} = data` |
| `lib/tau/session/provider_turn.ex` | 20 | 2 use `%{...} = data` (lines 97, 777) → widen |
| `lib/tau/session/model_swap.ex` | 11 | All bare |
| `lib/tau/session/compaction.ex` | 7 | All bare |
| `lib/tau/session/queue.ex` | 7 | All bare; includes `enqueue/4` from §B |
| `lib/tau/session/slash_command.ex` | 6 | All bare |
| `lib/tau/session/skill_activation.ex` | 6 | All bare |
| `lib/tau/session/journal.ex` | 6 | All bare |
| **Total** | **101** | 5 of which are widened-map (not bare-add) edits |

For convenience, each sub-module gains `alias Tau.Session.Data` at the top
(currently absent across all nine files; verified by
`grep -nE "alias\b.*Data" lib/tau/session/*.ex` returning zero matches)
so the head edits read `%Data{} = data` rather than the fully-qualified
`%Tau.Session.Data{} = data`. The alias is purely cosmetic; it does not
affect the structural guarantee.

## What does not change

- `Tau.Session.Data` struct fields, `@enforce_keys`, `@type t`, defaults —
  no field added, removed, renamed, or re-defaulted.
- `Data.new/1` signature and return type (`{:ok, %Tau.Session.Data{}}`).
- Public arities and `@spec` of every modified sub-module function
  (`enqueue/4`, `maybe_replace/3` in both `provider_turn.ex` and
  `model_swap.ex`, and the 101 swept heads).
- `Tau.Session.Meta` (already a typed struct; out of scope per problem.md).
- `lib/tau/session.ex` itself (the FSM module, not a sub-module per the
  problem statement's "sub-modules" framing; out of scope).
- Nested-map reads (e.g.
  `Map.get(data.tool_loop_state, key)`,
  `Map.get(data.tools_in_flight, call_id)`,
  `Map.get(data.coding_agent_state, :session_id)`,
  `Map.get(data.metadata, key)`) — these read into sub-maps, not into
  the `Data` struct itself; explicitly out of scope per
  `problem.md` "Out of scope".
- All tests — no test changes required. A grep over `test/` for bare-map
  calls into the modified functions (`grep -rnE
  "(enqueue|maybe_replace|dispatch_tools|finish_permission_round|run_tool|
  handle_tool_done)\(%\{" test/`) returns zero matches; tests use real
  `Data.new/1`-built structs throughout (this addresses Validator Claim 5's
  residual-doubt note as it applies to the expanded scope).

## Migration sketch

Single PR, four conceptual commits to keep review manageable:

1. **Add accessors to `data.ex`.** New `get_queue/2`, `put_queue/3`,
   `replace_field/3` with `@spec`s. Compiles cleanly with no callers yet.
2. **Defensive-fix sweep.** Update `queue.ex:enqueue/4`,
   `provider_turn.ex:179, 337`, and `model_swap.ex:94` to use the new
   accessors / dot-access (§B). Includes the struct-match on those four
   heads.
3. **Add `alias Tau.Session.Data` to the eight sub-modules that don't yet
   have it.** Mechanical; touches imports only.
4. **Full head sweep (§C).** Add `%Data{} = data` to the remaining
   97 heads (101 total − 4 already covered in commit 2) across the nine
   files. This commit is large in line-count (≈97 single-line edits) but
   trivial in semantic content; the reviewer reads it as a single
   mechanical transformation.

After the PR: `mix compile --warnings-as-errors` is unaffected (no
warnings are introduced by adding a struct match to a parameter — the
match either succeeds or surfaces a real bug). `mix dialyzer` gains
tighter type information at every call site because every entry point now
asserts the struct shape; this may surface latent bugs in callers that
pass non-struct maps, which is the desired outcome (fast-fail at the
boundary). No PLT rebuild is required.

## Open questions

- `replace_field/3` accepts `atom()` for `key`; Dialyzer cannot verify at
  the call site that `key` names a valid struct field. The "auditable
  escape hatch" property (one function to grep) is the intended trade.
  Documented in Open Questions of the prior revision; carried forward.
- The full-head sweep (§C) creates a uniform `%Data{} = data` head shape
  across the codebase. If a future refactor extracts a sub-struct (as
  Proposal 3 would have done), every swept head becomes a re-edit site —
  the cost of decomplecting now is paid again then. This is a known
  trade and is acceptable: the sub-struct refactor is not in scope for
  this sub-problem and is the natural successor node if revisited.
- Heads in sub-modules that do not currently name `data` (because they
  take a different argument shape) are unaffected. AC clause (d) speaks of
  "function heads touching session data"; a head that does not receive
  `data` does not touch it. The 101-head figure is therefore the
  exhaustive scope.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — "Remove remaining defensive reads; keep
  existing struct as-is": contributes the `persona_lifetime` dot-access fix
  and motivates the `model_swap.ex` parity fix.
- `proposals/proposal-2.md` — "Introduce typed accessor functions in Data":
  primary shape; contributes `get_queue`/`put_queue`/`replace_field`.
- `proposals/proposal-3.md` — "Split Data into typed sub-structs by concern
  cluster": rejected on migration cost, risk, and atomic-PR conflict with
  sibling sub-problems; remains the natural successor if revisited.
- `proposals/proposal-4.md` — "Add a Data behaviour with a typed contract
  callback": rejected as disproportionate to the AC and in tension with
  OTP non-negotiables §2 (behaviours are for extensibility seams, not
  construction guards).

## Revision history

- (revision 0 — initial) hybrid of proposals 1 + 2; added struct-match to
  only two heads; falsified by validator on AC clause (d).
- (revision 1 — current) scope expanded to commit to the full 101-head
  struct-match sweep across nine sub-modules, with per-file inventory.
  Adds `model_swap.ex:maybe_replace/3` parity fix to close Validator
  Claim 4's partial falsification. Adds `alias Tau.Session.Data` to the
  eight sub-modules currently without it, purely to keep head syntax
  compact. No body logic changes; no test changes.

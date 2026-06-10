---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: default_for_mode/3 encodes a second tool allow-list separate from the rule-set

## Statement

`Tau.Permissions.Evaluator.default_for_mode/3` contains hard-coded tool
allow-lists for `:plan`, `:auto`, and `:accept_edits` modes
(e.g. `["Read", "Grep", "Glob", "Agent"]` for `:plan`). This is a second
allow-list that is structurally independent of the rule-set evaluated just
above it in `evaluate/5`; the two lists can diverge silently when a tool
is added to one but not the other. The `"Agent"` entries in `:plan` and `:auto`
were added with inline comments citing the rationale (ADR-0014/0015), but
there is no property test asserting that the mode-dispatch fallback cannot
produce a result more permissive than the mode's stated policy (e.g. `:plan`
should never yield `:allow` for a non-read tool except `"Agent"`).

## Context

- `lib/tau/permissions/evaluator.ex`, `default_for_mode/3`, lines 91–119:
  - `:plan` allows `["Read", "Grep", "Glob", "Agent"]`; denies everything else.
  - `:auto` allows `["Read", "Grep", "Glob", "Agent"]`; asks everything else.
  - `:accept_edits` allows `["Read", "Write", "Edit", "Grep"]`; for `"Bash"`,
    delegates to `Heuristics.destructive_bash?/1`; everything else is `:ask`
    (unknown tools fall through to the `default_for_mode(_, _, _)` catch-all
    which returns `:ask`).
- The `evaluate/5` function evaluates the rule-set first (deny → allow → ask),
  then falls through to `default_for_mode/3` only on no match. The two layers
  are logically sequential but the tool allow-lists in `default_for_mode/3`
  are not derivable from the rule-set; they are a separate static policy.
- `test/tau/permissions/evaluator_test.exs`: examples cover the `:auto`/`Agent`
  case (lines 117–128) but there is no property asserting that for all tools
  NOT in the `:plan` allow-list, `:plan` mode always yields `:deny` when no
  allow rule matches.
- `SPEC-PERMISSION-PROMPTS.md` §D-090..D-099 names the evaluator as
  in-scope; no D-NNN invariant currently pins the `default_for_mode` contract.

## Complecting hypothesis

`default_for_mode/3` is complected with rule-set precedence because it
implements a secondary static allow-list for `:plan`/`:auto`/`:accept_edits`
modes that partially duplicates what a rule-set entry would express — but is
evaluated after the rule-set is exhausted, creating an implicit priority order
(rule-set deny > skill gate > bypass > rule-set allow/ask > mode default)
that is not stated as a property or spec invariant.

The `:accept_edits` heuristic path is complected with the mode-dispatch logic
because `Heuristics.destructive_bash?/1` is invoked from inside
`default_for_mode/3` rather than at the rule-set boundary, making the
`:accept_edits` + `"Bash"` path a structural exception to the
"rule-set first, mode last" contract.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

At least one property test asserts that for all tools outside the stated
allow-set for each non-default mode (`:plan`, `:dont_ask`), the evaluator
with an empty rule-set yields `:deny`; and the tool allow-lists in
`default_for_mode/3` are documented (inline or in a moduledoc addendum) with
the explicit invariant they enforce and a reference to ADR-0014/ADR-0015, so
a reader can verify them without searching commit history.

## Out of scope

- Matcher unit tests — covered by `matcher-unit-contracts`.
- Mode-lattice peer-rank properties — covered by `mode-lattice-properties`.
- `Settings.Loader.merge/2` — covered by `settings-merge-feed`.
- `Tau.Permissions.RuleSet` GenServer lifecycle — out of scope for this audit
  (declared in root `problem.md`).

## Amendment log

- (none yet)

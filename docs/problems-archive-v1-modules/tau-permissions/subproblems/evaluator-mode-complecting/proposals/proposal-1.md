---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Document and property-test the existing default_for_mode/3 contract in-place

## Approach

Leave `default_for_mode/3` structurally unchanged. Add a `@moduledoc` addendum
(or a dedicated `## Mode defaults` section within the existing moduledoc) that
states the allow-set for each non-default mode as a named invariant, cites
ADR-0014 and ADR-0015 inline, and explains why `"Agent"` is exempt from
read-only enforcement. Add property tests to `evaluator_test.exs` using
`StreamData` that, for each mode, generate arbitrary tool names outside the
stated allow-set and assert the empty-rule-set result equals the mode's
specified default outcome (`:deny` for `:plan`/`:dont_ask`, `:ask` for
`:auto`/`:accept_edits` non-Bash, `:allow` for `:bypass`).

## Rationale

The complecting hypothesis states the problem is that the secondary allow-list
is *undocumented* and lacks a property asserting its invariant — not that the
list is in the wrong place. A reader already following the code would need to
check commit history or ADRs to understand why `"Agent"` is in the `:plan`
allow-set. Surfacing the invariant as documented contract (moduledoc) + verified
property (StreamData) decomplects the *knowledge* without moving the *code*.
The implicit priority order (rule-set deny > skill gate > bypass > rule-set
allow/ask > mode default) becomes explicit in the module's narrative. The
`:accept_edits` + Bash heuristic exception is documented as an inline structural
note, not buried in an ADR.

## Sketch

Moduledoc addendum in `evaluator.ex`:

```elixir
@moduledoc """
  ...existing text...

  ## Mode defaults (evaluated only when no rule-set entry matches)

  These are *secondary* policy entries. They are evaluated after the
  full rule-set (deny → allow → ask) is exhausted. They MUST NOT be
  confused with rule-set entries — they are not expressed as rules and
  are not reachable by the rule-set scan.

  | mode           | default outcome  | allow-set                              | basis      |
  |----------------|-----------------|----------------------------------------|------------|
  | `:default`     | `:ask`          | (none — always asks)                   | —          |
  | `:plan`        | `:deny`         | `["Read","Grep","Glob","Agent"]`        | ADR-0014   |
  | `:auto`        | `:ask`          | `["Read","Grep","Glob","Agent"]`        | ADR-0015   |
  | `:accept_edits`| `:ask`          | `["Read","Write","Edit","Grep"]`        | ADR-0015   |
  | `:dont_ask`    | `:deny`         | (none — always denies on no match)     | —          |
  | `:bypass`      | `:allow`        | (all — evaluated before mode default)  | —          |

  `"Agent"` appears in the `:plan` and `:auto` allow-sets because it is
  dispatch infrastructure, not a content tool. Denying it kills sub-agent
  delegation entirely; the read-only constraint propagates into child
  sessions via `Tau.Permissions.Mode.clamp/2`. See ADR-0014, ADR-0015.

  The `:accept_edits` + `"Bash"` path is a deliberate structural exception:
  `Heuristics.destructive_bash?/1` is invoked here rather than at the
  rule-set boundary because the heuristic's semantics are mode-scoped
  (what is "destructive" under `:accept_edits` may be safe under `:bypass`).
"""
```

Property tests in `evaluator_test.exs`:

```elixir
describe "mode default invariants (properties)" do
  use ExUnitProperties

  # Tools NOT in the :plan allow-set must always yield :deny with an empty rule-set.
  property ":plan denies tools outside its allow-set" do
    plan_allowed = MapSet.new(["Read", "Grep", "Glob", "Agent"])

    check all tool <- string(:alphanumeric, min_length: 1),
              tool not in plan_allowed do
      assert Evaluator.evaluate({}, tool, %{}, %{}, :plan) == :deny
    end
  end

  # Tools NOT already auto-allowed under :dont_ask must default to :deny.
  property ":dont_ask denies all tools with empty rule-set" do
    check all tool <- string(:alphanumeric, min_length: 1) do
      assert Evaluator.evaluate({}, tool, %{}, %{}, :dont_ask) == :deny
    end
  end

  # Tools outside the explicit allow-set under :auto must never yield :allow
  # without a rule-set entry.
  property ":auto yields :ask (not :allow) for tools outside its allow-set" do
    auto_allowed = MapSet.new(["Read", "Grep", "Glob", "Agent"])

    check all tool <- string(:alphanumeric, min_length: 1),
              tool not in auto_allowed do
      result = Evaluator.evaluate({}, tool, %{}, %{}, :auto)
      assert result in [:ask, :deny]
      refute result == :allow
    end
  end
end
```

## Tradeoffs

### Strengths

- Zero structural change to evaluator logic; no regression surface.
- Acceptance criterion is fully met: the property tests assert the named
  invariants for `:plan` and `:dont_ask`; the moduledoc documents the
  allow-sets with ADR references.
- Cheapest migration: one PR, no other modules touched, no API change.
- Property tests are understandable by any future contributor without
  knowledge of the decomplecting rationale.

### Weaknesses

- Does not address the structural complecting: `default_for_mode/3` still
  encodes a secondary allow-list orthogonal to the rule-set. A future
  contributor adding a new mode can reproduce the same undocumented pattern.
- Documentation only survives as long as the moduledoc is kept current;
  it is not machine-checkable (the table can drift from the code).
- The `:accept_edits` + Bash heuristic exception is documented but still
  structurally embedded inside `default_for_mode/3`, not at the rule-set
  boundary; the explanation that it is "mode-scoped" may not satisfy
  future reviewers.
- Does not pin a D-NNN invariant in `SPEC-PERMISSION-PROMPTS.md`; a
  spec-coverage gap remains even if the acceptance criterion is met.

### Costs

- ~30 lines of new moduledoc prose.
- ~25 lines of StreamData property tests.
- No module boundary changes; no consumer updates required.
- No build-dependency additions beyond `stream_data` (already a dev dep).

## Dependencies

- `stream_data` must be available as a test dependency (it already is in this
  project per `mix.exs`).
- No other modules need to change first.

## Confidence

Medium. The approach is straightforward and low-risk; confidence would rise to
high if a prototype property run confirmed StreamData generates tool names
outside the allow-sets as expected (the `not in` guard in `check all` is
correct but non-obvious).

## Prior art / references

- StreamData `check all ... when` guard pattern: ExUnit documentation for
  `ExUnitProperties` with filter predicates.
- ADR-0014 and ADR-0015 in `docs/adr/` (the cited rationale sources).
- Existing `mode_test.exs` property tests in this repo (same pattern,
  same test file structure).

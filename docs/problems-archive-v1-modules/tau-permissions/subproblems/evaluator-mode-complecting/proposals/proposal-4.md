---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Pin the default_for_mode/3 contract as a D-NNN invariant in SPEC-PERMISSION-PROMPTS.md and add a property in the existing evaluator_test.exs

## Approach

Author a new D-NNN invariant entry in `SPEC-PERMISSION-PROMPTS.md` (within the
D-090..D-099 block) that formally states the `default_for_mode/3` contract as
a *named spec invariant*: its priority (evaluated only after rule-set
exhaustion), the allow-set for each mode, the Bash heuristic exception for
`:accept_edits`, and the `"Agent"` exemption rationale (citing ADR-0014/0015).
Add a single property test in `evaluator_test.exs` that mechanically verifies
the invariant for `:plan` and `:dont_ask` (the two deny-defaulting modes) using
StreamData. Leave `evaluator.ex` code unchanged. The D-NNN entry then becomes
the machine-checkable constraint referenced by future PRs under the
`spec-before-code.md` rule.

## Rationale

The problem statement notes that "no D-NNN invariant currently pins the
`default_for_mode` contract." The acceptance criterion asks for documentation
with ADR references and at least one property test. Proposal 1 meets the
acceptance criterion through moduledoc prose; this proposal meets it through the
SPEC's formal invariant system instead. The distinction matters: a moduledoc can
drift silently from the spec; a D-NNN entry is the authoritative spec contract
and is gated by `critic` and `reviewer` on every future PR touching this module.
The spec amendment creates a durable machine-readable anchor that future
`spec-before-code.md`-gated PRs must conform to. This proposal targets the
spec-coverage gap as the primary concern, treating the property test as its
verifier, not as the primary deliverable.

## Sketch

New D-NNN entry in `SPEC-PERMISSION-PROMPTS.md` (append to §3 / D-090..D-099
block; use next available number, e.g. D-098 if free):

```markdown
**D-098 — Evaluator mode-default contract**

`Tau.Permissions.Evaluator.default_for_mode/3` is the fallback path reached
only when no rule-set entry (deny, allow, or ask) matches the `(tool_name,
args, ctx)` triple. It MUST implement the following policy table, which is
evaluated strictly after the rule-set scan and strictly before any `:ask`
fall-through:

| mode           | allow-set                              | default outcome | bash override               |
|----------------|----------------------------------------|-----------------|-----------------------------|
| `:default`     | (none)                                 | `:ask`          | —                           |
| `:plan`        | `["Read","Grep","Glob","Agent"]`        | `:deny`         | —                           |
| `:auto`        | `["Read","Grep","Glob","Agent"]`        | `:ask`          | —                           |
| `:accept_edits`| `["Read","Write","Edit","Grep"]`        | `:ask`          | `Heuristics.destructive_bash?/1` → `:deny`/`:allow` |
| `:dont_ask`    | (none)                                 | `:deny`         | —                           |
| `:bypass`      | (handled before default_for_mode; unreachable) | — | —            |

`"Agent"` is in the `:plan` and `:auto` allow-sets because it is dispatch
infrastructure, not a content tool (ADR-0014, ADR-0015). Denying it kills
sub-agent delegation; the read-only constraint propagates into child sessions
via `Tau.Permissions.Mode.clamp/2`.

The `:accept_edits` + `"Bash"` path is a structural exception: the heuristic
is invoked from inside `default_for_mode/3` rather than at the rule-set
boundary. This is intentional — the heuristic's semantics are mode-scoped
and do not apply in `:bypass` or `:plan` context.

**Enforcement:** `test/tau/permissions/evaluator_test.exs` MUST contain a
StreamData property asserting that for all tool names outside the `:plan`
allow-set, `Evaluator.evaluate({}, tool, %{}, %{}, :plan) == :deny` with an
empty rule-set; and analogously for `:dont_ask`.
```

Property tests added to `evaluator_test.exs` (note: targeted narrowly at the
two modes with `:deny` defaults, matching the acceptance criterion's exact
wording):

```elixir
describe "D-098 invariant: mode-default deny contract (properties)" do
  use ExUnitProperties

  @plan_allowed MapSet.new(["Read", "Grep", "Glob", "Agent"])

  property "D-098a: :plan denies tools outside allow-set with empty rule-set" do
    check all tool <- string(:alphanumeric, min_length: 1),
              tool not in @plan_allowed do
      assert Evaluator.evaluate({}, tool, %{}, %{}, :plan) == :deny,
             "Expected :deny for #{inspect(tool)} under :plan with no rules"
    end
  end

  property "D-098b: :dont_ask denies all tools with empty rule-set" do
    check all tool <- string(:alphanumeric, min_length: 1) do
      assert Evaluator.evaluate({}, tool, %{}, %{}, :dont_ask) == :deny,
             "Expected :deny for #{inspect(tool)} under :dont_ask with no rules"
    end
  end
end
```

## Tradeoffs

### Strengths

- The D-NNN invariant is the canonical, spec-gated form of documentation for
  this subsystem — more authoritative than a moduledoc that can drift.
- Future PRs touching `evaluator.ex` must cite D-098 per `spec-before-code.md`
  rules; the invariant becomes a hard gate, not advisory prose.
- Minimal code change: two properties in the existing test file; no production
  code touched.
- Satisfies the acceptance criterion directly and precisely.
- The invariant table format (ADR references, Bash override column) makes the
  structural exception explicit without requiring readers to search ADR history.

### Weaknesses

- Does not remove the structural complecting — `default_for_mode/3` remains a
  secondary allow-list evaluated outside the rule-set scan; it merely
  documents and property-tests what is already there.
- Relies on the `spec-before-code.md` gate being enforced consistently;
  if a future PR bypasses the gate, the D-NNN entry has no compile-time
  enforcement.
- Adding a D-NNN entry to an already-dense D-090..D-099 block may require
  verifying that D-098 is free across the whole repo before use
  (per CLAUDE.md namespace invariant).
- Narrower property coverage than Proposals 1 or 2: only covers `:plan` and
  `:dont_ask` (the two deny-defaulting modes), not `:auto`'s "never allows
  outside allow-set" invariant. The acceptance criterion is satisfied, but
  coverage is not maximised.

### Costs

- `SPEC-PERMISSION-PROMPTS.md`: ~30 lines added to §3.
- `evaluator_test.exs`: ~20 lines of StreamData properties.
- No production code changes.
- D-NNN namespace check required before filing the PR (grep the repo for
  D-098 to confirm it is free).

## Dependencies

- Verify D-098 (or next available D-NNN) is free:
  `git log --all --grep=D-098 && grep -rn D-098 lib test docs .claude`.
- No upstream module or behaviour changes required.

## Confidence

High. The spec-amendment pattern is well-established in this project
(`spec-before-code.md` defines it); the property tests are trivial StreamData
exercises; no production code is changed; the only risk is the D-NNN namespace
collision check.

## Prior art / references

- `SPEC-PERMISSION-PROMPTS.md` §D-090..D-097: existing D-NNN entries in the
  same file, same format.
- `CLAUDE.md` Hard Rules: "Before authoring a new D-NNN, verify the identifier
  is free across the whole repo."
- ADR-0014, ADR-0015 (cited in the D-098 prose).
- `test/tau/permissions/mode_test.exs`: existing StreamData property tests in
  this subsystem (same pattern).

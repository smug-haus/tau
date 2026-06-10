---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Compile mode defaults into the rule-set at RuleSet.get/0 so default_for_mode/3 is eliminated

## Approach

Modify `Tau.Permissions.RuleSet` to inject the mode-default allow-list entries
as rule-set triples when it compiles rules, so that `default_for_mode/3` in
`Evaluator` becomes unreachable dead code for non-default modes and can be
reduced to a trivial two-clause function (`:dont_ask` → `:deny`;
`_` → `:ask`). The per-mode allow-set entries are expressed as `{:allow,
Tau.Permissions.Matchers.Always, compiled_always_rule}` triples tagged with a
`:mode_default` annotation, injected by the rule-set for the active mode. The
evaluator's rule-set scan then picks them up through its normal
`match_any/5 → :allow` path, and the secondary allow-list ceases to exist as
a separate code path. Property tests are added at the `RuleSet` level asserting
that for each non-default mode, the emitted triples cover exactly the stated
allow-set tools and no others.

## Rationale

The root complecting is that the evaluator has *two separate mechanisms* for
producing `:allow`: the rule-set scan and `default_for_mode/3`. These two
mechanisms share no structural coupling — a tool can be in one and not the
other. Folding the mode defaults into the rule-set eliminates the second
mechanism; `evaluate/5`'s `cond` becomes a single-pass rule-set walk, which is
its stated contract in the moduledoc. The `:accept_edits` Bash heuristic becomes
a mode-default rule with a `Heuristics` matcher rather than a structural branch
in `default_for_mode/3`. The priority order (rule-set deny > skill gate >
bypass > rule-set allow/ask > mode default) collapses to (rule-set deny > skill
gate > bypass > rule-set allow/ask) — mode defaults are now *in* the rule-set
at the right priority tier.

## Sketch

`lib/tau/permissions/rule_set.ex` — extend `get/0` (or add `get/1`) to accept
a mode and inject mode-default triples:

```elixir
@type mode_default_triple :: {:allow | :deny | :ask, module(), term()}

# New: @mode_defaults table — maps mode → list of {tool, :allow/:deny/:ask}
@mode_defaults %{
  plan: [
    {"Read", :allow}, {"Grep", :allow}, {"Glob", :allow}, {"Agent", :allow}
    # All other tools → no entry added (fall-through to :ask / :deny handled by
    # the trailing mode-catch-all triple below)
  ],
  auto: [
    {"Read", :allow}, {"Grep", :allow}, {"Glob", :allow}, {"Agent", :allow}
  ],
  accept_edits: [
    {"Read", :allow}, {"Write", :allow}, {"Edit", :allow}, {"Grep", :allow},
    {"Bash", :heuristic}   # special marker — resolved below
  ]
}

@spec mode_default_triples(atom()) :: [mode_default_triple()]
def mode_default_triples(:dont_ask),
  do: [{:deny, Tau.Permissions.Matchers.Always, :any}]

def mode_default_triples(mode) do
  entries = Map.get(@mode_defaults, mode, [])

  Enum.flat_map(entries, fn
    {tool, :heuristic} ->
      # Accept-edits Bash: inject two rules — deny if destructive, allow otherwise
      destructive_rule = {:deny, Tau.Permissions.Matchers.BashDestructive, tool}
      safe_rule        = {:allow, Tau.Permissions.Matchers.Always, {:only, tool}}
      [destructive_rule, safe_rule]

    {tool, decision} ->
      [{decision, Tau.Permissions.Matchers.Always, {:only, tool}}]
  end)
end
```

`Tau.Permissions.Matchers.Always` gains a `{:only, tool}` compiled form:

```elixir
# Already exists: match?(nil, _tool, _args, _ctx) → true
# New clause:
def match?({:only, tool}, tool, _args, _ctx), do: true
def match?({:only, _}, _, _, _), do: false
```

`evaluator.ex` — the `cond` in `evaluate/5` stays unchanged in structure; the
caller is responsible for passing the mode-default triples appended to the
rule-set:

```elixir
def evaluate(rule_set, tool_name, args, ctx, mode \\ :default) do
  # Append mode-default triples at lower priority than user rule-set entries
  rules = Tuple.to_list(rule_set) ++ Tau.Permissions.RuleSet.mode_default_triples(mode)

  cond do
    match_any(rules, :deny, tool_name, args, ctx)  -> :deny
    skill_blocked?(ctx, tool_name)                 -> :deny
    mode == :bypass                                -> :allow
    match_any(rules, :allow, tool_name, args, ctx) -> :allow
    match_any(rules, :ask, tool_name, args, ctx)   -> :ask
    true                                           -> :ask  # only :default reaches here
  end
end
```

`default_for_mode/3` is deleted; the two remaining atoms (`:dont_ask` → `:deny`
via the always-deny triple; everything else → `:ask` via fall-through) are
now handled by the rule-set scan.

Property tests (against `RuleSet.mode_default_triples/1`):

```elixir
property ":plan mode_default_triples yields :allow only for its stated allow-set" do
  plan_allowed = MapSet.new(["Read", "Grep", "Glob", "Agent"])
  triples = RuleSet.mode_default_triples(:plan)

  check all tool <- string(:alphanumeric, min_length: 1) do
    matched = Enum.find(triples, fn {_, mod, rule} -> mod.match?(rule, tool, %{}, %{}) end)
    if tool in plan_allowed do
      assert matched != nil
      assert elem(matched, 0) == :allow
    else
      assert matched == nil
    end
  end
end
```

## Tradeoffs

### Strengths

- Eliminates the second allow-list as a distinct code path; `evaluate/5`
  becomes a pure single-pass rule-set walk as its moduledoc claims.
- Mode defaults are now testable via the same rule-set matcher machinery used
  for user rules; no novel test infrastructure needed.
- The `:accept_edits` Bash heuristic becomes a named matcher pair
  (`BashDestructive`, `Always{:only, "Bash"}`), not a structural exception.
- Priority order is now structurally self-documenting: mode defaults are
  appended *after* user rules in the list, so their lower priority is encoded
  in position, not in a prose comment.

### Weaknesses

- `Tau.Permissions.Matchers.Always` gains a new compiled form `{:only, tool}`;
  this extends a previously zero-argument module and may surprise readers
  expecting `Always` to be unconditional.
- Requires a new `BashDestructive` matcher module (or extending an existing
  matcher) to handle the `:accept_edits` Bash heuristic as a rule-set entry;
  introduces a new public module for what was 2 lines of `defp`.
- The `rule_set` passed into `evaluate/5` still does not include mode defaults
  at its source (`RuleSet.get/0`); they are appended inside `evaluate/5`.
  This means `RuleSet.get/0` and `evaluate/5` are still coupled by an implicit
  contract about who injects mode defaults.
- API-breaking if any caller constructs a tuple rule-set and passes it to
  `evaluate/5` expecting `default_for_mode/3` to remain active — the results
  change when mode-default triples are now appended.
- More code moved/added than in proposals 1 or 2 for the same acceptance-
  criterion outcome; risk surface is higher.

### Costs

- New file: `lib/tau/permissions/rule_set.ex` additions (~40 lines).
- Possibly new file: `lib/tau/permissions/matchers/bash_destructive.ex` (~15 lines).
- `evaluator.ex`: remove 6 `defp` clauses, modify `evaluate/5` (~net 0 lines).
- `Matchers.Always`: add `{:only, tool}` clause (~4 lines).
- Tests: ~30 lines of properties against `mode_default_triples/1`.
- Any caller that mocked `default_for_mode/3` behaviour through rule-set
  manipulation needs re-examination.

## Dependencies

- `Tau.Permissions.Matchers.Always` must be extended first (or in same PR).
- The `BashDestructive` matcher (or equivalent) must land before `:accept_edits`
  tests pass.

## Confidence

Low-medium. The direction is sound (merge the two allow-list paths), but the
`{:only, tool}` extension to `Always` and the `BashDestructive` matcher design
introduce non-trivial surface. Confidence would rise with a working prototype
that passes existing `EvaluatorTest` examples unchanged.

## Prior art / references

- Plug pipeline's `plug :action` ordering: middleware inserted at compile-time
  at a known priority tier; same structural pattern.
- `Ecto.Query` composability: building a query by appending clauses at known
  priority positions rather than branching in a resolver function.
- ADR-0014, ADR-0015 (the policies being codified as rule-set entries).

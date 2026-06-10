---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Custom Credo check + spec guard — enforce struct discipline mechanically without touching callsites yet

## Approach

Write a custom `Credo.Check` (e.g., `Tau.Credo.Check.NoModelMapGet`) that fails
`mix credo --strict` whenever `Map.get/2`, `Map.get/3`, or `Map.put/3` is called
with a variable whose type annotation in the same function's `@spec` is `Model.t()`
or a bare `map()` in any file under `lib/tau/tui/app/`. Additionally, add a
`mix compile --warnings-as-errors` guard by annotating every consumer function
with the correct `@spec` (changing `map()` to `Model.t()`) so Dialyzer
progressively surfaces mismatches. The callsite replacements are then done
incrementally, driven by CI failures rather than by a single large PR.

## Rationale

The problem has two distinct layers: (a) missing `@spec` type discipline (consumer
functions accept and return `map()` instead of `Model.t()`), and (b) incorrect
access pattern (`Map.get/3` instead of `model.field`). Fixing (a) first gives
Dialyzer the information it needs to flag (b) automatically. The custom Credo
check makes (b) a hard CI failure for any new code immediately, without requiring
that all existing violations be corrected in the same PR. This is an incremental,
mechanical-enforcement-first approach: add the fence before fixing what is already
inside the fence.

## Sketch

**New file**: `lib/tau/credo/check/no_model_map_get.ex`

```elixir
defmodule Tau.Credo.Check.NoModelMapGet do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    tags: [:tau_struct_discipline],
    explanations: [
      check: """
      Do not call Map.get/2-3 or Map.put/3 on a value typed as Model.t().
      Use struct field access (model.field) and struct update syntax (%{model | field: val}).
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
  end

  # Detect Map.get(model, :field, ...) where the enclosing function
  # spec types model as map() or Model.t() — flag Map.get as suspect.
  # Conservative: flag any Map.get/put call in lib/tau/tui/app/**/*.ex.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Map]}, :get]}, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [format_issue(issue_meta, message: "Use struct access instead of Map.get", line_no: meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _), do: {ast, issues}
end
```

**`.credo.exs` addition** (under `checks: %{enabled: [...]}`):

```elixir
{Tau.Credo.Check.NoModelMapGet, files: %{included: ["lib/tau/tui/app/**/*.ex"]}}
```

**`@spec` annotation pass** (one PR, no callsite changes):

```elixir
# events.ex: change two specs
@spec update(Model.t(), term()) :: Model.t()
@spec update_session_event(Model.t(), term()) :: Model.t()

# view.ex
@spec status_bar_model(Model.t()) :: map()
@spec build_prompt_labels(Model.t()) :: [term()]

# keymap.ex
@spec handle_event(Model.t(), map()) :: Model.t()
@spec handle_event_normal(Model.t(), map()) :: Model.t()

# permission.ex
@spec on_permission_request(Model.t(), map()) :: Model.t()
```

**No callsite changes in this PR.** The CI check is scoped to new code only via
`--since git:main` (Credo supports this); existing violations are surfaced as
warnings, not errors, until they are corrected in subsequent PRs. The Credo check
and `@spec` annotation PR gates the approach; callsite cleanup PRs follow.

## Tradeoffs

### Strengths

- Prevents regression: any new `Map.get/3` on a `Model.t()` value fails CI
  immediately, even before the existing violations are fully cleaned up.
- Decouples the enforcement-introduction PR from the cleanup PRs; each cleanup
  PR is a small, focused diff (e.g., "fix events.ex violations only").
- The custom Credo check is reusable for any future struct whose consumers
  exhibit the same pattern.
- `@spec` annotation pass is zero-risk (no runtime changes) and immediately
  improves Dialyzer coverage.
- Incremental time horizon: the team can ship the guard first and address
  violations across multiple milestones without the all-or-nothing pressure of
  a single large refactor PR.

### Weaknesses

- Does not itself fix the acceptance criterion: `Map.get/3` calls remain until
  the subsequent cleanup PRs land. The acceptance criterion is only fully
  satisfied at the end of the incremental sequence, not at merge of this PR.
- The custom Credo AST check is a heuristic: it flags all `Map.get` calls in the
  targeted file glob, including any that legitimately operate on `map()` values
  that are not `Model.t()`. False positives require per-site `# credo:disable`
  annotations (which are themselves a code smell marker — acceptable but noisy).
- Writing and maintaining a custom Credo check requires familiarity with the
  Credo AST traversal API; the sketch above is simplified and may miss edge cases
  (e.g., `Map.get` called via a local alias).
- The Credo check does not help Dialyzer; the two mechanisms are orthogonal.
  Dialyzer still needs the `@spec` changes to flag callsite type mismatches.

### Costs

- Write `lib/tau/credo/check/no_model_map_get.ex` (~60 lines).
- Write a Credo check unit test (~20–30 lines).
- Update `.credo.exs` (2–3 lines).
- Write the `@spec` annotation pass (one PR, ~12–16 spec changes, no callsite
  changes).
- Each subsequent cleanup PR is small (one file, ~5–10 callsite edits) but there
  are 5 of them — total edit count similar to Proposal 1, spread across more PRs.

## Dependencies

- Credo >= 1.7 (already a project dependency per `mix.exs`).
- A working `mix dialyzer` baseline so that the `@spec` annotation PR does not
  introduce new Dialyzer warnings without resolving them.

## Confidence

Medium. The enforcement-first pattern is a legitimate engineering approach and
the Credo AST API is documented. Confidence would be raised by verifying that
the targeted glob (`lib/tau/tui/app/**/*.ex`) does not produce excessive false
positives on the current codebase (i.e., that non-`Model.t()` `Map.get` calls
in those files are rare or absent).

## Prior art / references

- Credo custom check documentation: https://hexdocs.pm/credo/writing_checks.html
- `mix credo --since git:main` — Credo's diff-scoped mode for blocking only new
  violations.
- Gradual type enforcement pattern — described in the Gradualizer/Dialyzer
  ecosystem as "add specs first, fix callsites incrementally".

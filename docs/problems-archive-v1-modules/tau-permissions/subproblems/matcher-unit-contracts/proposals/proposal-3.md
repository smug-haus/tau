---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Purify PathPrefix (replace File.cwd! with ctx-driven default) + property tests

## Approach

Change `PathPrefix.match?/4` in `lib/tau/permissions/matchers.ex` to
require `ctx[:cwd]` and return `false` (fail-closed) when it is absent,
eliminating the `File.cwd!/0` side-effect. Add
`test/tau/permissions/matchers_test.exs` with StreamData property tests
for all five matchers (same scope as Proposal 2), plus an explicit
property asserting the new behaviour: "absent `ctx[:cwd]` → `false`
for any input." The moduledoc `@note` is replaced with a doc that states
the now-pure contract.

## Rationale

The problem statement identifies `PathPrefix.match?/4` as complected
with process environment: calling `File.cwd!/0` makes a nominally-pure
function non-deterministic. Replacing the fallback with fail-closed
`false` decomplects the function from OS state, restores referential
transparency, and makes the contract testable as a pure property.
Combined with a direct property suite, this satisfies the acceptance
criterion at its strictest reading ("replaced with a ctx-driven default")
rather than its documentation-only escape hatch.

## Sketch

Change in `lib/tau/permissions/matchers.ex`, `PathPrefix.match?/4`:

```elixir
# BEFORE
def match?({tool, prefix}, tool_name, args, ctx) do
  if tool == "*" or tool == tool_name do
    path = args["path"] || ""
    cwd = ctx[:cwd] || File.cwd!()          # <── impure fallback
    full = Path.expand(path, cwd)
    String.starts_with?(full, Path.expand(prefix, cwd))
  else
    false
  end
end

# AFTER
def match?({tool, prefix}, tool_name, args, ctx) do
  if tool == "*" or tool == tool_name do
    case ctx[:cwd] do
      nil ->
        false                                # <── fail-closed; no OS call
      cwd ->
        path = args["path"] || ""
        full = Path.expand(path, cwd)
        String.starts_with?(full, Path.expand(prefix, cwd))
    end
  else
    false
  end
end
```

Updated moduledoc:

```elixir
defmodule Tau.Permissions.Matchers.PathPrefix do
  @moduledoc """
  Matches when the tool argument's path is under the given prefix.

  `ctx[:cwd]` MUST be supplied; when absent, `match?/4` returns `false`
  (fail-closed). This makes the function pure and its contract testable
  without OS state.
  """
```

New property in `test/tau/permissions/matchers_test.exs`:

```elixir
property "PathPrefix: absent ctx[:cwd] always returns false" do
  check all tool   <- StreamData.member_of(["Read", "Write", "*"]),
            prefix <- StreamData.string(:alphanumeric),
            path   <- StreamData.string(:alphanumeric) do
    refute PathPrefix.match?({tool, prefix}, tool, %{"path" => path}, %{})
  end
end
```

All other tests identical to Proposal 2.

## Tradeoffs

### Strengths

- Eliminates the only impure function in the matcher subsystem;
  `match?/4` on all five matchers is now a total pure function.
- The contract becomes testable as a StreamData property without needing
  OS fixtures or `:meck` stubbing.
- Fail-closed on `ctx[:cwd]` absence is the safer permission default:
  a missing context does not silently expand to the process's OS cwd,
  which could be a different directory than the user's project root.
- Satisfies the acceptance criterion at its most restrictive reading
  ("replaced with a ctx-driven default").
- Aligns with OTP non-negotiable #8 ("pure functions are the default").

### Weaknesses

- **Behaviour-correcting change**: any caller that relies on the
  `File.cwd!` fallback (i.e. passes no `ctx[:cwd]`) will now get
  `false` instead of a path-based match. This is a silent semantic
  change for those callers — they will stop matching `PathPrefix` rules
  where they previously matched.
- Must audit all callers of `PathPrefix.match?/4` (direct and indirect
  via `Evaluator.evaluate/5`) to confirm `ctx[:cwd]` is always supplied.
  From the current codebase, `Evaluator` receives `ctx` from the session;
  if any session call site omits `:cwd`, rules silently stop matching.
- If `File.cwd!` is currently what makes the TUI's PathPrefix rules work
  in practice (e.g. no call site passes `:cwd` today), this change
  silently breaks that use case.
- Larger PR diff: both a production change and a test change.

### Costs

- 3-line production diff in `matchers.ex`.
- Requires a grep for all `Evaluator.evaluate` call sites to confirm
  `ctx[:cwd]` propagation; at minimum `lib/tau/session.ex` and
  `lib/tau/tui/app.ex` need inspection.
- If any call site is missing `:cwd`, a follow-up fix is needed before
  this change ships — or the PR must include that fix.

## Dependencies

- Audit: confirm every `Evaluator.evaluate/5` call site passes `:cwd`
  in the ctx map. The primary sites are `Tau.Session` and any test that
  calls `Evaluator.evaluate` with `PathPrefix`-containing rule sets.
- If a call site is discovered that does not pass `:cwd`, that caller
  must be patched in the same PR or the risk mitigated by a default
  argument change.

## Confidence

Medium. The code change is small and the intent is sound, but the
behaviour-correcting impact depends on a call-site audit that has not
been done. Confidence would be high after confirming `:cwd` is always
present in the ctx passed to `Evaluator.evaluate/5` at the call sites
in `lib/tau/session.ex`.

## Prior art / references

- `PathPrefix.match?/4` line 82 in `lib/tau/permissions/matchers.ex`
  — the specific offending line identified in the problem statement.
- Hickey "Simple Made Easy" (2011) — "complecting" as weaving two
  concerns that should be separated; removing the OS-state dependency
  is the canonical decomplecting move.
- OTP non-negotiable #8: "pure functions are the default; processes are
  the exception."

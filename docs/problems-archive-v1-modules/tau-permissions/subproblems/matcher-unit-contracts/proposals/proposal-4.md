---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Extract Glob.glob_match?/2 into Tau.Permissions.GlobMatcher with a standalone contract module

## Approach

Extract `Glob.glob_match?/2` and its private `compile/1` helper from
`Tau.Permissions.Matchers.Glob` into a dedicated module
`Tau.Permissions.GlobMatcher`. `Matchers.Glob` delegates to it.
`GlobMatcher` has its own dedicated test module
`test/tau/permissions/glob_matcher_test.exs` with StreamData properties
covering the full contract of `glob_match?/2`. The remaining four
matchers get direct unit tests in `test/tau/permissions/matchers_test.exs`
(example-based, two per matcher). `PathPrefix` is documented with
`@note`. The new module is the single canonical export of the glob
algorithm; other future callers (e.g. path-prefix glob extensions) use
`GlobMatcher.glob_match?/2` directly.

## Rationale

The problem identifies two complecting concerns: `Glob.glob_match?/2` is
a public function embedded in a `Matcher` implementation module, making
its contract discoverable only by reading that implementation. Extracting
it to `Tau.Permissions.GlobMatcher` makes the contract first-class and
separately testable, decomplecting the "glob algorithm" from the "glob
matcher behaviour implementation." The separation also enables
`PathPrefix` to eventually use `GlobMatcher.glob_match?/2` for prefix
patterns (a future seam), and prevents the common mistake of callers
importing `Matchers.Glob` just for the algorithm.

## Sketch

New file `lib/tau/permissions/glob_matcher.ex`:

```elixir
defmodule Tau.Permissions.GlobMatcher do
  @moduledoc """
  Trivial `*`/`?` glob algorithm, decoupled from the `Matcher` behaviour.

  ## Contract

  - `*` matches zero or more of any character (including empty string).
  - `?` matches exactly one character (any character, including `/`).
  - All other characters match themselves literally.
  - No character classes, no `**`, no brace expansion.

  This module is the canonical home for glob semantics in the
  `tau-permissions` subsystem. Import it directly rather than calling
  `Tau.Permissions.Matchers.Glob.glob_match?/2`.
  """

  @doc """
  Returns `true` iff `str` matches `pattern` under the `*`/`?` glob rules.
  """
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(pattern, str) do
    re = compile(pattern)
    Regex.match?(re, str)
  end

  @spec compile(String.t()) :: Regex.t()
  defp compile(pattern) do
    body =
      pattern
      |> String.codepoints()
      |> Enum.map_join("", fn
        "*" -> ".*"
        "?" -> "."
        c when c in ~w(. ^ $ + ( ) [ ] { } | \\) -> "\\" <> c
        c -> c
      end)

    Regex.compile!("^" <> body <> "$")
  end
end
```

Modified `lib/tau/permissions/matchers.ex`, `Glob` module:

```elixir
defmodule Tau.Permissions.Matchers.Glob do
  @moduledoc """
  Glob matcher. Patterns look like `Bash(npm run *)`, `Read(./*.exs)`.
  Glob semantics are defined in `Tau.Permissions.GlobMatcher`.
  """
  @behaviour Tau.Permissions.Matcher
  alias Tau.Permissions.GlobMatcher

  @impl true
  def match?({tool, glob}, tool_name, args, _ctx) do
    if tool == "*" or tool == tool_name do
      arg_str = arg_for(tool_name, args)
      GlobMatcher.glob_match?(glob, arg_str)
    else
      false
    end
  end

  # glob_match?/2 removed from this module; callers use GlobMatcher directly.
  # arg_for/2 kept private here.
  ...
end
```

New test file `test/tau/permissions/glob_matcher_test.exs`:

```elixir
defmodule Tau.Permissions.GlobMatcherTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.GlobMatcher

  property "* alone matches any string" do
    check all s <- StreamData.string(:printable) do
      assert GlobMatcher.glob_match?("*", s)
    end
  end

  property "literal pattern matches only itself" do
    check all s <- StreamData.string(:alphanumeric, min_length: 1) do
      assert GlobMatcher.glob_match?(s, s)
      refute GlobMatcher.glob_match?(s, s <> "X")
    end
  end

  property "prefix* matches any string that begins with prefix" do
    check all prefix <- StreamData.string(:alphanumeric, min_length: 1),
              suffix <- StreamData.string(:printable) do
      assert GlobMatcher.glob_match?(prefix <> "*", prefix <> suffix)
    end
  end

  property "? matches exactly one character" do
    check all c <- StreamData.string(:printable, length: 1),
              prefix <- StreamData.string(:alphanumeric) do
      assert GlobMatcher.glob_match?(prefix <> "?" <> "*", prefix <> c)
    end
  end

  # Documents the ? behaviour for / (currently matches; not treated as separator)
  test "? matches / (not a path separator in this implementation)" do
    assert GlobMatcher.glob_match?("foo?bar", "foo/bar")
  end

  test "* matches empty string" do
    assert GlobMatcher.glob_match?("npm *", "npm ")
    assert GlobMatcher.glob_match?("npm*", "npm")
  end
end
```

Old callers: `Tau.Permissions.Matchers.Glob` now delegates; any external
caller that referenced `Matchers.Glob.glob_match?/2` must be updated to
`GlobMatcher.glob_match?/2`. From a codebase search, no file outside
`matchers.ex` calls `Glob.glob_match?/2` directly today (only `Evaluator`
tests call it indirectly via the full stack).

## Tradeoffs

### Strengths

- `Glob.glob_match?/2` is now a standalone module with a clearly
  documented contract; callers can import `GlobMatcher` without taking
  a dependency on the `Matcher` behaviour implementation.
- The contract is now the authoritative source of truth for glob
  semantics in the subsystem; future matchers (e.g. a path-prefix-glob
  matcher) reuse it without copying.
- The property suite lives in its own test file, scoped to the algorithm;
  easier to extend as the glob language grows.
- Sets the structural precedent for further algorithm extraction (e.g.
  domain-matching logic into `Tau.Permissions.DomainMatcher`).
- Acceptance criterion met: `glob_match?/2` has multiple StreamData
  properties, and the `Glob.match?/4` delegation is trivially verifiable.

### Weaknesses

- **API-breaking for external callers of `Matchers.Glob.glob_match?/2`**:
  the public function moves. While no external callers exist today, any
  tooling or test that references the old path breaks silently at compile
  time (missing function) rather than at runtime.
- Larger diff than proposals 1–3: new module, new test file, modified
  `matchers.ex`. Higher review surface.
- The extraction is architectural rather than strictly required by the
  acceptance criterion: a property test on `Matchers.Glob.glob_match?/2`
  in-place would satisfy the criterion without the module split.
- Introduces a new module namespace (`Tau.Permissions.GlobMatcher`)
  that may be considered over-engineering for a ~10-line function.
- Requires updating the spec catalog (`spec-before-code.md`) if
  `GlobMatcher` is considered a new coordinating component — unlikely
  (it is stateless), but worth noting.

### Costs

- One new production file (`glob_matcher.ex`, ~30 lines).
- One new test file (`glob_matcher_test.exs`, ~40 lines).
- Modified `matchers.ex` (~3 lines changed in `Glob`).
- Any external caller of `Matchers.Glob.glob_match?/2` needs updating —
  zero today, but future PRs that add callers need to know the canonical
  location has changed.

## Dependencies

- No library changes; `stream_data` already present.
- Should update `spec-before-code.md` to reference `glob_matcher.ex`
  in the `SPEC-PERMISSION-PROMPTS` source-map appendix if the spec
  explicitly lists matchers files — confirm before opening the PR.

## Confidence

Medium. The extraction is clean and the sketch is complete, but the
benefit over a simpler in-place property test (Proposal 2) is marginal
given the current codebase size and the zero external callers of
`glob_match?/2` today. Confidence in the structural choice would be
higher if a second caller of `GlobMatcher.glob_match?/2` existed or was
planned (e.g. a path-prefix-glob extension).

## Prior art / references

- Clojure's `clojure.string` extract pattern: algorithm moved out of
  the context where it was first needed into a named, independently
  testable namespace.
- `Tau.Permissions.GlobMatcher` naming mirrors `Tau.Permissions.Matcher`
  behaviour naming convention; `*Matcher` is already the module suffix
  for concrete implementations.
- `lib/tau/permissions/matchers.ex` — current home of `Glob.glob_match?/2`,
  the function being extracted.

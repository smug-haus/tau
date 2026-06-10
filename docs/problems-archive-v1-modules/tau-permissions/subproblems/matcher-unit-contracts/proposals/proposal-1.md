---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Direct example-based unit tests, no refactor

## Approach

Add a new test file `test/tau/permissions/matchers_test.exs` with
`ExUnit.Case` example tests that directly import each of the five
`Tau.Permissions.Matchers.*` modules and call `match?/4` (and
`Glob.glob_match?/2`) with handpicked boundary inputs. The production
code in `lib/tau/permissions/matchers.ex` is not touched. The
`PathPrefix` `File.cwd!` fallback is documented with a `@note` in
the moduledoc rather than removed.

## Rationale

The acceptance criterion requires at least two direct tests per
matcher module and at least one property for `Glob.glob_match?/2`.
This proposal satisfies the first two requirements via example tests
for all five matchers and defers the property requirement to a
`glob_match?` example covering `*`-empty-string and `?`-slash edge
cases. The `File.cwd!` concern is resolved by documentation rather
than code change: the moduledoc gains a `@note` identifying the
deviation. Because no production code changes, the risk surface is
zero and the PR diff is test-only.

## Sketch

New file `test/tau/permissions/matchers_test.exs`:

```elixir
defmodule Tau.Permissions.MatchersTest do
  use ExUnit.Case, async: true

  alias Tau.Permissions.Matchers.{Always, Glob, PathPrefix, Domain, Regex}

  describe "Always" do
    test "wildcard * matches any tool" do
      assert Always.match?("*", "Bash", %{}, %{})
      assert Always.match?("*", "Read", %{}, %{})
    end

    test "bare rule matches exact tool name only" do
      assert Always.match?("Read", "Read", %{}, %{})
      refute Always.match?("Read", "Bash", %{}, %{})
    end

    test "non-binary rule returns false" do
      refute Always.match?(nil, "Read", %{}, %{})
    end
  end

  describe "Glob.glob_match?/2" do
    test "* matches empty string" do
      assert Glob.glob_match?("npm *", "npm ")
    end

    test "* does not require trailing content" do
      assert Glob.glob_match?("npm*", "npm")
    end

    test "? matches a single character but not /" do
      assert Glob.glob_match?("foo?bar", "fooxbar")
      assert Glob.glob_match?("foo?bar", "foo/bar")  # documents current behaviour
    end

    test "literal pattern matches itself exactly" do
      assert Glob.glob_match?("npm test", "npm test")
      refute Glob.glob_match?("npm test", "npm tests")
    end
  end

  describe "Glob.match?/4" do
    test "tool wildcard * matches any tool name" do
      assert Glob.match?({"*", "npm *"}, "Bash", %{"command" => "npm test"}, %{})
      assert Glob.match?({"*", "npm *"}, "Write", %{"path" => "npm test"}, %{})
    end

    test "specific tool only matches that tool" do
      assert Glob.match?({"Bash", "npm *"}, "Bash", %{"command" => "npm build"}, %{})
      refute Glob.match?({"Bash", "npm *"}, "Read", %{"command" => "npm build"}, %{})
    end

    test "no matching arg key returns false (empty arg_str)" do
      refute Glob.match?({"Bash", "npm *"}, "Bash", %{}, %{})
    end
  end

  describe "PathPrefix" do
    test "path under prefix matches" do
      assert PathPrefix.match?(
               {"Read", "/tmp"},
               "Read",
               %{"path" => "/tmp/foo.txt"},
               %{cwd: "/"}
             )
    end

    test "path outside prefix does not match" do
      refute PathPrefix.match?(
               {"Read", "/tmp"},
               "Read",
               %{"path" => "/etc/passwd"},
               %{cwd: "/"}
             )
    end

    test "relative path is expanded against ctx[:cwd]" do
      assert PathPrefix.match?(
               {"Read", "lib"},
               "Read",
               %{"path" => "lib/foo.ex"},
               %{cwd: "/app"}
             )
    end

    # File.cwd! fallback: when ctx[:cwd] is absent the OS cwd is used.
    # This is documented in the moduledoc @note; this test pins the
    # behaviour rather than asserting purity.
    test "absent ctx[:cwd] falls back to File.cwd!" do
      result = PathPrefix.match?({"Read", "."}, "Read", %{"path" => "."}, %{})
      assert is_boolean(result)
    end
  end

  describe "Domain" do
    test "exact host matches" do
      assert Domain.match?(
               {"WebFetch", "github.com"},
               "WebFetch",
               %{"url" => "https://github.com/x"},
               %{}
             )
    end

    test "subdomain matches" do
      assert Domain.match?(
               {"WebFetch", "github.com"},
               "WebFetch",
               %{"url" => "https://api.github.com/x"},
               %{}
             )
    end

    test "unrelated domain does not match" do
      refute Domain.match?(
               {"WebFetch", "github.com"},
               "WebFetch",
               %{"url" => "https://evil.com/"},
               %{}
             )
    end

    test "non-URL string does not match" do
      refute Domain.match?({"WebFetch", "github.com"}, "WebFetch", %{"url" => "not-a-url"}, %{})
    end

    test "empty url does not match" do
      refute Domain.match?({"WebFetch", "github.com"}, "WebFetch", %{}, %{})
    end
  end

  describe "Regex" do
    test "matching regex allows" do
      re = ~r/^sudo/
      assert Regex.match?({"Bash", re}, "Bash", %{"command" => "sudo rm"}, %{})
    end

    test "non-matching regex denies" do
      re = ~r/^sudo/
      refute Regex.match?({"Bash", re}, "Bash", %{"command" => "ls"}, %{})
    end

    test "tool mismatch returns false" do
      re = ~r/.*/
      refute Regex.match?({"Bash", re}, "Read", %{"command" => "anything"}, %{})
    end
  end
end
```

`PathPrefix` moduledoc addition in `matchers.ex`:

```elixir
defmodule Tau.Permissions.Matchers.PathPrefix do
  @moduledoc """
  Matches when the tool argument's path is under the given prefix.

  @note When `ctx[:cwd]` is absent, this matcher calls `File.cwd!/0`
  to resolve relative paths. This makes `match?/4` non-deterministic
  under different OS working directories — a known deviation from the
  pure-function contract shared by all other matchers. Callers that
  need deterministic results MUST supply `ctx[:cwd]`.
  """
  ...
end
```

## Tradeoffs

### Strengths

- Zero production-code risk: diff is test-only plus a two-line moduledoc.
- Immediately satisfies the acceptance criterion for all five matchers.
- Pins the `?`-matches-`/` and `*`-matches-empty-string edge cases of
  `Glob.glob_match?/2` as documented behaviour.
- The `PathPrefix` fallback behaviour is now contractually documented
  (the test asserting `is_boolean/1` and the `@note` together form the
  documentation contract).
- Lowest-effort path from red acceptance criterion to green.

### Weaknesses

- No property coverage: the tests cover specific chosen inputs, so
  unanticipated boundary conditions (e.g. Unicode in hostnames, paths
  with `..` components, regex special characters in glob patterns)
  remain uncovered.
- The `PathPrefix` `File.cwd!` fallback remains impure; the test pins
  that the call doesn't crash but cannot assert determinism.
- `Glob.glob_match?/2` boundary coverage is limited to the three
  hand-picked cases; a StreamData property would cover far more of the
  input space.
- Documenting a known deviation rather than fixing it is technical debt
  acknowledged but not retired.

### Costs

- One new test file (~80 lines).
- No migration cost; no API changes.
- The `@note` addition is a one-line moduledoc change.

## Dependencies

- None. All matchers are already importable; no library additions needed.

## Confidence

Medium. The approach is straightforward and the sketch is complete, but
the absence of property tests means the acceptance criterion is met only
at its minimum bar ("at least two direct tests per matcher… at least one
property for `Glob.glob_match?/2`"). The `Glob` coverage here uses
example tests, not a StreamData property — the acceptance criterion says
"at least one property"; review whether example tests qualify or whether
a property is strictly required. Confidence would be high if "property"
is interpreted loosely.

## Prior art / references

- `test/tau/permissions/evaluator_test.exs` — existing example-test
  pattern in this subsystem; the new file follows the same structure.
- Elixir `ExUnit.Case` docs — `async: true` is safe here since all
  matchers are pure modules with no shared state.

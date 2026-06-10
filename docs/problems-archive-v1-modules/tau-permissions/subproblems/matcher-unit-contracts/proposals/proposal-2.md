---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: StreamData property tests for all five matchers

## Approach

Add `test/tau/permissions/matchers_test.exs` using `StreamData` /
`ExUnitProperties` with property-based tests for each matcher. Every
matcher gets at least two properties: one asserting the deterministic
invariant of a valid input class (e.g. "for any binary tool name equal
to the rule's tool, `Always.match?/4` returns `true`") and one
asserting a boundary (e.g. "for any `{tool, domain}` where the URL host
is a proper suffix, `Domain.match?/4` returns `true`"). `Glob.glob_match?/2`
gets its own property. No production code is changed. The `PathPrefix`
fallback is documented via `@note` in the moduledoc (same as Proposal 1).

## Rationale

The acceptance criterion explicitly requires "at least one property" for
`Glob.glob_match?/2` and properties are the natural fit for the
invariant-bearing matchers named in OTP non-negotiable #6. Property
tests explore far more of the input space than handpicked examples,
catching boundary conditions (Unicode hostnames, paths with `..`, glob
patterns containing regex metacharacters, empty strings in every
position) that example tests miss. This proposal satisfies the
acceptance criterion at its stated intent, not just its minimum count.

## Sketch

New file `test/tau/permissions/matchers_test.exs`:

```elixir
defmodule Tau.Permissions.MatchersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.Matchers.{Always, Glob, PathPrefix, Domain, Regex, as: M}

  # ── Always ──────────────────────────────────────────────────────────

  property "Always: wildcard * matches any tool name" do
    check all tool <- StreamData.string(:printable, min_length: 1) do
      assert Always.match?("*", tool, %{}, %{})
    end
  end

  property "Always: binary rule matches iff tool_name equals rule" do
    check all rule <- StreamData.string(:alphanumeric, min_length: 1),
              tool <- StreamData.string(:alphanumeric, min_length: 1) do
      assert Always.match?(rule, tool, %{}, %{}) == (rule == tool)
    end
  end

  # ── Glob.glob_match?/2 ───────────────────────────────────────────────

  property "Glob.glob_match?/2: literal pattern matches only itself" do
    check all s <- StreamData.string(:alphanumeric, min_length: 1) do
      assert Glob.glob_match?(s, s)
      # any single extra char appended makes it not match the literal
      refute Glob.glob_match?(s, s <> "X")
    end
  end

  property "Glob.glob_match?/2: * alone matches any string" do
    check all s <- StreamData.string(:printable) do
      assert Glob.glob_match?("*", s)
    end
  end

  property "Glob.glob_match?/2: prefix* matches any string starting with prefix" do
    check all prefix <- StreamData.string(:alphanumeric, min_length: 1),
              suffix <- StreamData.string(:printable) do
      assert Glob.glob_match?(prefix <> "*", prefix <> suffix)
    end
  end

  # ── PathPrefix ───────────────────────────────────────────────────────

  property "PathPrefix: path under prefix matches; path outside does not" do
    check all dir <- StreamData.string(:alphanumeric, min_length: 1),
              filename <- StreamData.string(:alphanumeric, min_length: 1) do
      inside  = "/tmp/" <> dir <> "/" <> filename
      outside = "/etc/" <> filename
      prefix  = "/tmp/" <> dir

      assert PathPrefix.match?({"Read", prefix}, "Read", %{"path" => inside},  %{cwd: "/"})
      refute PathPrefix.match?({"Read", prefix}, "Read", %{"path" => outside}, %{cwd: "/"})
    end
  end

  property "PathPrefix: tool mismatch always returns false" do
    check all tool <- StreamData.member_of(["Bash", "Write", "Edit"]),
              path <- StreamData.string(:alphanumeric) do
      refute PathPrefix.match?({"Read", "/tmp"}, tool, %{"path" => path}, %{cwd: "/"})
    end
  end

  # ── Domain ───────────────────────────────────────────────────────────

  property "Domain: exact host always matches" do
    check all domain <- StreamData.string(:alphanumeric, min_length: 1) do
      url = "https://" <> domain <> "/path"
      assert Domain.match?({"WebFetch", domain}, "WebFetch", %{"url" => url}, %{})
    end
  end

  property "Domain: subdomain always matches parent domain" do
    check all sub    <- StreamData.string(:alphanumeric, min_length: 1),
              domain <- StreamData.string(:alphanumeric, min_length: 1) do
      url = "https://" <> sub <> "." <> domain <> "/path"
      assert Domain.match?({"WebFetch", domain}, "WebFetch", %{"url" => url}, %{})
    end
  end

  # ── Regex ─────────────────────────────────────────────────────────────

  property "Regex: tool wildcard * dispatches to regex match on arg" do
    check all s <- StreamData.string(:alphanumeric, min_length: 1) do
      re = Elixir.Regex.compile!("^" <> s)
      assert M.Regex.match?({"*", re}, "Bash",  %{"command" => s <> " extra"}, %{})
      refute M.Regex.match?({"*", re}, "Bash",  %{"command" => "x" <> s},     %{})
    end
  end
end
```

`mix.exs` already lists `stream_data` as a dependency per existing
property tests in the codebase (e.g. `test/tau/permissions/mode_test.exs`);
no new dependency.

`PathPrefix` moduledoc `@note` — identical to Proposal 1.

## Tradeoffs

### Strengths

- Directly satisfies the "at least one property" language in the
  acceptance criterion, including for `Glob.glob_match?/2`.
- OTP non-negotiable #6 ("properties before examples for
  invariant-bearing modules") is honoured at the spirit level: the
  matcher module contracts are now property-verified.
- Input space explored is orders of magnitude larger than any example
  suite; edge conditions like `dir` containing dots, subdomains of length
  1, globs with no wildcard, etc. are caught probabilistically.
- Still no production-code change; diff is test-only plus `@note`.

### Weaknesses

- Properties are harder to write than examples and easier to write
  wrongly: a property that generates only "safe" inputs (e.g.
  `:alphanumeric` strings for domain tests) misses Unicode hostnames,
  IDNs, and empty strings. The sketch uses `:alphanumeric` generators in
  several places precisely to avoid generator failure rather than to
  capture the full contract — those are weaker than they appear.
- `Glob.glob_match?/2` semantics for `?` matching `/` are not tested
  by the property (because generating `?` as a glob metachar and `/`
  as a path separator requires a custom generator). This corner is
  documented but not exercised as a property.
- The `PathPrefix` `File.cwd!` fallback is still impure; the property
  suite only runs with `ctx[:cwd]` supplied.
- `stream_data` dependency is already present, but the import of
  `ExUnitProperties` adds a `use` macro not yet used in the matchers
  test namespace — minor, but may require a `config/test.exs` addition
  if `async: true` + StreamData conflicts with any global setup.

### Costs

- One new test file (~80 lines of property tests).
- No API changes, no production-code risk.
- Slightly higher cognitive overhead for future contributors unfamiliar
  with StreamData generators.

## Dependencies

- `stream_data` must be in `mix.exs` test deps. Existing
  `test/tau/permissions/mode_test.exs` already uses `StreamData`, so
  this is already satisfied.

## Confidence

Medium-high. The approach is well-established in the codebase
(mode_test.exs pattern). Confidence would be high if the generator
choices were widened to cover Unicode and empty-string edge cases beyond
`:alphanumeric` / `:printable`.

## Prior art / references

- `test/tau/permissions/mode_test.exs` — existing StreamData property
  pattern in the same subsystem; the new file mirrors its structure.
- CLAUDE.md OTP non-negotiable #6: "Properties before examples for
  invariant-bearing modules."
- Elixir `stream_data` hex docs — `StreamData.string/2`,
  `StreamData.member_of/1`.

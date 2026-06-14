defmodule Tau.Factory.IssueElaborationTest do
  @moduledoc """
  Gating tests for D-369 / D-370 / D-371 — issue → declared-scope elaboration
  (SPEC-FACTORY-CORE §6, PR #505, issue #488).

  ## What these tests enforce

  **D-369 — Conservative elaboration.**  `IssueSelector.select/1` MUST return
  `work_item.scope` as a `ConflictCheck.scope()` map (never a String).  The
  returned map must be accepted by `ConflictCheck.clear?/2` without crashing
  (closing the [C124-B10] latent type error), must over-declare files cited
  without a line reference (no codepoint narrowing), and must produce scopes
  that conflict on a shared file (the V3 soundness witness).

  **D-370 — Injected pure seam.**  An `:elaborate_fun` injected into
  `IssueSelector.select/1` is honoured (its output becomes `work_item.scope`).
  The DEFAULT elaborator is pure and deterministic — same issue → same scope —
  and makes NO network/LLM call on the admission path.

  **D-371 — Serialize-on-unscopable.**  An issue with no file paths and no SPEC
  citations yields a sentinel scope that clears against an EMPTY in-flight set
  `F` (admitted alone) but conflicts against ANY non-empty `F` (never
  disjoint-from-everything).

  Each test exercises the REAL `IssueSelector.select/1` and `ConflictCheck`
  API — no hand-built scope bypasses. Tests MUST FAIL against the pre-D-369
  implementation (where `select/1` emits a String scope and lacks
  `:elaborate_fun`).
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.ConflictCheck
  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:elab_ledger)

    start_supervised!(
      {Writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # Stub gh adapter: returns fixed issues, no network.
  defp gh_stub(issues) do
    fn _milestone -> {:ok, issues} end
  end

  # Build an issue_map with at least the keys the --json projection supplies.
  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  # Empty ConflictCheck.scope() — no deps, files, codepoints, specs, resources.
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # D-369(a): scope is a ConflictCheck.scope() map — not a String
  #
  # SPEC: "IssueSelector.select/1 produces work_item.scope as a
  # ConflictCheck.scope() map (%{deps, files, codepoints, specs, resources}),
  # never a string, … (closes the [C124-B10] latent type error)."
  #
  # PRE-IMPL FAILURE: select/1 returns scope as "#{number}: #{title}" (a
  # String).  ConflictCheck.clear?/2 calls Map.fetch!(scope, :files) on it,
  # which raises a KeyError/BadMapError, OR the map-shape assertion below fails.
  # ---------------------------------------------------------------------------
  @tag :d_369
  test "D-369(a): select/1 scope is a ConflictCheck.scope() map accepted by clear?/2 without crashing" do
    ledger = start_ledger()

    issue_map = issue(488, "I2: issue → declared-scope elaboration")
    gh_fun = gh_stub([issue_map])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_fun
      )

    assert {_issue, scope, _hash, _branch} = result,
           "D-369: select/1 must return a {issue, scope, hash, branch} work_item; got: #{inspect(result)}"

    # scope MUST be a map with the five ConflictCheck keys — never a String.
    assert is_map(scope),
           "D-369: work_item.scope must be a map (ConflictCheck.scope()), not #{inspect(scope)}"

    assert Map.has_key?(scope, :files),
           "D-369: scope missing :files key; got keys: #{inspect(Map.keys(scope))}"

    assert Map.has_key?(scope, :codepoints),
           "D-369: scope missing :codepoints key"

    assert Map.has_key?(scope, :specs),
           "D-369: scope missing :specs key"

    assert Map.has_key?(scope, :deps),
           "D-369: scope missing :deps key"

    assert Map.has_key?(scope, :resources),
           "D-369: scope missing :resources key"

    # The map must be accepted by ConflictCheck.clear?/2 without crashing.
    # (Pre-impl: a String scope causes Map.fetch! to crash here.)
    result_clear = ConflictCheck.clear?(scope, %{})

    assert result_clear in [
             :clear,
             {:conflict, :no_dependency},
             {:conflict, :disjoint_files},
             {:conflict, :disjoint_codepoints},
             {:conflict, :no_shared_spec},
             {:conflict, :resource_isolatable}
           ],
           "D-369: ConflictCheck.clear?/2 returned unexpected value: #{inspect(result_clear)}"
  end

  # ---------------------------------------------------------------------------
  # D-369(b): file-cited-but-not-line-cited → whole-files entry, no codepoints
  #
  # SPEC: "a fixture issue citing a file but no line yields that file in
  # `files` and no narrowing `codepoints` entry (over-declaration)"
  # [C127-B10] / [C128-B10].
  #
  # PRE-IMPL FAILURE: scope is a String — map assertions fail.
  # ---------------------------------------------------------------------------
  @tag :d_369
  test "D-369(b): issue citing a file path but no line yields that file in scope.files with no codepoints entry" do
    ledger = start_ledger()

    body = """
    Fixes a bug in lib/tau/factory/issue_selector.ex — no specific line cited.
    """

    issue_map = issue(488, "File-cited but no line", body: body)
    gh_fun = gh_stub([issue_map])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_fun
      )

    assert {_issue, scope, _hash, _branch} = result,
           "D-369: select/1 must return a 4-tuple work_item"

    assert is_map(scope),
           "D-369(b): scope must be a ConflictCheck.scope() map, not #{inspect(scope)}"

    # The file cited in the body must appear in scope.files.
    assert MapSet.member?(scope.files, "lib/tau/factory/issue_selector.ex"),
           "D-369(b): cited file 'lib/tau/factory/issue_selector.ex' must appear in scope.files; " <>
             "got: #{inspect(scope.files)}"

    # Over-declaration: NO codepoints entry for the cited file (no line was cited).
    codepoint_paths = MapSet.to_list(scope.codepoints) |> Enum.map(&elem(&1, 0))

    refute "lib/tau/factory/issue_selector.ex" in codepoint_paths,
           "D-369(b): file cited without a line MUST NOT appear in scope.codepoints " <>
             "(codepoint narrowing requires explicit file:line citation); " <>
             "got codepoints: #{inspect(scope.codepoints)}"
  end

  # ---------------------------------------------------------------------------
  # D-369(c): two issues citing a SHARED file → their scopes conflict
  #
  # SPEC: "two fixture issues citing a shared file elaborate to scopes that
  # ConflictCheck.pairwise_clear?/2 rejects (the V3 soundness witness — a real
  # shared file is never elaborated apart)."
  #
  # We assert via ConflictCheck.clear?(scope_b, %{"unit-a" => scope_a}), which
  # is the real pairwise-conflict path through the Scheduler's admission check.
  # A shared file must produce a {:conflict, :disjoint_files} result.
  #
  # PRE-IMPL FAILURE: scope is a String → ConflictCheck.clear?/2 crashes.
  # ---------------------------------------------------------------------------
  @tag :d_369
  test "D-369(c): two issues citing a shared file produce scopes that conflict via ConflictCheck.clear?/2" do
    ledger = start_ledger()

    shared_file = "lib/tau/factory/issue_selector.ex"

    body_a = "Modifies #{shared_file} for reason A."
    body_b = "Also modifies #{shared_file} for reason B."

    issue_a = issue(488, "Issue A — shared file", body: body_a)
    issue_b = issue(489, "Issue B — shared file", body: body_b)

    {_issue_a_raw, scope_a, _hash_a, _branch_a} =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_stub([issue_a])
      )

    {_issue_b_raw, scope_b, _hash_b, _branch_b} =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_stub([issue_b])
      )

    assert is_map(scope_a),
           "D-369(c): scope_a must be a ConflictCheck.scope() map, not #{inspect(scope_a)}"

    assert is_map(scope_b),
           "D-369(c): scope_b must be a ConflictCheck.scope() map, not #{inspect(scope_b)}"

    # Both scopes must include the shared file.
    assert MapSet.member?(scope_a.files, shared_file),
           "D-369(c): shared file must appear in scope_a.files; got: #{inspect(scope_a.files)}"

    assert MapSet.member?(scope_b.files, shared_file),
           "D-369(c): shared file must appear in scope_b.files; got: #{inspect(scope_b.files)}"

    # Soundness witness: scope_b conflicts against scope_a via the real
    # ConflictCheck predicate (the same path Scheduler.admit/3 uses).
    in_flight = %{"unit-488" => scope_a}
    check_result = ConflictCheck.clear?(scope_b, in_flight)

    assert {:conflict, :disjoint_files} = check_result,
           "D-369(c): two scopes sharing '#{shared_file}' must conflict on " <>
             ":disjoint_files; ConflictCheck.clear?/2 returned: #{inspect(check_result)}"
  end

  # ---------------------------------------------------------------------------
  # D-370(a): injected :elaborate_fun is honoured
  #
  # SPEC: "a stub elaborate_fun is honoured; the default is pure and
  # network-free." [C125-B10].
  #
  # PRE-IMPL FAILURE: select/1 does not accept :elaborate_fun → KeyError or
  # the stub output is ignored and the String scope is returned instead.
  # ---------------------------------------------------------------------------
  @tag :d_370
  test "D-370(a): :elaborate_fun stub injected into select/1 is honoured as work_item.scope" do
    ledger = start_ledger()

    # A known sentinel scope that could not be produced by any real heuristic.
    sentinel_files = MapSet.new(["lib/tau/__sentinel_test_file__.ex"])

    stub_scope = %{
      deps: [],
      files: sentinel_files,
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    elaborate_stub = fn _issue_map -> stub_scope end

    issue_map = issue(488, "D-370 stub test")
    gh_fun = gh_stub([issue_map])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_fun,
        elaborate_fun: elaborate_stub
      )

    assert {_issue, scope, _hash, _branch} = result,
           "D-370: select/1 must return a 4-tuple work_item; got: #{inspect(result)}"

    assert scope == stub_scope,
           "D-370(a): injected :elaborate_fun output must become work_item.scope; " <>
             "expected #{inspect(stub_scope)}, got #{inspect(scope)}"
  end

  # ---------------------------------------------------------------------------
  # D-370(b): default elaborator is pure and deterministic — same issue → same scope
  #
  # SPEC: "the DEFAULT elaborator is pure/deterministic and makes NO network/
  # LLM call on the admission path (assert determinism: same issue → same scope;
  # no network)."
  #
  # PRE-IMPL FAILURE: scope is a String — not a scope map, but determinism
  # comparison may coincidentally pass; the is_map/1 assertion fails.
  # ---------------------------------------------------------------------------
  @tag :d_370
  test "D-370(b): default elaborator is deterministic — same issue input yields identical scope twice" do
    ledger_1 = start_ledger()
    ledger_2 = start_ledger()

    body = "Touches lib/tau/factory/conflict_check.ex for D-370 determinism check."
    issue_map = issue(488, "D-370 determinism", body: body)

    # Select from two independent ledgers (both empty) with the same issue.
    {_i1, scope_1, _h1, _b1} =
      IssueSelector.select(
        ledger: ledger_1,
        milestone: "M10",
        gh_fun: gh_stub([issue_map])
      )

    {_i2, scope_2, _h2, _b2} =
      IssueSelector.select(
        ledger: ledger_2,
        milestone: "M10",
        gh_fun: gh_stub([issue_map])
      )

    assert is_map(scope_1),
           "D-370(b): scope must be a ConflictCheck.scope() map, not #{inspect(scope_1)}"

    assert scope_1 == scope_2,
           "D-370(b): default elaborator must be deterministic — same issue must " <>
             "produce identical scope on repeated calls; got scope_1=#{inspect(scope_1)} " <>
             "scope_2=#{inspect(scope_2)}"
  end

  # ---------------------------------------------------------------------------
  # D-371: unscopable issue (no files, no specs) → clears empty F, defers non-empty F
  #
  # SPEC: "when the default elaborator extracts no files and no specs from an
  # issue, it returns a universal-conflict sentinel scope that ConflictCheck
  # rejects against every non-empty in-flight member, so an unscopable unit is
  # admitted only into an empty F (it runs alone) and is never treated as
  # disjoint-from-everything."
  #
  # PRE-IMPL FAILURE: scope is a String → ConflictCheck.clear?/2 crashes on both
  # the empty-F and non-empty-F assertions.
  # ---------------------------------------------------------------------------
  @tag :d_371
  test "D-371: unscopable issue scope clears an empty in-flight set but conflicts any non-empty one" do
    ledger = start_ledger()

    # Deliberately vague issue body — no file paths, no SPEC citations,
    # no labels that map to resources.
    vague_issue = issue(488, "Something needs fixing", body: "We should fix the thing.")
    gh_fun = gh_stub([vague_issue])

    result =
      IssueSelector.select(
        ledger: ledger,
        milestone: "M10",
        gh_fun: gh_fun
      )

    assert {_issue, scope, _hash, _branch} = result,
           "D-371: select/1 must return a 4-tuple work_item; got: #{inspect(result)}"

    assert is_map(scope),
           "D-371: scope must be a ConflictCheck.scope() map, not #{inspect(scope)}"

    # (a) Clears against an EMPTY in-flight set — admitted alone.
    assert ConflictCheck.clear?(scope, %{}) == :clear,
           "D-371: unscopable scope must clear an empty in-flight F; " <>
             "ConflictCheck.clear?/2 returned: #{inspect(ConflictCheck.clear?(scope, %{}))}"

    # (b) Conflicts against a non-empty in-flight set containing ANY scope.
    # We use a minimal non-empty scope as the in-flight member.
    other_scope = empty_scope()
    in_flight = %{"unit-other" => other_scope}
    conflict_result = ConflictCheck.clear?(scope, in_flight)

    assert conflict_result != :clear,
           "D-371: unscopable scope must conflict against ANY non-empty in-flight F " <>
             "(serialize-on-unscopable); ConflictCheck.clear?/2 returned :clear " <>
             "instead of a {:conflict, _} tuple; scope=#{inspect(scope)}"

    assert match?({:conflict, _}, conflict_result),
           "D-371: ConflictCheck.clear?/2 must return {:conflict, _} for unscopable " <>
             "scope against non-empty F; got: #{inspect(conflict_result)}"
  end

  # ---------------------------------------------------------------------------
  # D-371 (reverse direction): sentinel ALREADY IN-FLIGHT blocks later non-sentinel
  #
  # SPEC: "an unscopable unit is admitted only into an empty F (it runs alone)"
  # — equivalently, once a sentinel is in F, NO subsequent unit may join F
  # alongside it.  The current implementation is ASYMMETRIC:
  #   clear?(sentinel, %{"u" => other})  → conflict  ✓  (forward, tested above)
  #   clear?(non_sentinel, %{"u" => sentinel}) → :clear  ✗  (reverse, the hole)
  #
  # This test asserts the REVERSE direction: when the sentinel scope is already
  # an in-flight member, a subsequent NON-sentinel candidate must CONFLICT, not
  # clear.
  #
  # PRE-IMPL FAILURE: ConflictCheck.clear?/2 only checks
  # `declared_scope.universal_conflict` — it never checks in-flight members'
  # `:universal_conflict` flag.  So `clear?(normal_scope, %{"unit-N" => sentinel})`
  # falls through to the MapSet checks (all empty-vs-nonempty intersections are
  # disjoint) and returns `:clear`, violating D-371.
  # ---------------------------------------------------------------------------
  @tag :d_371
  test "D-371 (reverse): sentinel scope already in-flight causes subsequent non-sentinel candidate to conflict" do
    ledger_sentinel = start_ledger()
    ledger_normal = start_ledger()

    # Produce the sentinel scope via the REAL elaborator (vague issue, no
    # file paths, no SPEC citations — triggers the universal-conflict sentinel).
    vague_issue = issue(999, "Something vague", body: "No files or specs mentioned here.")

    {_i_s, sentinel_scope, _h_s, _b_s} =
      IssueSelector.select(
        ledger: ledger_sentinel,
        milestone: "M10",
        gh_fun: gh_stub([vague_issue])
      )

    assert is_map(sentinel_scope),
           "D-371(reverse): sentinel scope must be a map; got: #{inspect(sentinel_scope)}"

    assert Map.get(sentinel_scope, :universal_conflict, false),
           "D-371(reverse): vague issue must yield a sentinel scope with universal_conflict: true; " <>
             "got: #{inspect(sentinel_scope)}"

    # Produce a normal (scopable) scope via the REAL elaborator: a regular
    # issue citing a concrete file path — no sentinel flag.
    normal_issue =
      issue(488, "Normal scoped work",
        body: "Modifies lib/tau/factory/conflict_check.ex for some reason."
      )

    {_i_n, normal_scope, _h_n, _b_n} =
      IssueSelector.select(
        ledger: ledger_normal,
        milestone: "M10",
        gh_fun: gh_stub([normal_issue])
      )

    assert is_map(normal_scope),
           "D-371(reverse): normal scope must be a map; got: #{inspect(normal_scope)}"

    refute Map.get(normal_scope, :universal_conflict, false),
           "D-371(reverse): file-citing issue must NOT yield a sentinel scope; " <>
             "got: #{inspect(normal_scope)}"

    # The sentinel is already in-flight.  The non-sentinel candidate comes later.
    # D-371 requires it to CONFLICT — the sentinel unit must run alone.
    in_flight_with_sentinel = %{"unit-sentinel" => sentinel_scope}
    reverse_result = ConflictCheck.clear?(normal_scope, in_flight_with_sentinel)

    assert reverse_result != :clear,
           "D-371(reverse): a non-sentinel candidate must CONFLICT when the in-flight " <>
             "set already contains a sentinel (universal_conflict) scope; " <>
             "ConflictCheck.clear?/2 returned :clear — asymmetric D-371 bug present; " <>
             "normal_scope=#{inspect(normal_scope)}, sentinel_scope=#{inspect(sentinel_scope)}"

    assert match?({:conflict, _}, reverse_result),
           "D-371(reverse): ConflictCheck.clear?/2 must return {:conflict, _}; " <>
             "got: #{inspect(reverse_result)}"
  end
end

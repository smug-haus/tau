defmodule Tau.Factory.BriefAssemblerRoleTest do
  @moduledoc """
  Gating tests for D-382 — role-aware brief + actionable seeded issue (#517).

  ## What these tests enforce

  **D-382 — `assemble/2` gains a `:role` opt (`:test_author` | `:implementer`)
  and renders a ROLE-SPECIFIC actionable instruction section.**

  - `:test_author` role → brief includes instructions to WRITE the gating test,
    the expected `test/...` path, and states it is in a fresh isolated worktree.
    It does NOT include the implementer instruction.
  - `:implementer` role → brief includes instructions to IMPLEMENT the issue to
    satisfy the gating test. It does NOT include the test-author instruction.
  - Two roles produce DIFFERENT briefs for the same input.
  - A brief for an issue with a real `body` is actionable — the body content
    appears in the brief, NOT `(none declared)`.

  Each test name and `@tag` carries the `D-382` token for Gate 5.1 AC linkage.

  ## Role-threading seam found

  `Tau.Factory.Supervisor.to_unit_work_item/1` is the single assembly site
  (line 322–343). It calls `BriefAssembler.assemble/2` but passes NO `:role`.
  The oracle worker (test_author) and the implementing worker (implementer) both
  receive the same role-agnostic brief today. The implementer must:
    1. Add `:role` support to `BriefAssembler.assemble/2` (role-specific section).
    2. Thread the worker's role from `to_unit_work_item/1` (or from a new
       role-carrying `work_item` field) into the `:role` opt passed to `assemble/2`.
    3. Enrich `Tau.Factory.Dogfood.Sandbox` with a real issue `body` string.

  All tests exercise the REAL `BriefAssembler.assemble/2` API — no hand-built
  struct bypasses.
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.BriefAssembler
  alias Tau.Factory.Dogfood.Sandbox
  alias Tau.Factory.Supervisor, as: FactorySupervisor

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # A minimal but realistic input used across role tests.
  defp d382_input do
    %{
      issue:
        issue(517, "role-aware brief + actionable seeded issue",
          body:
            "BriefAssembler.assemble/2 should render a role-specific section. " <>
              "Touches lib/tau/factory/brief_assembler.ex."
        ),
      declared_scope: %{
        deps: [],
        files: MapSet.new(["lib/tau/factory/brief_assembler.ex"]),
        codepoints: MapSet.new(),
        specs: MapSet.new(["SPEC-FACTORY-CORE"]),
        resources: MapSet.new()
      },
      gating_test_paths: ["test/tau/factory/brief_assembler_role_test.exs"],
      spec_refs: ["D-382"]
    }
  end

  # ---------------------------------------------------------------------------
  # D-382(a): :test_author role → brief contains test-author instruction,
  #           names the expected test/... path, references worktree context;
  #           does NOT contain the implementer instruction.
  #
  # PRE-IMPL FAILURE: BriefAssembler.assemble/2 ignores the :role opt today
  # (no such opt supported). The test-author instruction section is absent, so
  # the assertions that the brief CONTAINS those instructions fail.
  # ---------------------------------------------------------------------------
  @tag :d_382
  test "D-382(a): assemble/2 with role: :test_author produces a brief containing the test-author instruction, the expected test/... path, and worktree context" do
    input = d382_input()

    result = BriefAssembler.assemble(input, role: :test_author)

    assert is_binary(result),
           "D-382(a): assemble/2 with role: :test_author must return a String.t(); " <>
             "got: #{inspect(result)}"

    # The brief must instruct the agent to WRITE the gating test.
    assert result =~ ~r/write.*gating test|gating test.*write/i,
           "D-382(a): role: :test_author brief must instruct the agent to WRITE the gating test; " <>
             "got brief: #{inspect(result)}"

    # The brief must name the expected test/... path (from gating_test_paths).
    assert result =~ "test/tau/factory/brief_assembler_role_test.exs",
           "D-382(a): role: :test_author brief must name the expected gating-test path; " <>
             "got brief: #{inspect(result)}"

    # The brief must reference that the agent is in a fresh isolated worktree.
    assert result =~ ~r/worktree|isolated worktree/i,
           "D-382(a): role: :test_author brief must reference the fresh isolated worktree context; " <>
             "got brief: #{inspect(result)}"

    # Must NOT contain the implementer instruction.
    refute result =~ ~r/implement.*satisfy.*gating test|satisfy.*gating test.*implement/i,
           "D-382(a): role: :test_author brief must NOT contain the implementer instruction; " <>
             "got brief: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-382(b): :implementer role → brief contains implementer instruction
  #           (implement to satisfy the gating test); does NOT contain the
  #           test-author instruction.
  #
  # PRE-IMPL FAILURE: BriefAssembler.assemble/2 ignores the :role opt today.
  # The implementer instruction section is absent, so the assertions fail.
  # ---------------------------------------------------------------------------
  @tag :d_382
  test "D-382(b): assemble/2 with role: :implementer produces a brief containing the implementer instruction and NOT the test-author instruction" do
    input = d382_input()

    result = BriefAssembler.assemble(input, role: :implementer)

    assert is_binary(result),
           "D-382(b): assemble/2 with role: :implementer must return a String.t(); " <>
             "got: #{inspect(result)}"

    # The brief must instruct the agent to IMPLEMENT the issue to satisfy the test.
    assert result =~
             ~r/implement.*satisfy.*gating test|satisfy.*gating test.*implement|implement.*gating test/i,
           "D-382(b): role: :implementer brief must instruct the agent to implement the issue " <>
             "to satisfy the gating test; got brief: #{inspect(result)}"

    # Must NOT contain the test-author-specific WRITE instruction.
    refute result =~ ~r/write.*gating test|gating test.*write/i,
           "D-382(b): role: :implementer brief must NOT contain the test-author write instruction; " <>
             "got brief: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-382(c): two roles produce DIFFERENT briefs for the same issue.
  #
  # PRE-IMPL FAILURE: BriefAssembler.assemble/2 ignores the :role opt today,
  # so both calls return the same role-agnostic brief — the assertion that
  # briefs differ fails.
  # ---------------------------------------------------------------------------
  @tag :d_382
  test "D-382(c): assemble/2 with role: :test_author and role: :implementer produce DIFFERENT briefs for the same issue" do
    input = d382_input()

    test_author_brief = BriefAssembler.assemble(input, role: :test_author)
    implementer_brief = BriefAssembler.assemble(input, role: :implementer)

    assert is_binary(test_author_brief),
           "D-382(c): assemble/2 must return a String.t() for role: :test_author"

    assert is_binary(implementer_brief),
           "D-382(c): assemble/2 must return a String.t() for role: :implementer"

    refute test_author_brief == implementer_brief,
           "D-382(c): assemble/2 must produce DIFFERENT briefs for role: :test_author vs " <>
             "role: :implementer — both roles returned the same role-agnostic brief, " <>
             "which means the :role opt is being ignored. " <>
             "test_author_brief=#{inspect(test_author_brief)}, " <>
             "implementer_brief=#{inspect(implementer_brief)}"
  end

  # ---------------------------------------------------------------------------
  # D-382(d): a brief built from an issue with a real body is actionable —
  #           the body content appears in the assembled brief, NOT "(none declared)".
  #
  # This gates the seeded dogfood issue enrichment: Sandbox currently has
  # @issue_title but no @issue_body. After the implementer lands D-382,
  # the sandbox must carry a real body so the brief for the seeded issue is
  # actionable rather than showing "(none declared)" for the body section.
  #
  # Here we test BriefAssembler.assemble/2 directly with a real body to confirm
  # the assembler renders it (not "(none declared)") regardless of :role.
  #
  # PRE-IMPL FAILURE: The current assembler already handles a non-empty body
  # correctly (renders body text, not "(none declared)"), so this test passes
  # TODAY against the existing assembler. It is included to gate the sandbox's
  # body enrichment via the Sandbox module's issue_body/0 accessor — which does
  # not exist yet. This test will fail until Sandbox.issue_body/0 is added.
  # ---------------------------------------------------------------------------
  @tag :d_382
  test "D-382(d): a brief for an issue with a real body is actionable — body content appears in the brief, not (none declared); and Sandbox.issue_body/0 must exist" do
    # The sandbox must expose the seeded issue body so the assembled brief for
    # the dogfood issue is actionable. This accessor does not exist today.
    sandbox_body = Sandbox.issue_body()

    assert is_binary(sandbox_body) and sandbox_body != "",
           "D-382(d): Tau.Factory.Dogfood.Sandbox.issue_body/0 must return a non-empty String.t(); " <>
             "got: #{inspect(sandbox_body)}"

    # Confirm the assembler renders a real body (not placeholder) for role: :implementer.
    input = %{
      issue:
        issue(
          Sandbox.issue_number(),
          Sandbox.issue_title(),
          body: sandbox_body
        ),
      declared_scope: empty_scope()
    }

    result = BriefAssembler.assemble(input, role: :implementer)

    refute result =~ "(none declared)" and result =~ sandbox_body,
           "D-382(d): brief for the seeded dogfood issue must contain the real body content " <>
             "(not '(none declared)'); got brief: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-382(e): role-threading via to_unit_work_item/1 — the oracle worker's
  #           assembled brief is the :test_author brief, and the implementing
  #           worker's brief is the :implementer brief.
  #
  # This tests the seam in Tau.Factory.Supervisor.to_unit_work_item/1.
  # Today, to_unit_work_item/1 calls BriefAssembler.assemble/2 with NO :role,
  # producing one role-agnostic brief for both workers.
  #
  # After D-382, to_unit_work_item/1 (or a role-carrying variant) must accept
  # a :role and pass it to BriefAssembler.assemble/2, so each worker's work_item
  # carries the appropriate brief.
  #
  # We test the observable seam: Tau.Factory.Supervisor.to_unit_work_item/2
  # (with an explicit role arg) must exist and produce role-specific :brief values.
  # If only the arity-1 form exists (no role threading), the call raises
  # UndefinedFunctionError — the correct pre-impl failure.
  #
  # PRE-IMPL FAILURE: Tau.Factory.Supervisor.to_unit_work_item/2 does not exist
  # → UndefinedFunctionError (or the 1-arity form exists but ignores role).
  # ---------------------------------------------------------------------------
  @tag :d_382
  test "D-382(e): Supervisor.to_unit_work_item/2 (or the role-threaded path) produces role-specific :brief values for :test_author vs :implementer" do
    issue_map = issue(517, "role-aware brief (#517)", body: "Real body for D-382.")

    scope = %{
      deps: [],
      files: MapSet.new(["lib/tau/factory/brief_assembler.ex"]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }

    branch = "unit-517"
    hash = "abc123"
    work_item = {issue_map, scope, hash, branch}

    # to_unit_work_item/2 must accept a :role arg (or an equivalent role-carrying
    # variant must exist). If the 2-arity form is absent today, this call raises
    # UndefinedFunctionError — the correct pre-impl failure.
    test_author_item = FactorySupervisor.to_unit_work_item(work_item, role: :test_author)
    implementer_item = FactorySupervisor.to_unit_work_item(work_item, role: :implementer)

    ta_brief = Map.get(test_author_item, :brief, :__missing__)
    impl_brief = Map.get(implementer_item, :brief, :__missing__)

    assert is_binary(ta_brief),
           "D-382(e): to_unit_work_item/2 with role: :test_author must set :brief to a String.t(); " <>
             "got: #{inspect(ta_brief)}"

    assert is_binary(impl_brief),
           "D-382(e): to_unit_work_item/2 with role: :implementer must set :brief to a String.t(); " <>
             "got: #{inspect(impl_brief)}"

    refute ta_brief == impl_brief,
           "D-382(e): to_unit_work_item/2 must produce DIFFERENT :brief values for " <>
             ":test_author vs :implementer — role is being ignored. " <>
             "test_author brief=#{inspect(ta_brief)}, implementer brief=#{inspect(impl_brief)}"

    # The test-author brief must contain the test-author instruction.
    assert ta_brief =~ ~r/write.*gating test|gating test.*write/i,
           "D-382(e): the :test_author brief from to_unit_work_item/2 must instruct writing " <>
             "the gating test; got brief: #{inspect(ta_brief)}"

    # The implementer brief must contain the implementer instruction.
    assert impl_brief =~
             ~r/implement.*satisfy.*gating test|satisfy.*gating test.*implement|implement.*gating test/i,
           "D-382(e): the :implementer brief from to_unit_work_item/2 must instruct " <>
             "implementing to satisfy the gating test; got brief: #{inspect(impl_brief)}"
  end
end

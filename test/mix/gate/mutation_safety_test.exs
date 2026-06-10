defmodule Mix.Gate.MutationSafetyTest do
  @moduledoc """
  Safety tests for the `try/after` restore guarantee in `Mix.Gate.Mutation`
  and the no-production-delta `:not_applicable` exemption.

  Verifies that `mutation_check_in` restores the working tree to its HEAD
  state unconditionally — covering both normal completion and scenarios where
  the working tree is modified before the check runs. This exercises the
  safety contract that closes the partial-revert gap noted in
  `.code_audit/00-synthesis.md` §9 finding #14.

  Also verifies Gate 5.3 returns `:not_applicable` when the PR's entire diff
  lies within the declared gating-test paths (test-only / docs-only change),
  fixing the false FAIL reported in issue #423.
  """
  use ExUnit.Case, async: false

  alias Mix.Gate.Mutation

  @moduletag tmp_dir: true

  # Build a minimal two-commit git repo under tmp_dir.
  # base commit: lib/widget.ex returns :base_value
  # HEAD commit: lib/widget.ex returns :head_value + gating test added
  setup %{tmp_dir: tmp_dir} do
    run = fn args -> {_, 0} = System.cmd("git", args, cd: tmp_dir) end

    run.(["init", "-q"])
    run.(["config", "user.email", "test@example.com"])
    run.(["config", "user.name", "Test"])

    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))

    prod = Path.join(tmp_dir, "lib/widget.ex")
    gating = Path.join(tmp_dir, "test/widget_gate_test.exs")

    File.write!(prod, "defmodule Widget do\n  def run, do: :base_value\nend\n")
    run.(["add", "-A"])
    run.(["commit", "-q", "-m", "base"])
    {base_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp_dir)
    base_ref = String.trim(base_ref)

    File.write!(prod, "defmodule Widget do\n  def run, do: :head_value\nend\n")

    File.write!(gating, """
    defmodule WidgetGateTest do
      use ExUnit.Case
      test "widget is at head value" do
        assert Widget.run() == :head_value
      end
    end
    """)

    run.(["add", "-A"])
    run.(["commit", "-q", "-m", "head"])

    {:ok, tmp_dir: tmp_dir, base_ref: base_ref, prod: prod, head_prod_content: File.read!(prod)}
  end

  test "after-block restore fires after normal completion — file returns to HEAD", %{
    tmp_dir: tmp_dir,
    base_ref: base_ref,
    prod: prod,
    head_prod_content: head_prod_content
  } do
    # Confirm starting state: HEAD content.
    assert File.read!(prod) =~ ":head_value"

    # Run mutation_check — reverts prod to base_ref during the check, then
    # must restore it to HEAD in the after block before returning.
    # File.cd! ensures locate_repo_for_gating_tests finds the repo directly
    # without the recursive fallback, preventing cross-test tmp_dir pollution.
    File.cd!(tmp_dir, fn ->
      _result = Mutation.mutation_check(["test/widget_gate_test.exs"], base_ref)
    end)

    # After mutation_check returns (any result), the file MUST be at HEAD.
    restored = File.read!(prod)

    assert restored == head_prod_content,
           "expected HEAD content after mutation_check, got: #{inspect(restored)}"
  end

  test "after-block restore fires when production file is missing before check", %{
    tmp_dir: tmp_dir,
    base_ref: base_ref,
    prod: prod,
    head_prod_content: head_prod_content
  } do
    # Record HEAD content before manipulation.
    assert File.read!(prod) =~ ":head_value"

    # Remove the production file from disk — it's still tracked in git.
    # The revert sequence attempts git checkout base_ref -- lib/widget.ex,
    # restoring the base content on disk. The after block then runs
    # git checkout HEAD -- lib/widget.ex to restore HEAD content.
    File.rm!(prod)

    File.cd!(tmp_dir, fn ->
      Mutation.mutation_check(["test/widget_gate_test.exs"], base_ref)
    end)

    # After the call, the file must be restored to HEAD.
    assert File.exists?(prod),
           "expected lib/widget.ex to be restored by the after block"

    restored = File.read!(prod)

    assert restored == head_prod_content,
           "expected HEAD content after restore, got: #{inspect(restored)}"
  end

  # Test for issue #423: Gate 5.3 must return :not_applicable (exit 0) when
  # the PR's entire diff lies within the declared gating-test paths — i.e.
  # a test-only or docs-only change with no production delta.
  #
  # Scenario: base commit has lib/widget.ex unchanged; HEAD only adds a new
  # gating test file. The only change between base_ref and HEAD is the gating
  # test itself. Reverting everything outside gating-test paths reverts nothing
  # — no production delta to mutate.
  test "returns :not_applicable when PR has no production delta outside gating-test paths (#423)",
       %{tmp_dir: tmp_dir} do
    # Build a fresh isolated repo inside tmp_dir/test_only_repo so it does
    # not share git history with the outer setup repo.
    repo = Path.join(tmp_dir, "test_only_repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))
    run = fn args -> {_, 0} = System.cmd("git", args, cd: repo) end

    run.(["init", "-q"])
    run.(["config", "user.email", "test@example.com"])
    run.(["config", "user.name", "Test"])

    # base commit: production file only (no gating test yet)
    prod = Path.join(repo, "lib/widget.ex")
    File.write!(prod, "defmodule Widget do\n  def run, do: :value\nend\n")
    run.(["add", "-A"])
    run.(["commit", "-q", "-m", "base"])
    {base_ref, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    base_ref = String.trim(base_ref)

    # HEAD commit: production file UNCHANGED; only a new gating test added.
    # This simulates a test-only PR where the implementer already shipped the
    # production code and this PR only adds the gating test.
    gating = Path.join(repo, "test/widget_gate_test.exs")

    File.write!(gating, """
    defmodule WidgetGateTest do
      use ExUnit.Case
      test "widget returns expected value" do
        assert Widget.run() == :value
      end
    end
    """)

    run.(["add", "-A"])
    run.(["commit", "-q", "-m", "add gating test only"])

    # Run mutation check with the gating test as the only declared path.
    # The production file (lib/widget.ex) is identical at base_ref and HEAD,
    # so there is no production delta to revert — gate must return :not_applicable.
    result =
      File.cd!(repo, fn ->
        Mutation.mutation_check(["test/widget_gate_test.exs"], base_ref)
      end)

    assert result == :not_applicable,
           "expected :not_applicable for test-only PR (no production delta), got: #{inspect(result)}"
  end
end

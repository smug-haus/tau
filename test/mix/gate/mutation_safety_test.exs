defmodule Mix.Gate.MutationSafetyTest do
  @moduledoc """
  Safety tests for the `try/after` restore guarantee in `Mix.Gate.Mutation`.

  Verifies that `mutation_check_in` restores the working tree to its HEAD
  state unconditionally — covering both normal completion and scenarios where
  the working tree is modified before the check runs. This exercises the
  safety contract that closes the partial-revert gap noted in
  `.code_audit/00-synthesis.md` §9 finding #14.
  """
  use ExUnit.Case, async: true

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
end

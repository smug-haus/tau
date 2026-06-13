defmodule Tau.Factory.Dogfood.Sandbox do
  @moduledoc """
  Sandbox seeding helpers for the `mix tau.factory.dogfood` harness.

  Seeds a trivial issue + real gating test into the dogfood sandbox working
  repo. The seeded issue is: *add `Sandbox.answer/0` returning `42`*, with a
  real gating test asserting `Sandbox.answer() == 42`.

  The scripted `agent_bin` then produces the production implementation
  (`lib/sandbox.ex`) and commits it on the feature branch. Gate 5.3 mutation
  genuinely fires: the gating test fails on the reverted tree (no `answer/0`)
  and passes on the real tree.

  This module is a pure functional module — no GenServer, no process state
  (OTP non-negotiable #3). All operations are `System.cmd` / `File.*` calls
  against the given `work_path`.
  """

  @issue_title "add Sandbox.answer/0 returning 42"
  @issue_number 1

  @doc "The fixed issue number (always 1 in the dogfood harness)."
  @spec issue_number() :: integer()
  def issue_number, do: @issue_number

  @doc "The fixed issue title used to seed the dogfood sandbox."
  @spec issue_title() :: String.t()
  def issue_title, do: @issue_title

  @doc """
  The gating-test relative path that Gate 5.3 mutation uses.

  Frozen at scope-freeze; passed as `frozen_paths` in `%Gate.Request{}`.
  """
  @spec gating_test_path() :: String.t()
  def gating_test_path, do: "test/sandbox_test.exs"

  @doc """
  Seed the sandbox working repo with the mix project scaffold, the seeded
  gating test, and the feature branch.

  After seeding:
    - `origin/main` carries the scaffold + gating test.
    - Branch `unit-1` exists in `work_path`, pointing to the same commit as
      `main` (the base the worker builds on).

  The agent_bin then writes `lib/sandbox.ex` onto the `unit-1` branch.

  Returns `:ok` on success; raises on failure.
  """
  @spec seed(String.t()) :: :ok
  def seed(work_path) do
    git = fn args ->
      case System.cmd("git", args, cd: work_path, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, code} -> raise "git #{inspect(args)} failed (exit #{code}): #{out}"
      end
    end

    # Write the mix.exs scaffold so Health.check (mix compile + mix test) passes
    # after the agent commits the production file.
    write_mix_exs(work_path)

    # test/test_helper.exs — required for mix test.
    write_test_helper(work_path)

    # Seed the gating test: asserts Sandbox.answer() == 42.
    # This is the frozen gating-test path; it must exist at merge_base so
    # Gate 5.3 can restore it after reverting the production file.
    write_gating_test(work_path)

    # Commit everything on main, then push to origin.
    git.(["add", "."])
    git.(["commit", "-m", "seed sandbox project + gating test"])
    git.(["push", "origin", "main"])

    # Create branch unit-1 (the feature branch the worker checks out).
    git.(["checkout", "-b", "unit-1"])
    git.(["push", "origin", "unit-1"])

    # Return to main so the repo_dir stays on main (WorkspaceJanitor invariant).
    git.(["checkout", "main"])

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private — file content
  # ---------------------------------------------------------------------------

  defp write_mix_exs(work_path) do
    content = """
    defmodule Sandbox.MixProject do
      use Mix.Project

      def project do
        [
          app: :sandbox,
          version: "0.1.0",
          elixir: "~> 1.14",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """

    File.mkdir_p!(work_path)
    File.write!(Path.join(work_path, "mix.exs"), content)
    File.mkdir_p!(Path.join(work_path, "lib"))
    File.mkdir_p!(Path.join(work_path, "test"))
  end

  defp write_test_helper(work_path) do
    File.write!(Path.join(work_path, "test/test_helper.exs"), "ExUnit.start()\n")
  end

  defp write_gating_test(work_path) do
    content = """
    defmodule SandboxTest do
      use ExUnit.Case, async: true

      @moduletag :ac_12
      @moduletag :d_358

      test "Sandbox.answer/0 returns 42" do
        assert Sandbox.answer() == 42
      end
    end
    """

    File.write!(Path.join(work_path, gating_test_path()), content)
  end
end

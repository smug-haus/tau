defmodule Tau.Factory.SkipPermissionsD383Test do
  @moduledoc """
  Gating tests for PR #520 (issue #519 — D-383: headless skip-permissions
  for the autonomous `:claude_code` agent).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  All tests MUST FAIL against the current branch because neither
  `skip_permissions` field nor `--dangerously-skip-permissions` are wired
  anywhere yet.

  ## D-383 invariant

  The `:claude_code` adapter's headless permission posture is a single
  opt-in boolean `task.skip_permissions` (default `false`):

    - `skip_permissions: true`  → `Argv.build/2` argv contains
      `"--dangerously-skip-permissions"`.
    - absent / `false`          → argv does NOT contain it (interactive
      default preserved).

  Factory threading:
    - `AgentBin.resolve(agent_mode: :claude_code, skip_permissions: true)`
      → the CodingAgentShim encoded config carries `skip_permissions: true`.
    - `AgentBin.resolve(agent_mode: :claude_code)` (no skip opt)
      → encoded config `skip_permissions: false` (or key absent treated as false).
    - Non-`:claude_code` modes: `skip_permissions` irrelevant; no flag.

  Back-compat: a task built without `:skip_permissions` (non-factory caller)
  → no flag.

  ## Gating-test path

  `test/tau/factory/skip_permissions_d383_test.exs`

  ## AC / D-NNN linkage

  All tests carry `@tag :d_383`.
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgents.ClaudeCode.Argv
  alias Tau.Factory.AgentBin

  # ---------------------------------------------------------------------------
  # Layer 1 — Argv mapping
  # Tests that Argv.build/2 emits / omits --dangerously-skip-permissions
  # based solely on task.skip_permissions.  No subprocess is spawned.
  # ---------------------------------------------------------------------------

  describe "D-383 Argv mapping" do
    @tag :d_383
    test "D-383 argv: skip_permissions: true appends --dangerously-skip-permissions" do
      task = %{prompt: "p", workspace: "/tmp", skip_permissions: true}
      argv = Argv.build(task)

      assert "--dangerously-skip-permissions" in argv,
             "D-383: Argv.build/2 with skip_permissions: true must include " <>
               "--dangerously-skip-permissions; got #{inspect(argv)}"
    end

    @tag :d_383
    test "D-383 argv: skip_permissions: false does NOT append --dangerously-skip-permissions" do
      task = %{prompt: "p", workspace: "/tmp", skip_permissions: false}
      argv = Argv.build(task)

      refute "--dangerously-skip-permissions" in argv,
             "D-383: Argv.build/2 with skip_permissions: false must NOT include " <>
               "--dangerously-skip-permissions; got #{inspect(argv)}"
    end

    @tag :d_383
    test "D-383 argv back-compat: task without :skip_permissions key does NOT append --dangerously-skip-permissions" do
      task = %{prompt: "p", workspace: "/tmp"}
      argv = Argv.build(task)

      refute "--dangerously-skip-permissions" in argv,
             "D-383: Argv.build/2 with no :skip_permissions key must NOT include " <>
               "--dangerously-skip-permissions (back-compat); got #{inspect(argv)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 2 — Factory wiring
  # Tests that AgentBin.resolve/1 threads skip_permissions: true into the
  # CodingAgentShim encoded config, and that the config decodes correctly.
  # Mirrors the decode pattern from test/tau/factory/agent_bin_test.exs.
  # ---------------------------------------------------------------------------

  describe "D-383 factory wiring via AgentBin.resolve/1" do
    @tag :d_383
    test "D-383 wiring: resolve(agent_mode: :claude_code, skip_permissions: true) bakes skip_permissions: true into shim config" do
      opts = [agent_mode: :claude_code, skip_permissions: true, branch: "feat/test-d-383"]

      {agent_bin_path, _spawn_opts} = AgentBin.resolve(opts)

      assert is_binary(agent_bin_path),
             "D-383: AgentBin.resolve/1 must return {String.t(), keyword()}"

      assert File.exists?(agent_bin_path),
             "D-383: agent_bin_path #{agent_bin_path} must exist on disk"

      script = File.read!(agent_bin_path)

      assert [_, encoded_config] =
               Regex.run(~r/encoded = \\"([A-Za-z0-9+\/]+)\\"/, script),
             "D-383: shim script must contain a baked base64-encoded config; " <>
               "head=#{String.slice(script, 0, 200)}"

      decoded_config =
        encoded_config
        |> Base.decode64!(padding: false)
        |> :erlang.binary_to_term()

      assert decoded_config[:skip_permissions] == true,
             "D-383: decoded shim config must carry skip_permissions: true; " <>
               "got #{inspect(decoded_config)}"

      File.rm(agent_bin_path)
    end

    @tag :d_383
    test "D-383 wiring: resolve(agent_mode: :claude_code) without skip opt → decoded config skip_permissions is false or absent" do
      opts = [agent_mode: :claude_code, branch: "feat/test-d-383-absent"]

      {agent_bin_path, _spawn_opts} = AgentBin.resolve(opts)

      script = File.read!(agent_bin_path)

      assert [_, encoded_config] =
               Regex.run(~r/encoded = \\"([A-Za-z0-9+\/]+)\\"/, script),
             "D-383: shim script must contain a baked base64-encoded config"

      decoded_config =
        encoded_config
        |> Base.decode64!(padding: false)
        |> :erlang.binary_to_term()

      # skip_permissions absent or false both satisfy D-383 back-compat
      actual = Map.get(decoded_config, :skip_permissions, false)

      refute actual == true,
             "D-383: decoded shim config without skip opt must NOT carry " <>
               "skip_permissions: true; got #{inspect(decoded_config)}"

      File.rm(agent_bin_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 3 — Back-compat for non-factory callers
  # A non-`:claude_code` resolve call must not carry skip_permissions: true,
  # and the absent-key Argv.build path is already covered in Layer 1.
  # ---------------------------------------------------------------------------

  describe "D-383 back-compat for non-factory paths" do
    @tag :d_383
    test "D-383 back-compat: resolve(agent_mode: :scripted) does not thread skip_permissions into spawn_opts" do
      opts = [agent_mode: :scripted, skip_permissions: true]

      {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

      refute Keyword.get(spawn_opts, :skip_permissions) == true,
             "D-383: :scripted mode MUST NOT propagate skip_permissions: true " <>
               "into spawn_opts; got #{inspect(spawn_opts)}"
    end

    @tag :d_383
    test "D-383 back-compat: absent agent_mode with skip_permissions: true does not activate the flag in spawn_opts" do
      opts = [skip_permissions: true]

      {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

      refute Keyword.get(spawn_opts, :skip_permissions) == true,
             "D-383: default (absent agent_mode) MUST NOT propagate skip_permissions: true " <>
               "into spawn_opts; got #{inspect(spawn_opts)}"
    end
  end
end

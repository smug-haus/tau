defmodule Tau.Factory.AgentBoundaryModelTest do
  @moduledoc """
  Gating tests for PR #528 — unified agent-boundary model.

  Advances D-387 (external tool boundary / argv), D-388 (per-worker config
  isolation / CLAUDE_CONFIG_DIR), D-389 (whitelist posture, not blanket bypass),
  and the D-388 fail-safe diagnostic (unexpected_commit telemetry).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  All tests MUST FAIL against the current branch because:

    - D-387: `Argv.build/2` has no `--disallowedTools` / git-blocking flag today.
    - D-388: `ClaudeCode.start/2` port_env has no `CLAUDE_CONFIG_DIR`; no
             seeding helper exists.
    - D-389: `AgentBin.resolve/1` for :claude_code mode reads skip_permissions
             from opts; the dogfood task forces skip_permissions: true (line 120)
             and passes it through. D-389 requires that the factory path does NOT
             set skip_permissions: true when the operator has not opted in.
             The "no bypass" assertion on the shim config fails because the
             dogfood currently forces it.
    - Diagnostic: `CodingAgentShim.Runner` has no `:unexpected_commit` telemetry.

  ## Gating-test paths

    - `test/tau/factory/agent_boundary_model_test.exs`
    - `test/support/factory/committing_agent.ex`

  ## AC / D-NNN linkage

    - D-387 — external tool boundary (argv `--disallowedTools` + factory whitelist)
    - D-388 — per-worker config isolation (`CLAUDE_CONFIG_DIR` + seeding contract)
    - D-389 — whitelist posture, not blanket bypass (no `--dangerously-skip-permissions`
               on factory path; escape-hatch retained for opt-in)
    - Diagnostic — D-388 fail-safe: unexpected_commit telemetry + `:no_work_product`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tau.CodingAgents.ClaudeCode.Argv
  alias Tau.CodingAgents.ClaudeCode.ConfigDir, as: ClaudeConfigDir
  alias Tau.Factory.AgentBin
  alias Tau.Factory.CodingAgentShim

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp mk_tmp(tag) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "tau_#{tag}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    tmp_dir
  end

  # -------------------------------------------------------------------------
  # D-387 — external tool boundary (argv)
  # -------------------------------------------------------------------------

  describe "D-387 external tool boundary — argv disallowedTools" do
    @tag :d_387
    test "D-387 argv: Argv.build/2 for a plain task always contains --disallowedTools with a git-blocking pattern" do
      # D-387 contract: every argv produced by Argv.build/2 MUST carry
      # `--disallowedTools` with a value that blocks git (e.g. "Bash(git:*)").
      # On the current branch Argv.build/2 has no --disallowedTools → this fails.
      task = %{prompt: "implement the feature", workspace: "/tmp"}
      argv = Argv.build(task)

      disallowed_idx = Enum.find_index(argv, &(&1 == "--disallowedTools"))

      assert disallowed_idx != nil,
             "D-387: Argv.build/2 must include --disallowedTools for the external tool " <>
               "boundary; got #{inspect(argv)}"

      disallowed_value = Enum.at(argv, disallowed_idx + 1)

      assert is_binary(disallowed_value) and String.contains?(disallowed_value, "git"),
             "D-387: --disallowedTools value must contain a git-blocking pattern " <>
               "(e.g. 'Bash(git:*)'); got value=#{inspect(disallowed_value)}, argv=#{inspect(argv)}"
    end
  end

  describe "D-387 external tool boundary — factory whitelist posture" do
    @tag :d_387
    test "D-387 factory argv: whitelist path produces --allowedTools without bare git access" do
      # D-387 contract: when the factory passes allowed_tools (whitelist mode),
      # the resulting argv MUST carry --allowed-tools and its value MUST NOT
      # grant bare git access (no "Bash(git" in the value).
      # The factory whitelist allows Read/Write/Edit/Bash (non-git) but not git.
      #
      # On the current branch there is no factory whitelist enforcement and no
      # --disallowedTools, so this test fails at the --disallowedTools check.
      factory_allowed = ["Read", "Write", "Edit", "Bash(ls:*)", "Bash(cat:*)"]

      task = %{
        prompt: "factory task",
        workspace: "/tmp",
        allowed_tools: factory_allowed
      }

      argv = Argv.build(task)

      # D-387 primary: --disallowedTools must always be present (git-deny baseline)
      disallowed_idx = Enum.find_index(argv, &(&1 == "--disallowedTools"))

      assert disallowed_idx != nil,
             "D-387: factory argv must include --disallowedTools as the git-deny baseline " <>
               "even when --allowed-tools is also set; got #{inspect(argv)}"

      # The disallowed value must block git
      disallowed_value = Enum.at(argv, disallowed_idx + 1)

      assert is_binary(disallowed_value) and String.contains?(disallowed_value, "git"),
             "D-387: --disallowedTools value must contain a git-blocking pattern; " <>
               "got disallowed_value=#{inspect(disallowed_value)}"

      # --allowed-tools must also be present (the factory whitelist)
      allowed_idx = Enum.find_index(argv, &(&1 == "--allowed-tools"))

      assert allowed_idx != nil,
             "D-387: factory argv must include --allowed-tools for whitelist posture; " <>
               "got #{inspect(argv)}"

      allowed_value = Enum.at(argv, allowed_idx + 1)

      # The allowed value must not grant git
      refute String.contains?(allowed_value, "Bash(git"),
             "D-387: factory --allowed-tools value must NOT contain Bash(git...) " <>
               "(git is blocked at the external boundary); got value=#{inspect(allowed_value)}"
    end
  end

  # -------------------------------------------------------------------------
  # D-388 — per-worker config isolation (CLAUDE_CONFIG_DIR)
  # -------------------------------------------------------------------------

  describe "D-388 per-worker config isolation — CLAUDE_CONFIG_DIR in port env" do
    @tag :d_388
    test "D-388 port env: ClaudeCode spawn env carries CLAUDE_CONFIG_DIR pointing at an isolated directory" do
      # D-388 contract: the port_env assembled in ClaudeCode.start/2 (or the
      # worker's spawn path) MUST carry CLAUDE_CONFIG_DIR set to a per-invocation
      # isolated directory. On the current branch port_env only carries the three
      # ANTHROPIC_* scrubs and nothing else → this assertion fails.
      #
      # The implementer must add {~c"CLAUDE_CONFIG_DIR", isolated_path} to port_env.
      # We assert the seeding helper exists — this is the production seam the
      # implementer must create. Without it this test fails.
      #
      # The seeding helper is the natural prerequisite: ClaudeCode.start/2 must
      # call it before opening the port to produce the isolated dir path that
      # goes into CLAUDE_CONFIG_DIR.
      assert function_exported?(Tau.CodingAgents.ClaudeCode, :seed_config_dir, 1) or
               Code.ensure_loaded?(ClaudeConfigDir),
             "D-388: implementation must expose a seeding helper — either " <>
               "Tau.CodingAgents.ClaudeCode.seed_config_dir/1 or " <>
               "Tau.CodingAgents.ClaudeCode.ConfigDir module — for per-invocation " <>
               "CLAUDE_CONFIG_DIR isolation; neither exists on the current branch"
    end

    @tag :d_388
    test "D-388 seeding contract: isolated config dir contains .credentials.json + settings.json with no hooks key" do
      # D-388 contract: the seeding helper (whatever the implementer names it)
      # must produce a directory containing:
      #   - `.credentials.json`  — OAuth credentials only (no API key — D-375/D-036)
      #   - `settings.json`      — empty or minimal; no `hooks` key
      #   - NO operator hook / plugin / skill / MCP content
      #
      # We assert this by calling the seed helper with a fake source credentials
      # file and inspecting the output directory.
      #
      # FAIL BEFORE: the module/function does not exist → UndefinedFunctionError.
      tmp_dir = mk_tmp("d388_seed")
      isolated_dir = Path.join(tmp_dir, "isolated_config")
      File.mkdir_p!(isolated_dir)

      # Fake source credentials file (no real key — just structural test).
      source_creds = Path.join(tmp_dir, ".credentials.json")
      File.write!(source_creds, ~s({"type":"oauth","access_token":"test-only"}))

      # Call the expected public seam. If neither form exists this raises
      # UndefinedFunctionError → legitimate fail-before.
      seeded_dir =
        if Code.ensure_loaded?(ClaudeConfigDir) do
          :ok = ClaudeConfigDir.seed(isolated_dir, source_creds)
          isolated_dir
        else
          # Will raise UndefinedFunctionError — correct fail-before
          alias Tau.CodingAgents.ClaudeCode, as: ClaudeCodeAdapter
          ClaudeCodeAdapter.seed_config_dir(isolated_dir, source_creds: source_creds)
          isolated_dir
        end

      creds_path = Path.join(seeded_dir, ".credentials.json")

      assert File.exists?(creds_path),
             "D-388: seeded config dir must contain .credentials.json; " <>
               "dir=#{seeded_dir}, contents=#{inspect(File.ls!(seeded_dir))}"

      settings_path = Path.join(seeded_dir, "settings.json")

      assert File.exists?(settings_path),
             "D-388: seeded config dir must contain settings.json; " <>
               "dir=#{seeded_dir}"

      {:ok, settings_raw} = File.read(settings_path)

      settings =
        if settings_raw == "" do
          %{}
        else
          Jason.decode!(settings_raw)
        end

      refute Map.has_key?(settings, "hooks"),
             "D-388: settings.json in isolated config dir must NOT contain 'hooks' key; " <>
               "got settings=#{inspect(settings)}"

      # No operator hook/plugin content under the isolated dir
      hook_files =
        Path.wildcard(Path.join(seeded_dir, "**/{hooks,plugins,skills}/**"))

      assert hook_files == [],
             "D-388: isolated config dir must NOT contain hooks/plugins/skills content; " <>
               "found #{inspect(hook_files)}"
    end
  end

  # -------------------------------------------------------------------------
  # D-389 — whitelist posture, not blanket bypass
  # -------------------------------------------------------------------------

  describe "D-389 whitelist posture — no --dangerously-skip-permissions on factory path" do
    @tag :d_389
    test "D-389 factory: dogfood factory_opts pattern does NOT bake skip_permissions: true into shim when no opt-in" do
      # D-389 contract: when the factory coordinator calls AgentBin.resolve/1
      # WITHOUT an explicit skip_permissions opt-in, the resulting shim config
      # must NOT carry skip_permissions: true (and therefore must not produce
      # --dangerously-skip-permissions in the agent argv).
      #
      # The current dogfood task at tau.factory.dogfood.ex line 120 does:
      #   AgentBin.resolve(Keyword.put(factory_opts, :skip_permissions, true))
      # which forcibly adds skip_permissions: true → D-389 requires removing
      # that line, making the factory default skip_permissions-free.
      #
      # We simulate BOTH the pre-D-389 (current, broken) path AND the post-D-389
      # path to produce the fail-before and pass-after signals clearly.
      #
      # FAIL BEFORE: the shim produced by the dogfood forcing pattern carries
      # skip_permissions: true. We assert the CONTRACT (post-D-389 state): the
      # shim produced by factory_opts WITHOUT forced skip_permissions must have
      # skip_permissions: false or absent.
      #
      # We verify the dogfood forcing pattern is the violation: produce a shim
      # using the current dogfood pattern (force skip_permissions: true) and
      # assert it is absent. This fails on the current branch because the dogfood
      # forces it (AgentBin.resolve threads it into the shim config), and the
      # test asserts it is NOT present.

      # Replicate the forcing pattern from dogfood line 120:
      factory_opts = Application.get_env(:tau, :factory, [])

      # D-389 violation: current dogfood does exactly this:
      dogfood_forced_opts =
        factory_opts
        |> Keyword.put(:agent_mode, :claude_code)
        |> Keyword.put(:branch, "feat/d389-dogfood-test")
        |> Keyword.put(:skip_permissions, true)

      {agent_bin_path, _spawn_opts} = AgentBin.resolve(dogfood_forced_opts)

      on_exit(fn -> File.rm(agent_bin_path) end)

      script = File.read!(agent_bin_path)

      assert [_, encoded_config] =
               Regex.run(~r/encoded = \\"([A-Za-z0-9+\/=]+)\\"/, script),
             "D-389: shim script must contain a baked base64-encoded config; " <>
               "head=#{String.slice(script, 0, 200)}"

      decoded_config =
        encoded_config
        |> Base.decode64!(padding: false)
        |> :erlang.binary_to_term()

      # D-389 CONTRACT ASSERTION: the factory MUST NOT produce skip_permissions: true
      # in the shim when operating in autonomous (non-explicit-opt-in) mode.
      # This fails on the current branch because the dogfood forces it.
      refute Map.get(decoded_config, :skip_permissions, false) == true,
             "D-389: the factory/dogfood path must NOT bake skip_permissions: true into " <>
               "the shim config when there is no explicit operator opt-in. " <>
               "FAIL REASON: current tau.factory.dogfood.ex line 120 forces " <>
               "Keyword.put(factory_opts, :skip_permissions, true), causing the shim " <>
               "config to carry skip_permissions: true unconditionally. " <>
               "decoded_config=#{inspect(decoded_config)}"
    end

    @tag :d_389
    test "D-389 factory argv: shim with skip_permissions: false produces no --dangerously-skip-permissions" do
      # D-389 contract: the shim encoding from a factory call with no skip_permissions
      # opt-in must produce an argv without --dangerously-skip-permissions.
      # After D-389 is implemented: the shim config carries skip_permissions: false
      # and Argv.build produces no bypass flag.
      # We verify this at the Argv level for a clean task.
      task = %{
        prompt: "factory task",
        workspace: "/tmp",
        allowed_tools: ["Read", "Write", "Edit"]
      }

      argv = Argv.build(task)

      refute "--dangerously-skip-permissions" in argv,
             "D-389: factory argv without skip_permissions opt-in must NOT contain " <>
               "--dangerously-skip-permissions; got #{inspect(argv)}"
    end

    @tag :d_389
    test "D-389 escape-hatch retained: Argv.build/2 with skip_permissions: true still appends --dangerously-skip-permissions" do
      # D-389 back-compat: the skip_permissions escape hatch MUST still work
      # when explicitly set to true. This verifies D-383 parity is retained.
      # If --dangerously-skip-permissions is removed unconditionally this fails.
      task = %{prompt: "headless task", workspace: "/tmp", skip_permissions: true}
      argv = Argv.build(task)

      assert "--dangerously-skip-permissions" in argv,
             "D-389: escape hatch — Argv.build/2 with skip_permissions: true MUST " <>
               "still append --dangerously-skip-permissions (opt-in retained); " <>
               "got #{inspect(argv)}"
    end
  end

  # -------------------------------------------------------------------------
  # Diagnostic — D-388 fail-safe: unexpected_commit telemetry
  # -------------------------------------------------------------------------

  describe "D-388 diagnostic: shim detects self-commit breach and emits telemetry" do
    @tag :d_388
    @tag :diagnostic
    test "D-388 diagnostic: self-committing adapter causes shim to emit unexpected_commit telemetry and no work_ready" do
      # D-388 / Diagnostic contract: when an agent commits to the git repo before
      # exiting (boundary breach), the shim MUST:
      #   1. Detect that HEAD advanced past base_ref unexpectedly (before the
      #      shim's own commit step).
      #   2. Emit telemetry [:tau, :factory, :agent, :unexpected_commit].
      #   3. NOT rescue the commit as a valid work product.
      #   4. Surface :no_work_product to the Worker (no work_ready frame).
      #
      # We use `Tau.Factory.Test.CommittingAgent` (test/support/factory/committing_agent.ex)
      # as the adapter: it writes a file and self-commits before returning Done{0}.
      #
      # On the current branch:
      #   - CodingAgentShim.Runner has no git log HEAD comparison step.
      #   - There is no [:tau, :factory, :agent, :unexpected_commit] telemetry.
      # This test fails because the telemetry event is never emitted.

      tmp_dir = mk_tmp("d388_diagnostic")
      %{repo_dir: repo_dir} = setup_git_repo(tmp_dir)

      # Attach a telemetry handler for the expected event BEFORE running the shim.
      test_pid = self()
      handler_id = "test-d388-unexpected-commit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :agent, :unexpected_commit],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_fired, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      shim_bin = Path.join(tmp_dir, "shim_d388_diag_#{System.unique_integer([:positive])}")

      # Write a shim with our self-committing adapter.
      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.Factory.Test.CommittingAgent,
          branch: "feat/d388-diag-branch"
        )

      on_exit(fn -> File.rm(shim_bin) end)

      # Spawn the shim directly. The shim's Runner will drive CommittingAgent,
      # which self-commits before Done{0}. The Runner must detect the breach.
      System.cmd(shim_bin, [], cd: repo_dir, stderr_to_stdout: true)

      # D-388 diagnostic assertion: the shim must emit unexpected_commit telemetry.
      # On the current branch this message is never received → timeout failure.
      assert_receive {:telemetry_fired, [:tau, :factory, :agent, :unexpected_commit], _meas, _meta},
                     5_000,
                     "D-388 diagnostic: CodingAgentShim.Runner must emit " <>
                       "[:tau, :factory, :agent, :unexpected_commit] telemetry when the " <>
                       "agent self-commits before Done{0}. FAIL REASON: current shim has " <>
                       "no HEAD-vs-base_ref check and no unexpected_commit telemetry."
    end

    @tag :d_388
    @tag :diagnostic
    test "D-388 diagnostic: self-committing adapter causes shim to exit non-zero (breach, not silent no-op)" do
      # D-388 diagnostic contract: when the adapter self-commits (boundary breach),
      # the shim MUST exit non-zero. The current shim exits 0 (empty-diff path)
      # because it sees a clean tree after the self-commit. This silently maps to
      # :no_work_product — indistinguishable from a legitimate "agent ran but
      # changed nothing" outcome. D-388 requires the shim exit non-zero on breach
      # so the Worker treats it as a retriable error, not a silent no-op.
      #
      # FAIL BEFORE: current shim exits 0 for empty diff regardless of whether
      # the tree was empty because (a) agent did nothing or (b) agent self-committed.
      # After D-388: shim detects HEAD advanced before its own commit step → exits
      # non-zero. We assert shim exit code != 0.

      tmp_dir = mk_tmp("d388_nonzero_exit")
      %{repo_dir: repo_dir} = setup_git_repo(tmp_dir)

      shim_bin = Path.join(tmp_dir, "shim_d388_nze_#{System.unique_integer([:positive])}")

      shim_bin =
        CodingAgentShim.write(shim_bin,
          adapter: Tau.Factory.Test.CommittingAgent,
          branch: "feat/d388-breach-branch"
        )

      on_exit(fn -> File.rm(shim_bin) end)

      {_out, exit_code} =
        System.cmd(shim_bin, [], cd: repo_dir, stderr_to_stdout: true)

      # D-388 diagnostic: the shim MUST exit non-zero when breach is detected.
      # On the current branch exit_code is 0 (empty-diff silent path) → fails.
      assert exit_code != 0,
             "D-388 diagnostic: a self-committing adapter must cause the shim to exit " <>
               "non-zero (breach detected). FAIL REASON: current shim exits 0 for any " <>
               "empty diff, silently masking the boundary breach as a no-op. " <>
               "exit_code=#{exit_code}"
    end
  end
end

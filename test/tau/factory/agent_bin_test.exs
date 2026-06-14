defmodule Tau.Factory.AgentBinTest do
  @moduledoc """
  Gating tests for PR #512 (issue #511 — AgentBin selector, D-376).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  All tests MUST FAIL against the current branch because:
    - `Tau.Factory.AgentBin` does not exist yet.
    - Calling `Tau.Factory.AgentBin.resolve/1` raises `UndefinedFunctionError`.

  ## Contract under test (D-376)

  `Tau.Factory.AgentBin.resolve/1` reads `config :tau, :factory, agent_mode`
  and returns `{agent_bin_path, spawn_opts}`:

    - `:claude_code` → the written shim's baked config names
      `Tau.CodingAgents.ClaudeCode` as the adapter, AND the returned
      spawn_opts carry `agent_mode: :claude_code`.

    - `:scripted` / `:replay` / absent → resolves to the prior agent_bin shape
      (Replay shim / scripted binary), and the returned spawn_opts do NOT
      contain `agent_mode: :claude_code`.

  `resolve/1` accepts a keyword list of options (typically forwarding
  `Application.get_env(:tau, :factory, [])`) so tests can inject the
  config without mutating persistent application state.

  ## Pinned interface (oracle-declared; implementer MUST conform)

      Tau.Factory.AgentBin.resolve(opts :: keyword()) ::
        {agent_bin_path :: String.t(), spawn_opts :: keyword()}

    where `opts` may carry:
      - `:agent_mode` — atom; selects the agent bin variant. When absent
                        (or any non-`:claude_code` atom) the prior behaviour
                        is used. `:claude_code` activates real-agent mode.
      - `:branch`     — String; required; forwarded to the shim (branch to
                        commit to). SPEC gap: if the implementer requires
                        additional options, they MUST be documented in
                        SPEC-FACTORY-FLEET §4 B4-A1 before landing.

  ## AC / D-NNN linkage

  All tests carry `@tag :d_376`.

  ## REFINE addition (PR #512 gate finding)

  The gate found that `resolve/1` is an ORPHANED FENCE: the dogfood caller at
  `lib/mix/tasks/tau.factory.dogfood.ex:116` does `{agent_bin, _spawn_opts}` —
  dropping spawn_opts — and `lib/tau/factory/unit_driver.ex:177-183` builds
  worker_fun opts with no `agent_mode:`. The D-374 preflight (`preflight_metered`)
  in `Tau.Factory.Worker` is therefore NEVER reached for `:claude_code` mode.

  Test `d_376_e2e_claude_code_worker_fires_d374_preflight` (see below) closes
  this gap: it drives `UnitDriver.drive/2` with `agent_mode: :claude_code` and a
  stub `creds_check_fun` returning `{:error, :subscription_creds_absent}`.

  - Current (buggy): UnitDriver ignores `agent_mode:` from deps → worker spawns
    with no `agent_mode:` → preflight skipped → slow bin blocks → state_timeout
    fires → unit escalates with `:E_WORKER_STALLED`. The assertion for
    `reason: :E_WORKER_ERROR` FAILS → correct fail-before.

  - After fix: UnitDriver threads `agent_mode: :claude_code` + `creds_check_fun:`
    into spawn opts → `preflight_metered(:claude_code, creds_fn)` fires →
    `creds_fn.()` returns `{:error, :subscription_creds_absent}` →
    `WorkerSupervisor.spawn/5` returns `{:error, :metered_path_refused}` →
    worker_fun returns `{:error, :metered_path_refused}` → Unit escalates with
    `:E_WORKER_ERROR`. Test PASSES.
  """

  use ExUnit.Case, async: false

  alias Tau.CodingAgents.ClaudeCode
  alias Tau.Factory.AgentBin
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitDriver
  alias Tau.Factory.UnitSupervisor
  alias Tau.Factory.WorkerRegistry
  alias Tau.Factory.WorkerSupervisor
  alias Tau.Factory.WorkspaceJanitor

  @tag :d_376
  test "D-376: :claude_code mode — resolve/1 returns a shim whose adapter is Tau.CodingAgents.ClaudeCode" do
    tmp_dir = System.tmp_dir!()
    opts = [agent_mode: :claude_code, branch: "feat/test-d-376"]

    {agent_bin_path, _spawn_opts} = AgentBin.resolve(opts)

    assert is_binary(agent_bin_path),
           "D-376: resolve/1 must return a {String.t(), keyword()} tuple; got agent_bin_path=#{inspect(agent_bin_path)}"

    assert File.exists?(agent_bin_path),
           "D-376: agent_bin_path #{agent_bin_path} must exist on disk"

    script = File.read!(agent_bin_path)

    # Extract the base64-encoded config baked into the shim script.
    # Tau.Factory.CodingAgentShim.write/2 embeds the config as:
    # encoded = %{...} |> :erlang.term_to_binary() |> Base.encode64(padding: false)
    # and writes it into the script as:   encoded = "<base64_string>"
    assert [_, encoded_config] = Regex.run(~r/encoded = \\"([A-Za-z0-9+\/]+=*)\\"/, script),
           "D-376: script must contain a baked base64-encoded config; script head=#{String.slice(script, 0, 200)}"

    decoded_config =
      encoded_config
      |> Base.decode64!(padding: false)
      |> :erlang.binary_to_term()

    assert decoded_config.adapter == ClaudeCode,
           "D-376: :claude_code shim adapter must be Tau.CodingAgents.ClaudeCode, got #{inspect(decoded_config.adapter)}"

    # Cleanup
    File.rm(agent_bin_path)
    _ = tmp_dir
  end

  @tag :d_376
  test "D-376: :claude_code mode — resolve/1 spawn_opts carry agent_mode: :claude_code" do
    opts = [agent_mode: :claude_code, branch: "feat/test-d-376-spawn-opts"]

    {agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    assert Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: spawn_opts must include agent_mode: :claude_code for :claude_code mode; got #{inspect(spawn_opts)}"

    # Cleanup
    File.rm(agent_bin_path)
  end

  @tag :d_376
  test "D-376: :scripted mode — resolve/1 does not set agent_mode: :claude_code in spawn_opts" do
    opts = [agent_mode: :scripted]

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: :scripted mode must NOT produce agent_mode: :claude_code in spawn_opts; got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: :replay mode — resolve/1 does not set agent_mode: :claude_code in spawn_opts" do
    opts = [agent_mode: :replay]

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: :replay mode must NOT produce agent_mode: :claude_code in spawn_opts; got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: absent agent_mode (default) — resolve/1 does not activate :claude_code (D-357 gated OFF)" do
    opts = []

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: absent agent_mode must NOT produce agent_mode: :claude_code (D-357 gated OFF); got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: absent agent_mode reads from Application.get_env(:tau, :factory) when no opts provided" do
    # Verify resolve/0 (or resolve([]) reading app env) does not default to :claude_code
    # when app env does not contain agent_mode: :claude_code.
    prior = Application.get_env(:tau, :factory, [])

    on_exit(fn ->
      Application.put_env(:tau, :factory, prior)
    end)

    Application.put_env(:tau, :factory, Keyword.delete(prior, :agent_mode))

    factory_opts = Application.get_env(:tau, :factory, [])
    {_agent_bin_path, spawn_opts} = AgentBin.resolve(factory_opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: when factory config has no agent_mode, resolve/1 must not activate :claude_code; got #{inspect(spawn_opts)}"
  end

  # ---------------------------------------------------------------------------
  # D-376 END-TO-END: selecting :claude_code fires the D-374 preflight in the Worker
  #
  # This is the REFINE addition (PR #512 gate finding: orphaned fence).
  #
  # Observation point: `UnitDriver.drive/2` with `agent_mode: :claude_code` in
  # deps + a `creds_check_fun` stub returning `{:error, :subscription_creds_absent}`.
  # The unit must escalate with `reason: :E_WORKER_ERROR` because
  # `WorkerSupervisor.spawn/5` returns `{:error, :metered_path_refused}`.
  #
  # FAIL-BEFORE reason (current branch):
  #   UnitDriver ignores `agent_mode:` from deps → worker spawns without
  #   `agent_mode:` → preflight skipped → slow bin blocks → state_timeout
  #   fires after @fast_timeout_ms → unit escalates with `:E_WORKER_STALLED`,
  #   NOT `:E_WORKER_ERROR`. The `assert_receive` pattern matching
  #   `reason: :E_WORKER_ERROR` times out or matches wrong reason → test FAILS.
  #
  # PASS-AFTER reason (after implementer threads spawn_opts through the callers):
  #   UnitDriver threads `agent_mode: :claude_code` + `creds_check_fun:` into
  #   the worker spawn opts → `preflight_metered(:claude_code, creds_fn)` fires
  #   immediately → `{:error, :metered_path_refused}` → worker_fun returns
  #   `{:error, :metered_path_refused}` → unit escalates with `:E_WORKER_ERROR`
  #   → `assert_receive` matches immediately → test PASSES.
  # ---------------------------------------------------------------------------

  # Short state_timeout so the current-buggy path escalates quickly (with
  # :E_WORKER_STALLED) and the test does not block for 30 s.
  @d376_e2e_state_timeout_ms 400

  # Outer receive timeout — must exceed @d376_e2e_state_timeout_ms plus OTP
  # message-delivery overhead, but stay short enough that a test-suite run
  # doesn't stall. 5_000 ms is well inside CI limits.
  @d376_e2e_receive_timeout_ms 5_000

  @tag :d_376
  test "D-376 end-to-end: selecting :claude_code threads agent_mode to the Worker so the D-374 preflight fires" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("tau_d376_e2e_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # A blocking agent bin: reads stdin forever, never emits work_ready.
    # Used so the BUGGY path (no agent_mode threaded) keeps the worker alive
    # until state_timeout fires → unit escalates with :E_WORKER_STALLED.
    # The FIXED path never reaches this bin (preflight refuses before Port.open).
    blocking_bin = Path.join(tmp_dir, "blocking_agent")

    File.write!(blocking_bin, """
    #!/bin/sh
    # Block until killed — never emits a work_ready frame.
    read -r _line || true
    exit 0
    """)

    File.chmod!(blocking_bin, 0o755)

    # Hermetic git repo for git worktree add.
    repo_dir = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo_dir)
    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "d376test@tau.test"])
    {_, 0} = git.(["config", "user.name", "D376 Test"])
    File.write!(Path.join(repo_dir, "README"), "d376\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial"])
    {sha, 0} = git.(["rev-parse", "HEAD"])
    base_ref = String.trim(sha)

    # Resolve the agent_bin for :claude_code mode.
    # `spawn_opts` = [agent_mode: :claude_code] per the existing 6 tests.
    # The IMPLEMENTER must thread spawn_opts into UnitDriver deps so the Worker
    # receives agent_mode: :claude_code. Currently the dogfood drops spawn_opts.
    {agent_bin_path, spawn_opts} =
      AgentBin.resolve(agent_mode: :claude_code, branch: "feat/d376-e2e-test")

    on_exit(fn -> File.rm(agent_bin_path) end)

    assert Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "Prerequisite: resolve/1 must return [agent_mode: :claude_code] in spawn_opts; got #{inspect(spawn_opts)}"

    # Start the factory substrate (mirrors UnitDriverTest.start_substrate/3 pattern).
    n = System.unique_integer([:positive])
    sched = :"d376e2e_sched_#{n}"
    unit_sup = :"d376e2e_unitsup_#{n}"
    unit_reg = :"d376e2e_unitreg_#{n}"
    worker_reg = :"d376e2e_workerreg_#{n}"
    worker_sup = :"d376e2e_workersup_#{n}"
    ledger = :"d376e2e_ledger_#{n}"
    janitor = :"d376e2e_janitor_#{n}"
    db_path = Path.join(tmp_dir, "d376e2e_ledger_#{n}.db")

    start_supervised!({Scheduler, name: sched, w_cap: 10}, id: sched)
    start_supervised!({UnitSupervisor, name: unit_sup}, id: unit_sup)

    start_supervised!(
      %{
        id: unit_reg,
        start: {Registry, :start_link, [[keys: :unique, name: unit_reg]]}
      },
      id: unit_reg
    )

    start_supervised!({WorkerRegistry, name: worker_reg}, id: worker_reg)
    start_supervised!({WorkerSupervisor, name: worker_sup, registry: worker_reg}, id: worker_sup)
    start_supervised!({LedgerWriter, db_path: db_path, name: ledger}, id: ledger)

    # WorkspaceJanitor always registers under __MODULE__ (Tau.Factory.WorkspaceJanitor)
    # regardless of the :name supervision opt (see lib/tau/factory/workspace_janitor.ex:63).
    # Pass WorkspaceJanitor (the module atom) as deps[:janitor] so UnitDriver's
    # `janitor_pid = deps[:janitor] || WorkspaceJanitor` resolves to the running process.
    # This mirrors the UnitDriverTest pattern.
    start_supervised!({WorkspaceJanitor, ledger: ledger, name: janitor}, id: janitor)

    test_pid = self()
    unit_id = "d376-e2e-#{n}"

    # A stub MergeAuthority the unit never reaches (escalates before gating).
    merge_authority =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:request_merge, _}} ->
            :gen.reply(from, :queued)
        end
      end)

    work_item = %{
      unit_id: unit_id,
      declared_scope: %{
        deps: [],
        files: MapSet.new(),
        codepoints: MapSet.new(),
        specs: MapSet.new(),
        resources: MapSet.new()
      },
      hash: "hash-#{unit_id}",
      branch: "feat/d376-e2e-branch",
      run: "run-1",
      base_ref: base_ref,
      brief: "D-376 end-to-end test brief"
    }

    # deps carries agent_mode: :claude_code and creds_check_fun.
    # After the fix: UnitDriver extracts agent_mode + creds_check_fun from deps
    # and threads them into the worker_fun spawn opts.
    # Currently (before fix): UnitDriver ignores both keys.
    #
    # Note: deps[:janitor] = WorkspaceJanitor (module atom, not bespoke name)
    # because WorkspaceJanitor always self-registers under __MODULE__.
    deps = %{
      unit_supervisor: unit_sup,
      unit_registry: unit_reg,
      scheduler: sched,
      worker_supervisor: worker_sup,
      worker_registry: worker_reg,
      ledger: ledger,
      janitor: WorkspaceJanitor,
      pubsub: Tau.PubSub,
      repo_dir: repo_dir,
      agent_bin: blocking_bin,
      # The two keys that MUST be threaded through to WorkerSupervisor.spawn/5
      # by the implementer (the fix this test gates):
      agent_mode: :claude_code,
      creds_check_fun: fn -> {:error, :subscription_creds_absent} end,
      gate_fun: fn _coord -> :pass end,
      merge_authority: merge_authority,
      report_to: test_pid,
      unit_timeouts: [state_timeout_ms: @d376_e2e_state_timeout_ms]
    }

    unit_pid = UnitDriver.drive(work_item, deps)

    assert is_pid(unit_pid),
           "D-376: UnitDriver.drive/2 must return a Unit pid; got #{inspect(unit_pid)}"

    # Assert: the Unit escalates with :E_WORKER_ERROR (preflight fired, spawn refused).
    #
    # FAIL-BEFORE (current branch): UnitDriver ignores agent_mode/creds_check_fun
    # → preflight never fires → blocking bin runs → state_timeout fires after
    # @d376_e2e_state_timeout_ms → unit escalates with reason: :E_WORKER_STALLED.
    # The pattern below does NOT match :E_WORKER_STALLED → assert_receive FAILS
    # (or the message is never received within the timeout), proving the fence is
    # orphaned.
    #
    # PASS-AFTER (implementer threads spawn_opts): preflight fires immediately →
    # WorkerSupervisor.spawn returns {:error, :metered_path_refused} → worker_fun
    # returns {:error, ...} → Unit escalates with reason: :E_WORKER_ERROR →
    # assert_receive matches → test PASSES.
    assert_receive {:unit_terminal, ^unit_id, :escalated, %{reason: :E_WORKER_ERROR}},
                   @d376_e2e_receive_timeout_ms,
                   "D-376 end-to-end: expected Unit to escalate with :E_WORKER_ERROR " <>
                     "(D-374 preflight fired, spawn refused with :metered_path_refused). " <>
                     "Got :E_WORKER_STALLED or no message — agent_mode: :claude_code was NOT " <>
                     "threaded from deps to WorkerSupervisor.spawn/5 (orphaned-fence bug). " <>
                     "Implementer must wire: dogfood spawn_opts → supervisor_opts[:agent_mode] " <>
                     "→ UnitDriver deps[:agent_mode] → worker_fun opts[:agent_mode] → " <>
                     "WorkerSupervisor.spawn/5."
  end
end

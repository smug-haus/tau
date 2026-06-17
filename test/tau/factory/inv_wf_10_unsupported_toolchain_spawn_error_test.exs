defmodule Tau.Factory.InvWf10UnsupportedToolchainSpawnErrorTest do
  @moduledoc """
  Gating test for INV-WF-10 (issue #612).

  INV-WF-10 statement:
    Concurrent workers MUST NOT share any declared mutable $HOME path. A
    worker spec for a concurrent build that lacks the required namespace
    declarations is a spawn error, not a warning.

  The specific failure path under audit:
    When `Toolchain.for/1` returns `{:error, {:unsupported_language, lang}}`
    (worker.ex:241-242 catches this and silently sets `decls = []`), the
    Worker MUST `{:stop, {:unsupported_toolchain, lang}}` (or equivalent stop
    tuple containing the unsupported-toolchain signal) rather than continuing
    with an empty namespace map and opening the agent Port.

  This test exercises the real user-facing entry point:
    `Tau.Factory.WorkerSupervisor.spawn/5`
  with an unsupported `:toolchain` key (e.g. `:python`) that causes
  `Toolchain.for/1` to return `{:error, {:unsupported_language, :python}}`.

  EXPECTED (conformant) behaviour:
    - The worker stops immediately — it is never alive in the registry after
      a brief settle window.
    - The agent Port is NEVER opened (no marker file written).
    - `report_to` receives a death-certificate
      `{:worker_exit, worker_id, reason}` where `reason` encodes the
      unsupported-toolchain stop, NOT `:normal` or `:no_work_product`.

  CURRENT (defective) behaviour (worker.ex:240-244):
    `case tc_module do {:error, _} -> [] ...` silently degrades to
    `decls = []`, then `resolve_namespace(ws, []) => %{}`, then execution
    continues through verify_position and Port.open — the worker runs with
    ZERO isolation env vars, violating D-309 clause 2.

  Because the current code does NOT stop on unsupported toolchain, this test
  FAILS (red) before the implementer ships the fix.

  References: SPEC-FACTORY-FLEET §4 B3, D-309, INV-WF-10; issue #612.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_wf_10

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Helpers (local copies; test-author must not touch lib/).
  # ---------------------------------------------------------------------------

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

  defp start_fleet(test_tag) do
    n = System.unique_integer([:positive])
    registry_name = :"#{test_tag}_registry_#{n}"
    sup_name = :"#{test_tag}_sup_#{n}"

    {:ok, _} =
      start_supervised({@worker_registry, name: registry_name}, id: :"reg_#{n}")

    {:ok, sup} =
      start_supervised({@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # INV-WF-10 tests
  # ---------------------------------------------------------------------------

  describe "INV-WF-10 — unsupported toolchain is a spawn error, not a silent degradation" do
    @tag :inv_wf_10
    test "INV-WF-10: spawning a worker with an unsupported toolchain key MUST stop the worker — Port is never opened" do
      # Exercises the real path: WorkerSupervisor.spawn/5 with toolchain: :python.
      # Toolchain.for(:python) returns {:error, {:unsupported_language, :python}}.
      #
      # Conformant behaviour: the Worker's init/1 MUST call {:stop, ...} with a
      # reason that encodes the unsupported-toolchain condition; it MUST NOT
      # proceed to Port.open.
      #
      # Current (defective) behaviour: worker.ex:241-242 catches the error and
      # silently sets decls = [], then continues — the Port IS opened and the
      # worker runs with an empty namespace (zero isolation). This test catches
      # that defect.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv_wf10_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      # Marker file: the agent executable creates this on startup.
      # If it appears, the Port was opened — an INV-WF-10 violation.
      marker = Path.join(tmp_dir, "port_launched_inv_wf10")

      agent_bin = Path.join(tmp_dir, "marker_agent_inv_wf10")

      File.write!(agent_bin, """
      #!/bin/sh
      touch #{marker}
      # Stay alive briefly so the test window can detect the marker.
      sleep 2
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {_sup_name, sup, registry_name} = start_fleet(:inv_wf10)

      report_to = self()

      # Spawn with toolchain: :python — a key Toolchain.for/1 does NOT know.
      # Under the conformant (fixed) implementation this MUST stop the worker
      # with a spawn error before Port.open.
      # Under the defective implementation the worker starts and the marker appears.
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          toolchain: :python,
          report_to: report_to,
          registry: registry_name
        )

      # Allow a settle window for the worker to complete init and (if conformant)
      # stop. Use the death-certificate as the primary signal (conformant impl
      # delivers {:worker_exit, worker_id, reason} to report_to on every stop).
      settle_ms = 1_500

      dc_reason =
        receive do
          {:worker_exit, ^worker_id, reason} -> reason
        after
          settle_ms -> :no_death_cert_received
        end

      # ---------------------------------------------------------------------------
      # Assertion 1: the worker must have stopped — not alive in the registry.
      # ---------------------------------------------------------------------------
      # Give an extra moment for registry deregistration after the death-cert.
      Process.sleep(100)
      registry_entries = Registry.lookup(registry_name, worker_id)

      assert registry_entries == [] or
               (registry_entries != [] and
                  not Process.alive?(elem(hd(registry_entries), 0))),
             "INV-WF-10: a worker spawned with an unsupported toolchain key " <>
               "(toolchain: :python → Toolchain.for(:python) = {:error, {:unsupported_language, :python}}) " <>
               "MUST stop immediately (spawn error); " <>
               "but it is still alive and registered. " <>
               "Current defect: worker.ex:241-242 catches {:error, _} and sets decls=[], " <>
               "then continues through verify_position and Port.open with an empty namespace."

      # ---------------------------------------------------------------------------
      # Assertion 2: Port must NEVER have been opened (marker absent).
      # ---------------------------------------------------------------------------
      # Allow brief I/O flush in case the agent was just started.
      Process.sleep(200)

      refute File.exists?(marker),
             "INV-WF-10: the agent Port MUST NOT be opened when the toolchain is " <>
               "unsupported. The marker at #{marker} appeared, meaning Port.open " <>
               "was called before the worker stopped. " <>
               "Fix: worker.ex init_after_worktree/1 must pattern-match {:error, _} " <>
               "from Toolchain.for/1 and return {:stop, {:unsupported_toolchain, lang}}."

      # ---------------------------------------------------------------------------
      # Assertion 3: the death-certificate reason must encode the toolchain error,
      # NOT :normal or :no_work_product (which would mean the Port ran to completion).
      # ---------------------------------------------------------------------------
      refute dc_reason == :no_death_cert_received,
             "INV-WF-10: a death-certificate {:worker_exit, worker_id, reason} MUST " <>
               "arrive at report_to after a spawn error for unsupported toolchain. " <>
               "None arrived within #{settle_ms}ms. " <>
               "Either the worker did not stop (defect: still running with empty ns) " <>
               "or the monitor did not fire."

      refute dc_reason == :normal,
             "INV-WF-10: death-cert reason :normal means the Port ran to clean exit — " <>
               "the worker processed work with an empty namespace map (zero isolation). " <>
               "The reason must encode the unsupported-toolchain stop, not :normal."

      refute dc_reason == :no_work_product,
             "INV-WF-10: death-cert reason :no_work_product means the Port ran and " <>
               "exited without a work_ready frame — still a Port-opened path. " <>
               "The reason must encode the unsupported-toolchain stop."

      # Positive assertion: the reason must carry the unsupported-toolchain signal.
      # Accept any stop-tuple whose first element names the toolchain error condition.
      assert match?({:unsupported_toolchain, _}, dc_reason) or
               match?({:unsupported_language, _}, dc_reason) or
               match?({{:unsupported_language, _}, _}, dc_reason) or
               (is_tuple(dc_reason) and
                  Enum.any?(
                    Tuple.to_list(dc_reason),
                    &(&1 == :unsupported_toolchain or &1 == :unsupported_language)
                  )),
             "INV-WF-10: death-cert reason must encode the unsupported-toolchain " <>
               "condition (e.g. {:unsupported_toolchain, :python}); " <>
               "got #{inspect(dc_reason)}."
    end

    @tag :inv_wf_10
    test "INV-WF-10: a supported toolchain (:elixir) does NOT trigger a spawn error — control" do
      # Regression guard: the fix must not break the :elixir (supported) path.
      # A slow agent is used so the worker is alive during the registry check.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv_wf10_ctrl_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)

      agent_bin = Path.join(tmp_dir, "slow_agent_ctrl")

      File.write!(agent_bin, """
      #!/bin/sh
      read -r line || true
      exit 0
      """)

      File.chmod!(agent_bin, 0o755)

      {_sup_name, sup, registry_name} = start_fleet(:inv_wf10_ctrl)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          toolchain: :elixir,
          registry: registry_name
        )

      # Settle: :elixir path should produce a live worker.
      Process.sleep(300)

      entries = Registry.lookup(registry_name, worker_id)

      assert entries != [],
             "INV-WF-10 (control): a worker spawned with the supported toolchain :elixir " <>
               "MUST remain alive; it was not found in the registry after 300ms. " <>
               "The fix must not reject valid toolchains."

      [{pid, _}] = entries

      assert Process.alive?(pid),
             "INV-WF-10 (control): the :elixir-toolchain worker must be alive; " <>
               "got pid=#{inspect(pid)} (dead)."

      Process.exit(pid, :kill)
    end
  end
end

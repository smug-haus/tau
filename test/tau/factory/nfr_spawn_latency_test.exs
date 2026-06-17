defmodule Tau.Factory.NfrSpawnLatencyTest do
  @moduledoc """
  Gating test for issue #679 — **NFR-SPAWN**.

  ## Invariant statement

  A work unit's isolated workspace (git checkout + per-worker resource
  namespace) is ready at p95 <= 30 seconds (warm cache). The observable
  mechanism gating a collector's ability to derive spawn latency is the
  `[:tau, :factory, :worker, :start]` telemetry event: it MUST include a
  `duration_ms` measurement carrying the wall-time in milliseconds from the
  start of `init/1` (before `git worktree add`) to the end (after
  `Port.open`). Without this field the p95 invariant is uncollectable and
  therefore permanently unenforceable.

  ## Why this is falsified now

  `lib/tau/factory/worker.ex` lines 398-417: the `:telemetry.execute/3`
  call at the end of `init/1` emits:

      :telemetry.execute(
        [:tau, :factory, :worker, :start],
        %{},                              <- empty measurements
        %{worker_id: worker_id, role: role}
      )

  No monotonic clock is started before `git worktree add` (line 131) and
  no duration is computed. The empty `%{}` measurement map means no
  external collector -- Prometheus, OtelReporter, or a test -- can derive
  spawn latency from the event.

  ## Contract (NFR-SPAWN, docs/arch/02-requirements/nfrs.md lines 47-52)

      NFR-SPAWN -- worker spawn latency. A work unit's isolated workspace
      (git checkout + per-worker resource namespace) is ready at p95 <= 30 s.
      (statistic: p95; threshold: 30 s incl. dependency warm-cache; window:
      per spawn; load: peak concurrency.)

  The p95 threshold can only be enforced if duration is measured and emitted.
  The implementer MUST:
    1. Capture `t0 = System.monotonic_time(:millisecond)` at the start of
       `init/1` (before `git worktree add`).
    2. Compute `duration_ms = System.monotonic_time(:millisecond) - t0`
       immediately before the `:telemetry.execute/3` call.
    3. Emit `%{duration_ms: duration_ms}` as the measurements map (not `%{}`).

  ## AC linkage

    - `@tag :nfr_spawn` -- every test below.
    - Test name contains "NFR-SPAWN".

  ## Evidence (issue #679)

    - `lib/tau/factory/worker.ex` lines 110-162: init starts, no monotonic
      clock captured before git worktree add at line 131.
    - `lib/tau/factory/worker.ex` lines 398-417: Port.open at 399, then
      `:telemetry.execute/3` at ~413 with empty `%{}` measurements.
    - `docs/arch/02-requirements/nfrs.md` lines 47-52: NFR-SPAWN contract.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :nfr_spawn

  @worker_supervisor Tau.Factory.WorkerSupervisor
  @worker_registry Tau.Factory.WorkerRegistry

  # ---------------------------------------------------------------------------
  # Test helpers
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

    readme_path = Path.join(repo_dir, "README")
    File.write!(readme_path, "initial\n")
    {_, 0} = git.(["add", "README"])

    {staged, _} = git.(["diff", "--cached", "--name-only"])

    unless String.contains?(staged, "README") do
      raise "setup_git_repo: git add did not stage README; staged=#{inspect(staged)}"
    end

    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])
    base_ref = String.trim(sha)

    %{repo_dir: repo_dir, base_ref: base_ref}
  end

  # A dummy agent that blocks until its stdin closes (so the worker stays alive
  # long enough for us to inspect the telemetry event before the worker exits).
  defp blocking_agent_bin(tmp_dir) do
    bin_path = Path.join(tmp_dir, "blocking_agent_#{System.unique_integer([:positive])}")

    File.write!(bin_path, """
    #!/bin/sh
    read -r line || true
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"#{tag}_reg_#{n}"
    sup_name = :"#{tag}_sup_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"nfr_spawn_reg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"nfr_spawn_sup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # NFR-SPAWN: [:tau, :factory, :worker, :start] telemetry MUST include
  # duration_ms in measurements
  # ---------------------------------------------------------------------------

  describe "NFR-SPAWN -- worker start telemetry carries spawn duration" do
    @tag :nfr_spawn
    test "NFR-SPAWN: [:tau, :factory, :worker, :start] measurements include duration_ms as a non-negative integer" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_nfr_spawn_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = blocking_agent_bin(tmp_dir)

      # Attach a telemetry handler that captures the event measurements.
      handler_id = "nfr_spawn_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :worker, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:worker_start_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {_sup_name, sup, registry_name} = start_fleet(:nfr_spawn)

      # Spawn a real worker through the real user-facing entry point
      # (WorkerSupervisor.spawn/5 -> Worker.init/1 -> telemetry.execute).
      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "test brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      # The [:tau, :factory, :worker, :start] event is emitted synchronously
      # at the end of Worker.init/1, so it arrives before start_link returns.
      # We should already have it; receive with a short timeout as a safety net.
      measurements =
        receive do
          {:worker_start_telemetry, m, _meta} ->
            m
        after
          5_000 ->
            flunk(
              "NFR-SPAWN: no [:tau, :factory, :worker, :start] telemetry received " <>
                "within 5 s of WorkerSupervisor.spawn/5. The event must be emitted " <>
                "synchronously at the end of Worker.init/1."
            )
        end

      # The measurements map MUST contain a duration_ms key.
      assert Map.has_key?(measurements, :duration_ms),
             "NFR-SPAWN: [:tau, :factory, :worker, :start] measurements MUST include " <>
               ":duration_ms. Current implementation emits empty %{} (worker.ex ~line 413). " <>
               "The implementer must: (1) capture t0 = System.monotonic_time(:millisecond) " <>
               "at the start of init/1, before git worktree add; (2) compute " <>
               "duration_ms = System.monotonic_time(:millisecond) - t0 before the telemetry " <>
               "execute call; (3) emit %{duration_ms: duration_ms} as the measurements. " <>
               "Without this field, external collectors (Prometheus, OtelReporter) cannot " <>
               "derive spawn latency and NFR-SPAWN (docs/arch/02-requirements/nfrs.md " <>
               "lines 47-52: p95 <= 30 s warm-cache) is permanently unenforceable. " <>
               "Received measurements: #{inspect(measurements)}"

      # The duration_ms value MUST be a non-negative integer (monotonic time difference).
      duration_ms = measurements[:duration_ms]

      assert is_integer(duration_ms),
             "NFR-SPAWN: measurements[:duration_ms] must be an integer (milliseconds); " <>
               "got #{inspect(duration_ms)}"

      assert duration_ms >= 0,
             "NFR-SPAWN: measurements[:duration_ms] must be >= 0; " <>
               "got #{inspect(duration_ms)}"

      # Clean up the live worker.
      [{pid, _}] = Registry.lookup(registry_name, worker_id)
      Process.exit(pid, :kill)
    end
  end

  # ---------------------------------------------------------------------------
  # NFR-SPAWN: metadata contract -- worker_id and role must still be present
  # alongside the new duration_ms measurement
  # ---------------------------------------------------------------------------

  describe "NFR-SPAWN -- worker start telemetry metadata is complete" do
    @tag :nfr_spawn
    test "NFR-SPAWN: [:tau, :factory, :worker, :start] metadata includes worker_id and role alongside duration_ms" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_nfr_spawn_meta_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = blocking_agent_bin(tmp_dir)

      handler_id = "nfr_spawn_meta_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :worker, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:worker_start_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {_sup_name, sup, registry_name} = start_fleet(:nfr_spawn_meta)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :reviewer, "meta brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name
        )

      {measurements, metadata} =
        receive do
          {:worker_start_telemetry, m, md} -> {m, md}
        after
          5_000 ->
            flunk("NFR-SPAWN: no [:tau, :factory, :worker, :start] telemetry received within 5 s")
        end

      # duration_ms must be present (the gating assertion from the primary test).
      assert Map.has_key?(measurements, :duration_ms),
             "NFR-SPAWN: measurements must include :duration_ms; got #{inspect(measurements)}"

      # Existing metadata keys must be preserved (no regression).
      assert Map.has_key?(metadata, :worker_id),
             "NFR-SPAWN: metadata must include :worker_id; got #{inspect(metadata)}"

      assert Map.has_key?(metadata, :role),
             "NFR-SPAWN: metadata must include :role; got #{inspect(metadata)}"

      assert metadata.worker_id == worker_id,
             "NFR-SPAWN: metadata.worker_id must match the spawned worker_id; " <>
               "expected #{inspect(worker_id)}, got #{inspect(metadata.worker_id)}"

      assert metadata.role == :reviewer,
             "NFR-SPAWN: metadata.role must match the spawned role :reviewer; " <>
               "got #{inspect(metadata.role)}"

      [{pid, _}] = Registry.lookup(registry_name, worker_id)
      Process.exit(pid, :kill)
    end
  end
end

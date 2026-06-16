defmodule Tau.Factory.WorkerIdempotentRedeliveryTest do
  @moduledoc """
  Gating test for issue #596: INV-DIST-WORKER-IDEMPOTENT.

  Invariant statement:
    Every worker job submitted via the Oban queue MUST be idempotent
    (re-delivery after timeout is benign) and ref-correlated (result message
    carries the unit/worker ref so a late or duplicate reply is matchable and
    discardable).

  Falsified by:
    - A worker job whose re-delivery produces a double-action side-effect.
    - A result message lacking a correlation ref.

  This test exercises the real user-facing dispatch boundary:
  `Tau.Factory.WorkerSupervisor.spawn/5`.

  Two sub-properties are asserted here:

  ### P1 — Oban queue infrastructure present (INV-DIST-WORKER-IDEMPOTENT / queue path)

  The documented architecture (`docs/arch/04-software-architecture/supervision-tree.md`
  §6 D-S4) specifies that the distribution boundary for remote worker dispatch is
  Oban: "remote workers pull work; they are idempotent and ref-correlated."
  The anti-pattern review confirms: "Node-crossing (future) is idempotent +
  ref-correlated via Oban." Oban MUST be a declared dependency for the invariant's
  queue path to exist.

  ### P2 — Re-delivery idempotency: duplicate spawn with same worker_id MUST NOT
  double-execute (INV-DIST-WORKER-IDEMPOTENT / re-delivery)

  `WorkerSupervisor.spawn/5` called twice with the same `:worker_id` MUST be
  idempotent: exactly ONE agent process runs; exactly ONE death certificate
  `{:worker_exit, worker_id, _}` is received by `report_to`.

  ### P3 — Ref-correlation: every result message MUST carry the worker_id
  (INV-DIST-WORKER-IDEMPOTENT / ref-correlated)

  The `{:worker_exit, worker_id, reason}` death certificate MUST carry the
  `worker_id` correlation ref returned by `spawn/5`, enabling the Unit FSM to
  match and discard late or duplicate replies.

  ## AC linkage
    - `@tag :inv_dist_worker_idempotent` — every test below.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_dist_worker_idempotent

  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Helpers
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

  # Agent that blocks (reads from stdin) so we can test concurrent spawning.
  defp blocking_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "blocking_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    # Block until stdin closes or a signal arrives (simulates a live agent).
    read -r _line || true
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  # Agent that exits immediately (used to drive death-cert assertions quickly).
  defp fast_exit_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "fast_exit_agent#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exit 0
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_fleet(test_tag) do
    n = System.unique_integer([:positive])
    registry_name = :"#{test_tag}_registry_#{n}"
    sup_name = :"#{test_tag}_sup_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"reg_#{n}"
      )

    {:ok, _sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"sup_#{n}"
      )

    {sup_name, registry_name}
  end

  # ---------------------------------------------------------------------------
  # P1 — Oban queue infrastructure (INV-DIST-WORKER-IDEMPOTENT / queue path)
  # ---------------------------------------------------------------------------

  describe "INV-DIST-WORKER-IDEMPOTENT P1 — Oban queue infrastructure present" do
    @tag :inv_dist_worker_idempotent
    test "INV-DIST-WORKER-IDEMPOTENT: Oban must be a declared dependency for the idempotent queue path" do
      # The documented architecture specifies Oban as the distribution boundary:
      # "remote workers pull work; they are idempotent and ref-correlated."
      # (docs/arch/04-software-architecture/supervision-tree.md §6 D-S4)
      # This assertion fails until Oban is added to mix.exs deps.
      assert Code.ensure_loaded?(Oban),
             "INV-DIST-WORKER-IDEMPOTENT: Oban module must be available. " <>
               "The architecture specifies Oban as the distribution queue boundary " <>
               "(supervision-tree.md §6 D-S4): 'remote workers pull work; they are " <>
               "idempotent and ref-correlated.' Oban is absent from mix.exs deps — " <>
               "add {:oban, \"~> 2.x\"} and the Oban.Worker behaviour to the worker " <>
               "dispatch path to satisfy this invariant."
    end
  end

  # ---------------------------------------------------------------------------
  # P2 — Re-delivery idempotency (INV-DIST-WORKER-IDEMPOTENT / re-delivery)
  # ---------------------------------------------------------------------------

  describe "INV-DIST-WORKER-IDEMPOTENT P2 — re-delivery with same worker_id is idempotent" do
    @tag :inv_dist_worker_idempotent
    test "INV-DIST-WORKER-IDEMPOTENT: spawning same worker_id twice must not double-execute; exactly one death-cert received",
         %{tmp_dir: tmp_dir} do
      {sup_name, registry_name} = start_fleet(:p2_idem)
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      blocking_bin = blocking_agent_bin(tmp_dir)

      shared_worker_id = "idem-#{System.unique_integer([:positive])}"

      # First spawn: starts the worker.
      result1 =
        @worker_supervisor.spawn(
          sup_name,
          :implementer,
          "brief one",
          base_ref,
          worker_id: shared_worker_id,
          registry: registry_name,
          repo_dir: repo_dir,
          agent_bin: blocking_bin,
          report_to: self()
        )

      assert {:ok, ^shared_worker_id} = result1,
             "INV-DIST-WORKER-IDEMPOTENT: first spawn must return {:ok, worker_id}"

      # Verify the worker is live in the registry before second spawn.
      live_entries = Registry.lookup(registry_name, shared_worker_id)

      assert length(live_entries) == 1,
             "INV-DIST-WORKER-IDEMPOTENT: exactly one worker must be registered after first spawn; " <>
               "got #{length(live_entries)} entries"

      # Second spawn with same worker_id: MUST be idempotent (no second agent run).
      result2 =
        @worker_supervisor.spawn(
          sup_name,
          :implementer,
          "brief duplicate",
          base_ref,
          worker_id: shared_worker_id,
          registry: registry_name,
          repo_dir: repo_dir,
          agent_bin: blocking_bin,
          report_to: self()
        )

      assert {:ok, ^shared_worker_id} = result2,
             "INV-DIST-WORKER-IDEMPOTENT: duplicate spawn must return {:ok, worker_id} (idempotent)"

      # Still exactly one live entry in the registry — no second process started.
      live_entries_after = Registry.lookup(registry_name, shared_worker_id)

      assert length(live_entries_after) == 1,
             "INV-DIST-WORKER-IDEMPOTENT: re-delivery must NOT start a second worker process; " <>
               "registry must still have exactly one entry; got #{length(live_entries_after)}"

      # Kill the worker and verify exactly ONE death certificate arrives —
      # a double-spawn would produce two certificates.
      [{worker_pid, _}] = live_entries_after
      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^shared_worker_id, _reason},
                     5_000,
                     "INV-DIST-WORKER-IDEMPOTENT: exactly one death-cert {:worker_exit, worker_id, _} " <>
                       "must be received after killing the single worker"

      # No second death certificate should arrive (idempotency: no double-action).
      refute_receive {:worker_exit, ^shared_worker_id, _},
                     200,
                     "INV-DIST-WORKER-IDEMPOTENT: a second death-cert for the same worker_id " <>
                       "was received — re-delivery produced a double-action side-effect, " <>
                       "violating the idempotency requirement"
    end
  end

  # ---------------------------------------------------------------------------
  # P3 — Ref-correlation (INV-DIST-WORKER-IDEMPOTENT / ref-correlated)
  # ---------------------------------------------------------------------------

  describe "INV-DIST-WORKER-IDEMPOTENT P3 — result messages carry worker_id correlation ref" do
    @tag :inv_dist_worker_idempotent
    test "INV-DIST-WORKER-IDEMPOTENT: {:worker_exit, worker_id, reason} carries the exact worker_id returned by spawn/5",
         %{tmp_dir: tmp_dir} do
      {sup_name, registry_name} = start_fleet(:p3_refcorr)
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      fast_bin = fast_exit_agent_bin(tmp_dir)

      {:ok, worker_id} =
        @worker_supervisor.spawn(
          sup_name,
          :implementer,
          "brief",
          base_ref,
          registry: registry_name,
          repo_dir: repo_dir,
          agent_bin: fast_bin,
          report_to: self()
        )

      assert is_binary(worker_id),
             "INV-DIST-WORKER-IDEMPOTENT: spawn/5 must return {:ok, worker_id} with a string worker_id; " <>
               "got #{inspect(worker_id)}"

      # The death-cert MUST carry the same worker_id — the correlation ref that
      # allows the Unit FSM to match and discard late or duplicate replies.
      assert_receive {:worker_exit, cert_worker_id, _reason},
                     5_000,
                     "INV-DIST-WORKER-IDEMPOTENT: {:worker_exit, worker_id, reason} must be received; " <>
                       "it carries the correlation ref enabling Unit to discard late/duplicate replies"

      assert cert_worker_id == worker_id,
             "INV-DIST-WORKER-IDEMPOTENT: the worker_id in {:worker_exit, worker_id, _} must " <>
               "match the worker_id returned by spawn/5; " <>
               "expected #{inspect(worker_id)}, got #{inspect(cert_worker_id)}"
    end

    @tag :inv_dist_worker_idempotent
    test "INV-DIST-WORKER-IDEMPOTENT: two concurrent workers produce ref-correlated death-certs; each cert is matchable to its spawn/5 worker_id",
         %{tmp_dir: tmp_dir} do
      {sup_name, registry_name} = start_fleet(:p3_multi_refcorr)
      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      fast_bin1 = fast_exit_agent_bin(tmp_dir, "_1")
      fast_bin2 = fast_exit_agent_bin(tmp_dir, "_2")

      {:ok, worker_id_1} =
        @worker_supervisor.spawn(
          sup_name,
          :implementer,
          "brief 1",
          base_ref,
          registry: registry_name,
          repo_dir: repo_dir,
          agent_bin: fast_bin1,
          report_to: self()
        )

      {:ok, worker_id_2} =
        @worker_supervisor.spawn(
          sup_name,
          :reviewer,
          "brief 2",
          base_ref,
          registry: registry_name,
          repo_dir: repo_dir,
          agent_bin: fast_bin2,
          report_to: self()
        )

      refute worker_id_1 == worker_id_2,
             "INV-DIST-WORKER-IDEMPOTENT: two independent spawns must produce distinct worker_ids"

      # Collect both death-certs; each must carry its own worker_id.
      certs =
        Enum.map(1..2, fn _ ->
          assert_receive {:worker_exit, cert_id, reason},
                         5_000,
                         "INV-DIST-WORKER-IDEMPOTENT: expected a :worker_exit cert from one of two workers"

          {cert_id, reason}
        end)

      cert_ids = Enum.map(certs, fn {id, _} -> id end) |> Enum.sort()
      expected_ids = Enum.sort([worker_id_1, worker_id_2])

      assert cert_ids == expected_ids,
             "INV-DIST-WORKER-IDEMPOTENT: death-certs must be ref-correlated — each cert's worker_id " <>
               "must match one of the two spawn/5 worker_ids so late/duplicate replies are matchable; " <>
               "expected #{inspect(expected_ids)}, got #{inspect(cert_ids)}"
    end
  end

  # ---------------------------------------------------------------------------
  # ExUnit setup: inject tmp_dir
  # ---------------------------------------------------------------------------

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "tau_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end
end

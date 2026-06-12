defmodule Tau.Factory.CoordinatorRecoveryTest do
  @moduledoc """
  Gating test for PR #455 (P5b — Coordinator durable resume from the Ledger).

  Enforces **D-344 (Recovery progress, liveness)** / **AC-8**: after a
  Coordinator crash the loop resumes from the durable Ledger (L) and continues;
  in-flight units rehydrate at their snapshotted state; **no terminal work is
  re-done** (exactly-once on resume).

  SPEC sources (docs/spec/SPEC-FACTORY-CORE.md):
    - §5 Coordinator state table: `running` entry = "start (resume from L)".
    - §4 B3 {Coordinator,Unit} ↔ Ledger.Writer: `snapshot_unit/2` is the durable
      write op recording a unit's transition state; every write carries an
      idempotency key `{unit_id, kind, coordinate}`; "a coordinator restart
      resumes from L with no decision lost or re-applied" (D-315, RPO=0).
    - §6 D-344: enforced by `coordinator_recovery_test.exs` — kill the Coordinator
      mid-drive; assert resume + idempotent rehydrate; no terminal work re-done.

  Written BEFORE the resume implementation exists (oracle-separation phase,
  factory-loop §4b). On current `main` the Coordinator's `init/1` does NOT take a
  `:ledger` opt and does NOT resume from L, and `Ledger.Writer` does not yet
  expose `snapshot_unit/2`. This test therefore FAILS now (the resume behaviour
  is precisely what is absent) and passes only once P5b lands. A test that passes
  against the absent behaviour would be vacuous.

  ## Pinned API contract (the implementer MUST conform exactly)

  ### Tau.Factory.Ledger.Writer — durable unit-snapshot op (B3)

  `snapshot_unit(server, attrs) :: {:ok, ref} | {:error, term}`
    `attrs` is a map:
      `:unit_id` — String.t(); the PR/unit identifier.
      `:state`   — atom(); the Unit FSM state at this snapshot, one of
                   `#{inspect([:planned, :oracle, :implementing, :gating, :refine_k, :awaiting_merge, :merged, :escalated])}`
                   (§5 Unit state enumeration). `:merged` / `:escalated` are
                   terminal sinks.
      `:idempotency_key` — String.t(); deterministic per `{unit_id, kind,
                   coordinate}` (B3 Pre). A replayed write with the same key is a
                   no-op (B3 Post; D-315).
    WAL-before-ack: the `{:ok, ref}` reply arrives only after the SQLite WAL
    commit is durable, so a snapshot survives a Coordinator crash.

  `latest_unit_snapshots(server) :: %{unit_id => state_atom}`
    Returns the latest snapshotted state per unit_id (highest row id wins),
    across the whole ledger. This is the resume-read the Coordinator uses to
    rebuild its in-flight set and to learn which units already reached a
    terminal sink. (The §4 B3 contract names the write op `snapshot_unit/2` but
    is silent on the resume-read op; see the SPEC-gap note in the test-author
    report. This name is the test's pinned contract; an amendment may rename it,
    in which case this test is updated in lockstep.)

  ### Tau.Factory.Coordinator — durable resume (D-344)

  `start_link/1` gains one option:
      `:ledger` — `GenServer.server()` reference to a running `Ledger.Writer`.
                  When present, `init/1` reads `latest_unit_snapshots/1` and:
                    - rehydrates each NON-terminal unit at its snapshotted state
                      (drives it forward — resume continues the loop), and
                    - re-does NO work for any unit already at a terminal sink
                      (`:merged` / `:escalated`) — exactly-once on resume (D-344).

  AC/D-NNN linkage: AC-8, D-344.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :ac_8
  @moduletag :d_344

  # Runtime module references. File compiles while the resume surfaces are
  # absent; the test fails at runtime (UndefinedFunctionError / behaviour gap).
  @coordinator Tau.Factory.Coordinator
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # Start a real Ledger.Writer against an isolated temp DB and return its name.
  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique_name(:rec_ledger)

    start_supervised!(
      {@writer, db_path: db_path, name: writer_name},
      id: writer_name
    )

    writer_name
  end

  # ---------------------------------------------------------------------------
  # AC-8 / D-344: Coordinator killed mid-drive resumes from L; no terminal
  # work is re-done; the in-flight unit rehydrates at its snapshotted state.
  #
  # Timeline:
  #   1. Real Ledger (L) holds two snapshotted units:
  #        - terminal_unit at :merged   (a terminal sink — already done).
  #        - inflight_unit at :implementing (NON-terminal — was in flight).
  #   2. Start Coordinator wired to L. select_fun returns nil (no NEW external
  #      work), so any drive the Coordinator performs can ONLY come from
  #      rehydrating L state — isolating the resume behaviour under test.
  #      drive_fun records every unit_id it is asked to drive into an Agent.
  #   3. KILL the Coordinator with :kill (terminate/2 cannot help — resume MUST
  #      come from L alone).
  #   4. Restart the Coordinator against the SAME L.
  #   5. Assert (load-bearing oracles):
  #        a. the terminal unit is NEVER driven post-resume (exactly-once / no
  #           terminal work re-done — the D-344 crux),
  #        b. the in-flight unit IS rehydrated (driven) — resumed, not dropped,
  #        c. resume is reflected in the Coordinator's rebuilt state
  #           (:sys.get_state shows the in-flight unit, terminal unit absent).
  # ---------------------------------------------------------------------------

  @tag :ac_8
  @tag :d_344
  test "AC-8 / D-344: Coordinator killed mid-drive resumes from L; terminal work is not re-done (exactly-once rehydrate)" do
    ledger = start_ledger()

    terminal_unit = "unit-terminal-#{System.unique_integer([:positive])}"
    inflight_unit = "unit-inflight-#{System.unique_integer([:positive])}"

    # --- Seed L with the two unit snapshots via the REAL durable write op. ---
    # A unit that already reached a terminal sink (:merged): no work may be
    # re-done for it on resume.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: terminal_unit,
               state: :merged,
               idempotency_key: "#{terminal_unit}:snapshot:merged"
             })

    # A unit that was in flight (non-terminal :implementing) when the crash hit:
    # it must rehydrate at this state and be driven forward on resume.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: inflight_unit,
               state: :implementing,
               idempotency_key: "#{inflight_unit}:snapshot:implementing"
             })

    # --- A drive seam that records every unit_id it is asked to drive. ---
    # Bound in THIS (test) process and closed over, so the recording target is
    # the test pid, never the coordinator's self() (the #452 mis-targeting trap).
    {:ok, drive_log} = Agent.start_link(fn -> [] end)
    test_pid = self()
    coord = coord_name()

    drive_fun = fn work ->
      unit_id = work
      Agent.update(drive_log, fn log -> log ++ [unit_id] end)
      send(test_pid, {:driven, unit_id})
      # The rehydrated unit "completes" immediately so the loop can quiesce;
      # the coordinator pid is resolved by registered name at drive time.
      coord_pid = Process.whereis(coord)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, unit_id, :merged})
      :ok
    end

    # No NEW external work: any drive observed comes from L rehydration alone.
    select_fun = fn -> nil end

    # --- Start the Coordinator wired to L, then KILL it mid-drive. ---
    {:ok, pid1} =
      @coordinator.start_link(
        name: coord,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil,
        ledger: ledger
      )

    # Let the first incarnation begin its resume/drive, then kill it hard.
    Process.sleep(50)
    Process.exit(pid1, :kill)

    refute Process.alive?(pid1)

    # Wait for the registered name to clear so the restart can re-register it.
    wait_until_unregistered(coord)

    # Reset the drive log: we assert about POST-RESUME drives specifically.
    Agent.update(drive_log, fn _ -> [] end)
    drain_driven_messages()

    # --- Restart the Coordinator against the SAME L. ---
    {:ok, _pid2} =
      @coordinator.start_link(
        name: coord,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: drive_fun,
        scheduler: nil,
        ledger: ledger
      )

    # The in-flight unit MUST be rehydrated and driven on resume (resumed at its
    # snapshotted state, not cold-dropped). select_fun returns nil, so this drive
    # can only originate from L rehydration.
    assert_receive {:driven, ^inflight_unit},
                   2000,
                   "D-344 violation: in-flight unit was not rehydrated/resumed from L"

    # Give the loop a moment to (incorrectly) re-drive the terminal unit if the
    # resume is NOT idempotent. With correct resume, no such drive occurs.
    Process.sleep(150)

    post_resume_drives = Agent.get(drive_log, & &1)

    # Oracle (a): exactly-once / no terminal work re-done — the terminal unit is
    # NEVER driven after resume. This is the D-344 crux.
    refute terminal_unit in post_resume_drives,
           "D-344 violation: a unit already :merged in L was re-driven on resume " <>
             "(post-resume drives: #{inspect(post_resume_drives)})"

    # Oracle (b): the in-flight unit was driven exactly once on resume — resumed,
    # not duplicated.
    inflight_count = Enum.count(post_resume_drives, &(&1 == inflight_unit))

    assert inflight_count == 1,
           "Expected the in-flight unit driven exactly once on resume; " <>
             "got #{inflight_count} (drives: #{inspect(post_resume_drives)})"

    # Oracle (c): resume is reflected in the rebuilt Coordinator state. The
    # restarted Coordinator's data must know about the in-flight unit it
    # rehydrated and must NOT carry the terminal unit as work to do.
    {_state_name, data} = :sys.get_state(coord)
    resumed = resumed_unit_ids(data)

    assert inflight_unit in resumed,
           "Rebuilt Coordinator state does not reflect the rehydrated in-flight " <>
             "unit from L; resumed=#{inspect(resumed)}"

    refute terminal_unit in resumed,
           "Rebuilt Coordinator state carries a terminal (:merged) unit as live " <>
             "work; resumed=#{inspect(resumed)}"
  end

  # ---------------------------------------------------------------------------
  # Local helpers used by the test body.
  # ---------------------------------------------------------------------------

  # A single stable registered name for the coordinator-under-test, so the
  # drive_fun closure (built before start) can resolve the pid by name and the
  # restart re-registers the same name.
  defp coord_name do
    Process.get(:rec_coord_name) ||
      (
        name = unique_name(:coord_recovery)
        Process.put(:rec_coord_name, name)
        name
      )
  end

  # Collect every unit_id the rebuilt Coordinator data treats as live/in-flight,
  # tolerant of how the resume records them (a single :in_flight id, a list, or a
  # map keyed by unit_id). Terminal units, correctly resumed, never appear here.
  defp resumed_unit_ids(data) when is_map(data) do
    direct =
      case Map.get(data, :in_flight) do
        nil -> []
        id when is_binary(id) -> [id]
        ids when is_list(ids) -> ids
        %{} = m -> Map.keys(m)
        _ -> []
      end

    collection =
      [:in_flight_units, :resumed, :units, :rehydrated]
      |> Enum.flat_map(fn key ->
        case Map.get(data, key) do
          %{} = m -> Map.keys(m)
          l when is_list(l) -> l
          _ -> []
        end
      end)

    Enum.uniq(direct ++ collection)
  end

  defp resumed_unit_ids(_), do: []

  defp wait_until_unregistered(name) do
    Enum.reduce_while(1..200, :waiting, fn _, _ ->
      case Process.whereis(name) do
        nil -> {:halt, :ok}
        _ -> Process.sleep(10) && {:cont, :waiting}
      end
    end)
  end

  defp drain_driven_messages do
    receive do
      {:driven, _} -> drain_driven_messages()
    after
      0 -> :ok
    end
  end
end

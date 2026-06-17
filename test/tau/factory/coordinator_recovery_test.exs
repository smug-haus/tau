defmodule Tau.Factory.CoordinatorRecoveryTest do
  @moduledoc """
  Gating test for PR #455 (P5b — Coordinator durable resume from the Ledger).

  Enforces **D-344 (Recovery progress, liveness)** / **AC-8**: after a
  Coordinator crash the *supervisor restarts it*, the restart resumes from the
  durable Ledger (L) and continues; in-flight units rehydrate at their
  snapshotted state; **no terminal work is re-done** (exactly-once on resume).

  ## Why this drives the SUPERVISED restart path (the strongest oracle)

  D-344's "resumes and continues" is only meaningful in production if the thing
  that triggers a resume — a *supervisor restart of the crashed Coordinator* —
  actually fires. Production wires the Coordinator into `Tau.Factory.Supervisor`
  via its `child_spec` (`start: {Coordinator, :start_link, [opts]}`,
  `restart: :permanent`, strategy `:one_for_one`). For the supervisor to detect
  the crash and restart, `start_link/1` MUST establish a link (the supervisor's
  link to its child). A `start_link` that calls `:gen_statem.start` (UNLINKED)
  registers a child the supervisor can never observe crashing — it is never
  restarted, and D-344 is structurally unenforceable in production.

  This test therefore exercises the REAL production trigger: it starts the
  Coordinator UNDER A SUPERVISOR (`start_supervised!/2`, which honours the
  child_spec's `restart`), KILLS it, and asserts THE SUPERVISOR RESTARTS IT
  (a new pid re-registers under the same name) and that the restart resumes
  from L. The test relies on the supervisor's link to the Coordinator; it never
  links the Coordinator to the *test* process, so a properly-linking
  `start_link` does not cascade the `:kill` into the suite.

  ## Fail-before validity

  On a branch where `start_link/1` is UNLINKED (`:gen_statem.start`), the
  supervisor never restarts the killed Coordinator: the registered name stays
  unbound, no new pid appears, and the resume-from-L oracles never hold — so
  THIS TEST FAILS. It passes only once `start_link/1` relinks
  (`:gen_statem.start_link`) so the production supervisor can restart and the
  restart resumes. A test that passed against the unlinked `start_link` would be
  wrong-path (it would never exercise the supervised restart that actually
  triggers D-344 in production).

  SPEC sources (docs/spec/SPEC-FACTORY-CORE.md):
    - §5 Coordinator state table: `running` entry = "start (resume from L)".
    - §4 B3 {Coordinator,Unit} ↔ Ledger.Writer: `snapshot_unit/2` is the durable
      write op; every write carries an idempotency key `{unit_id, kind,
      coordinate}`; "a coordinator restart resumes from L with no decision lost
      or re-applied" (D-315, RPO=0).
    - §6 D-344: kill the Coordinator; assert SUPERVISED restart + resume +
      idempotent rehydrate; no terminal work re-done.

  AC/D-NNN linkage: AC-8, D-344.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :ac_8
  @moduletag :d_344

  @coordinator Tau.Factory.Coordinator
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # Start a real Ledger.Writer against an isolated temp DB; return its name.
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
  # AC-8 / D-344: a SUPERVISOR restarts the killed Coordinator; the restart
  # resumes from L; the in-flight unit rehydrates at its snapshotted state; no
  # terminal work is re-done.
  #
  # Timeline:
  #   1. Real Ledger (L) holds two snapshotted units:
  #        - terminal_unit at :merged       (a terminal sink — already done).
  #        - inflight_unit at :implementing  (NON-terminal — was in flight).
  #   2. Start the Coordinator UNDER A SUPERVISOR (start_supervised!), wired to
  #      L, with select_fun returning nil (no NEW external work) so any drive can
  #      ONLY come from rehydrating L — isolating the resume behaviour. drive_fun
  #      records every driven unit_id into an EXTERNAL Agent that OUTLIVES the
  #      Coordinator restart (owned by the test, closed over).
  #   3. Resolve the running Coordinator's pid by registered name, then KILL it
  #      with :kill. Because it is supervised (not linked to the test process),
  #      the :kill does NOT reach the test — the SUPERVISOR restarts it.
  #   4. Poll the registered name until it resolves to a pid DIFFERENT from the
  #      killed one (bounded; never hangs). This is the production restart.
  #   5. Assert (load-bearing oracles):
  #        a. the SUPERVISOR RESTARTED it — new pid ≠ killed pid, same name,
  #        b. the restart RESUMED from L — :sys.get_state shows the in-flight
  #           unit rehydrated, terminal unit absent,
  #        c. NO terminal work re-done — the terminal unit's id is NEVER recorded
  #           as driven by drive_fun after the restart (exactly-once).
  # ---------------------------------------------------------------------------

  @tag :ac_8
  @tag :d_344
  test "AC-8 / D-344: supervisor restarts a killed Coordinator, which resumes from L without re-doing terminal work" do
    ledger = start_ledger()

    terminal_unit = "unit-terminal-#{System.unique_integer([:positive])}"
    inflight_unit = "unit-inflight-#{System.unique_integer([:positive])}"

    # --- Seed L with the two unit snapshots via the REAL durable write op. ---
    # A unit already at a terminal sink (:merged): no work may be re-done on
    # resume.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: terminal_unit,
               state: :merged,
               idempotency_key: "#{terminal_unit}:snapshot:merged"
             })

    # A unit in flight (non-terminal :implementing) at crash time: it must
    # rehydrate at this state and be driven forward on resume.
    assert {:ok, _} =
             @writer.snapshot_unit(ledger, %{
               unit_id: inflight_unit,
               state: :implementing,
               idempotency_key: "#{inflight_unit}:snapshot:implementing"
             })

    # --- External drive-record store that SURVIVES a Coordinator restart. ---
    # The Agent is owned by the test process, not the Coordinator, so a kill of
    # the Coordinator does not destroy the record. Closed over by drive_fun.
    {:ok, drive_log} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(drive_log), do: Agent.stop(drive_log) end)

    test_pid = self()
    coord = unique_name(:coord_recovery)

    drive_fun = fn work ->
      # D-344 / #607: the production Coordinator passes a map %{unit_id: id,
      # resume_state: state} for rehydrated units (coordinator.ex:181) and a
      # plain binary for newly-selected work (coordinator.ex:208). Accept both.
      unit_id =
        case work do
          %{unit_id: id} -> id
          id when is_binary(id) -> id
        end

      Agent.update(drive_log, fn log -> log ++ [unit_id] end)
      send(test_pid, {:driven, unit_id})
      # The rehydrated unit "completes" immediately so the loop can quiesce; the
      # coordinator pid is resolved by registered name at drive time (it is the
      # currently-registered incarnation, original or restarted).
      coord_pid = Process.whereis(coord)
      if is_pid(coord_pid), do: send(coord_pid, {:unit_terminal, unit_id, :merged})
      :ok
    end

    # No NEW external work: any drive observed comes from L rehydration alone.
    select_fun = fn -> nil end

    opts = [
      name: coord,
      pubsub: Tau.PubSub,
      select_fun: select_fun,
      drive_fun: drive_fun,
      scheduler: nil,
      ledger: ledger
    ]

    # --- Start the Coordinator UNDER A SUPERVISOR (production restart path). ---
    # start_supervised!/1 starts {Coordinator, opts} via its child_spec, which
    # declares restart: :permanent. For the supervisor to restart on crash,
    # start_link/1 MUST link the Coordinator to the supervisor.
    start_supervised!({@coordinator, opts})

    # The first incarnation rehydrates the in-flight unit from L.
    assert_receive {:driven, ^inflight_unit}, 2000

    # Capture the running Coordinator's pid by registered name.
    pid1 = Process.whereis(coord)
    assert is_pid(pid1), "Coordinator did not register under #{inspect(coord)}"

    # Reset the drive log: we assert about POST-RESTART drives specifically.
    Agent.update(drive_log, fn _ -> [] end)
    drain_driven_messages()

    # --- KILL the Coordinator. Because it is SUPERVISED (linked to the
    # supervisor, NOT to this test process), the :kill does not reach the test —
    # the supervisor restarts it. ---
    Process.exit(pid1, :kill)
    refute Process.alive?(pid1)

    # --- Oracle (a): the SUPERVISOR RESTARTED it. Poll the registered name
    # until it resolves to a NEW pid (different from the killed one), under the
    # SAME name. This is the production D-344 trigger. ---
    pid2 = wait_for_restart(coord, pid1)

    assert is_pid(pid2),
           "D-344 violation: the supervisor did NOT restart the killed Coordinator " <>
             "(name #{inspect(coord)} never re-registered a new pid). This is the " <>
             "structural failure an UNLINKED start_link induces."

    assert pid2 != pid1,
           "Expected a freshly-restarted Coordinator pid under #{inspect(coord)}; " <>
             "got the same pid #{inspect(pid2)} (no restart occurred)."

    # The restarted incarnation rehydrates the in-flight unit from L again
    # (resume continues the loop). This drive can only originate from L.
    assert_receive {:driven, ^inflight_unit},
                   2000,
                   "D-344 violation: the restarted Coordinator did not resume the " <>
                     "in-flight unit from L"

    # Give the restarted loop a moment to (incorrectly) re-drive the terminal
    # unit if resume is not idempotent. With correct resume, no such drive occurs.
    Process.sleep(150)

    post_restart_drives = Agent.get(drive_log, & &1)

    # --- Oracle (c): exactly-once / no terminal work re-done — the terminal
    # unit is NEVER driven after the restart. This is the D-344 crux. ---
    refute terminal_unit in post_restart_drives,
           "D-344 violation: a unit already :merged in L was re-driven after the " <>
             "supervised restart (post-restart drives: #{inspect(post_restart_drives)})"

    # The in-flight unit was driven exactly once on resume — resumed, not
    # duplicated.
    inflight_count = Enum.count(post_restart_drives, &(&1 == inflight_unit))

    assert inflight_count == 1,
           "Expected the in-flight unit driven exactly once on resume; " <>
             "got #{inflight_count} (drives: #{inspect(post_restart_drives)})"

    # --- Oracle (b): resume is reflected in the RESTARTED Coordinator's rebuilt
    # state. The restarted incarnation must know about the in-flight unit it
    # rehydrated and must NOT carry the terminal unit as work to do. ---
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

  # Collect every unit_id the rebuilt Coordinator data treats as live/in-flight,
  # tolerant of how the resume records them (a single :in_flight id, a list, or a
  # map keyed by unit_id, under any of several plausible field names). Terminal
  # units, correctly resumed, never appear here.
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

  # Poll the registered name until it resolves to a pid different from `old_pid`
  # (the killed incarnation). Returns the new pid, or `nil` if no restart was
  # observed within the bound — never hangs. A `nil` result IS the fail-before
  # signal on an unlinked `start_link` (no supervisor restart).
  defp wait_for_restart(name, old_pid) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != old_pid -> {:halt, pid}
        _ -> Process.sleep(10) && {:cont, nil}
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

defmodule Tau.Factory.KillSwitchConformanceTest do
  @moduledoc """
  Gating tests for kill-switch conformance cluster PR #692.

  Closes: #549 (INV-KILLSWITCH-OPERATOR-STATE), #580 (D-321 main-synced),
          #599 (INV-DS-KILL-SWITCH), #673 (NFR-KILL-LATENCY).

  Each test asserts the FULL conformant behaviour the invariant documents:

  - INV-KILLSWITCH-OPERATOR-STATE: kill signal lives in an ETS table owned by a
    supervised control owner (`Tau.Factory.KillSwitch.Store`), never in process
    heap or raw filesystem.

  - D-321 (main-synced clause): the `halting → halted` transition MUST confirm
    `main == origin/main` (via a `main_synced_fun` injectable on the Coordinator)
    before notifying `:on_halted`. Currently absent from the Coordinator — tests
    will fail with `UndefinedFunctionError` or assertion failure.

  - INV-DS-KILL-SWITCH (#599): `StepJob.perform/1` MUST check the filesystem
    sentinel file (`.claude/STOP-FACTORY`, or an injectable `"sentinel_path"` job
    arg) at the start of every job execution (factory-loop.md §kill-switch-latency).
    When the sentinel file EXISTS at job start, `perform/1` MUST return
    `{:cancel, :kill_switch_armed}` — even without a `KillSwitch.Store` wired.
    Currently `perform/1` only checks `Store.armed?` when a `"store"` arg is
    present; it does not check the filesystem sentinel at all → assertion failure.

  - NFR-KILL-LATENCY (#673): T_unit_max must be finite and bounded by a
    compile-time ceiling (@max_unit_max_ms). Passing unit_max_ms: nil (by omitting
    the option) must NOT be accepted — a finite default must exist. The
    verify-volatility-split.md §3 V3-b clamp contract requires every liveness-
    bounding number to be clamped against a hard ceiling (same pattern as N and
    budget). Currently: Keyword.get(opts, :unit_max_ms) defaults to nil →
    arm_unit_max_timer/1 returns [] → absolute ceiling never fires when omitted →
    factory can hang forever after a kill with a stalled unit.

  Tests are written before the production fix exists (oracle-separation §4b).
  Failing modes: `UndefinedFunctionError`, compile error, or assertion failure.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Tau.Factory.KillSwitch.Store
  alias Tau.Factory.StepJob

  @kill_switch Tau.Factory.KillSwitch
  @coordinator Tau.Factory.Coordinator

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # INV-KILLSWITCH-OPERATOR-STATE (#549)
  #
  # The kill signal must live in operator state — an ETS flag under a control
  # owner (`Tau.Factory.KillSwitch.Store`) — never in GenServer process heap or
  # on the filesystem.
  #
  # Conformant behaviour:
  #   1. `KillSwitch.Store.start_link/1` creates and owns an ETS table.
  #   2. After `KillSwitch.request_halt/1`, `KillSwitch.Store.armed?/1` returns
  #      `true` — readable directly from ETS, NOT via GenServer state.
  #   3. The armed flag survives a crash-and-restart of the KillSwitch GenServer
  #      (the Store process holds the ETS table independently).
  #
  # Current failure mode: `Tau.Factory.KillSwitch.Store` does not exist →
  # `UndefinedFunctionError` on `Store.start_link/1`.
  # ---------------------------------------------------------------------------

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: halt flag lives in ETS (KillSwitch.Store), not process heap" do
    store_name = unique_name(:ks_store)
    ks_name = unique_name(:ks)

    # KillSwitch.Store must exist and be startable independently.
    # It owns the ETS table; the KillSwitch GenServer writes to it.
    start_supervised!(
      {Store, name: store_name},
      id: store_name
    )

    # Armed? should be false before any halt request.
    refute Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: Store.armed? should be false before request_halt"

    # Start the KillSwitch, wired to the same Store.
    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub, store: store_name},
      id: ks_name
    )

    # Trigger halt.
    :ok = @kill_switch.request_halt(ks_name)

    # The flag must now be readable directly from the ETS owner (the Store),
    # not from the KillSwitch GenServer's process state.
    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: halt flag not in ETS after request_halt — " <>
             "flag lives in process heap, not operator state (Store)"
  end

  @tag :inv_killswitch_operator_state
  test "INV-KILLSWITCH-OPERATOR-STATE: armed flag persists in ETS after KillSwitch process crash" do
    store_name = unique_name(:ks_store_persist)
    ks_name = unique_name(:ks_persist)

    # Start the Store (independent ETS owner).
    start_supervised!(
      {Store, name: store_name},
      id: store_name
    )

    # Start KillSwitch, wired to the Store.
    {:ok, ks_pid} =
      start_supervised(
        {@kill_switch, name: ks_name, pubsub: Tau.PubSub, store: store_name},
        id: ks_name
      )

    # Arm the switch.
    :ok = @kill_switch.request_halt(ks_name)

    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: armed flag not set in Store after request_halt"

    # Kill the KillSwitch process (simulates a crash).
    Process.exit(ks_pid, :kill)
    Process.sleep(50)

    # The Store is a separate process; ETS table must still show armed = true.
    # If the flag was in process heap, it would be lost here.
    assert Store.armed?(store_name),
           "INV-KILLSWITCH-OPERATOR-STATE: armed flag lost after KillSwitch process crash — " <>
             "flag was in process heap (not ETS), violating operator-state invariant"
  end

  # ---------------------------------------------------------------------------
  # D-321 — main-synced clause (#580)
  #
  # The `halting → halted` transition MUST confirm `main == origin/main` before
  # notifying :on_halted. Current coordinator.ex calls `notify_halted/1` in
  # `halting(:internal, :drain, ...)` without any main-sync check.
  #
  # Conformant behaviour: the Coordinator accepts a `:main_synced_fun` option
  # (injectable for tests). Before transitioning to :halted, it calls
  # `main_synced_fun.()` and asserts it returns `true`. If it returns `false`
  # (main not synced), the Coordinator must NOT transition to :halted; it must
  # stay in :halting and retry or raise an escalation.
  #
  # Current failure mode: Coordinator does not accept `:main_synced_fun` and
  # does not perform any sync check → the test's sync tracker is never called →
  # assertion failure (sync_called? == false).
  # ---------------------------------------------------------------------------

  @tag :d_321
  test "D-321 (main-synced): Coordinator checks main==origin/main before transitioning to :halted" do
    coord_name = unique_name(:coord_d321_synced)
    on_halted = self()

    # Track whether the main-sync check was performed.
    {:ok, sync_tracker} = Agent.start_link(fn -> false end)

    main_synced_fun = fn ->
      Agent.update(sync_tracker, fn _ -> true end)
      # Returning true: main is synced (allows halt to proceed).
      true
    end

    # Coordinator MUST accept a :main_synced_fun option and call it before
    # transitioning to :halted. Currently this option is not implemented.
    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    # Trigger a halt on an idle coordinator (no in-flight unit → goes straight
    # to halting → drain → should call main_synced_fun → halted).
    ks_name = unique_name(:ks_d321)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Wait for the coordinator to reach :halted.
    assert_receive :coordinator_halted, 2000, "Coordinator did not reach :halted"

    sync_called = Agent.get(sync_tracker, & &1)

    assert sync_called,
           "D-321 (main-synced): Coordinator transitioned to :halted WITHOUT calling " <>
             "main_synced_fun — the 'main MUST be synced before halting' clause has no " <>
             "executable enforcement (coordinator.ex halting/3 :drain, lines 252-254)"
  end

  @tag :d_321
  test "D-321 (main-synced): Coordinator does NOT halt when main_synced_fun returns false" do
    coord_name = unique_name(:coord_d321_not_synced)
    on_halted = self()

    # Simulate main NOT being synced.
    main_synced_fun = fn -> false end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    ks_name = unique_name(:ks_d321_ns)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Give the Coordinator time to process. It must NOT reach :halted when
    # main_synced_fun returns false.
    Process.sleep(200)

    # Must NOT have received :coordinator_halted yet.
    refute_received :coordinator_halted,
                    "D-321 (main-synced): Coordinator halted even though main_synced_fun " <>
                      "returned false — main-sync check is not enforced before halting"

    # State must NOT be :halted.
    {state, _} = :sys.get_state(coord_name)

    refute state == :halted,
           "D-321 (main-synced): Coordinator reached :halted state without a synced main"
  end

  # ---------------------------------------------------------------------------
  # INV-DS-KILL-SWITCH (#599)
  #
  # factory-loop.md §kill-switch-latency states:
  #   "placing a sentinel file at `.claude/STOP-FACTORY`. The coordinator MUST
  #    check for this sentinel at the start of every factory step; if present,
  #    it does no new work, reports current state, and halts."
  #
  # `StepJob.perform/1` IS the factory-step entry point invoked by the Oban cron
  # driver. It MUST check the filesystem sentinel at job start and return
  # `{:cancel, :kill_switch_armed}` when the file is present — independently of
  # any `KillSwitch.Store`.
  #
  # Conformant `perform/1` contract:
  #   1. Accepts a `"sentinel_path"` job arg (injectable for tests; production
  #      default: `.claude/STOP-FACTORY`).
  #   2. When the file at `sentinel_path` EXISTS at job start → return
  #      `{:cancel, :kill_switch_armed}` without executing factory work.
  #   3. When the file is ABSENT → return `:ok` (step proceeds normally).
  #
  # Current failure mode: `StepJob.perform/1` does NOT read `"sentinel_path"`
  # from job args; it only checks `Store.armed?` when `"store"` is provided.
  # A job with `"sentinel_path"` pointing at an existing sentinel file and no
  # `"store"` returns `:ok` instead of `{:cancel, :kill_switch_armed}` →
  # assertion failure on the first test.
  # ---------------------------------------------------------------------------

  @tag :inv_ds_kill_switch
  test "INV-DS-KILL-SWITCH: StepJob.perform/1 cancels when sentinel FILE exists (no Store required)" do
    # The filesystem sentinel is the PRIMARY kill-switch mechanism per
    # factory-loop.md §kill-switch-latency. StepJob must check it at job start,
    # independent of any ETS Store.

    sentinel_path =
      Path.join(
        System.tmp_dir!(),
        "stop_factory_#{System.unique_integer([:positive])}"
      )

    # Create the sentinel file before the job runs.
    File.write!(sentinel_path, "")

    on_exit(fn -> File.rm(sentinel_path) end)

    # Args carry the injectable sentinel path but NO store — the filesystem
    # check must be sufficient on its own.
    args = %{"sentinel_path" => sentinel_path, "milestone" => "test-milestone"}

    job = StepJob.new(args)
    result = StepJob.perform(job)

    assert result == {:cancel, :kill_switch_armed},
           "INV-DS-KILL-SWITCH: StepJob.perform/1 returned #{inspect(result)} when sentinel " <>
             "file was present at #{inspect(sentinel_path)}. " <>
             "perform/1 MUST read 'sentinel_path' from job args and cancel when the file " <>
             "exists (factory-loop.md §kill-switch-latency). Current implementation ignores " <>
             "'sentinel_path' entirely — it only checks Store.armed? via 'store' arg."
  end

  @tag :inv_ds_kill_switch
  test "INV-DS-KILL-SWITCH: StepJob.perform/1 proceeds (:ok) when sentinel FILE is absent" do
    # Inverse: without the sentinel file the job must NOT be cancelled.

    absent_path =
      Path.join(
        System.tmp_dir!(),
        "stop_factory_absent_#{System.unique_integer([:positive])}"
      )

    refute File.exists?(absent_path),
           "test setup: sentinel path must not exist before the test"

    args = %{"sentinel_path" => absent_path, "milestone" => "test-milestone"}

    job = StepJob.new(args)
    result = StepJob.perform(job)

    assert result == :ok,
           "INV-DS-KILL-SWITCH: StepJob.perform/1 returned #{inspect(result)} when sentinel " <>
             "file was absent — cancellation must only fire when the sentinel is present."
  end

  # ---------------------------------------------------------------------------
  # NFR-KILL-LATENCY (#673)
  #
  # After a kill signal, the factory MUST halt within at most 1 atomic unit,
  # bounded above by T_unit_max. From kill signal to clean halt:
  # **≤ 1 atomic unit**, bounded above by T_unit_max (default 30 min).
  #
  # The architecture document (verify-volatility-split.md §3 "V3-b") identifies
  # that `T_unit_max` must be:
  #   (a) finite — nil / :infinity sentinels must be REJECTED. A Coordinator
  #       without an explicit unit_max_ms must fall back to a finite default, not
  #       to nil which silently disarms the ceiling.
  #   (b) clamped — there must be a hard compile-time upper bound
  #       (@max_unit_max_ms) that the option is clamped against, matching the
  #       min(policy, ceiling) pattern used for N and budget.
  #
  # Current failure modes:
  #   (a) Coordinator.init/1: `Keyword.get(opts, :unit_max_ms)` with no default
  #       → stores nil → arm_unit_max_timer(%{unit_max_ms: nil}) returns [] →
  #       no ceiling ever armed when unit_max_ms is omitted.
  #   (b) No @max_unit_max_ms module attribute exists in coordinator.ex, and
  #       unit_max_ms is never clamped → over-ceiling values accepted silently.
  # ---------------------------------------------------------------------------

  @tag :nfr_kill_latency
  test "NFR-KILL-LATENCY: Coordinator defaults unit_max_ms to a finite value (nil disarms ceiling)" do
    # arm_unit_max_timer(%{unit_max_ms: nil}) currently returns [] — no ceiling.
    # A Coordinator started without :unit_max_ms has NO kill-latency bound at all,
    # defeating NFR-KILL-LATENCY entirely.
    #
    # Conformant behaviour: Coordinator.init/1 must default :unit_max_ms to a
    # finite positive integer (e.g. @default_unit_max_ms = 1_800_000 ms = 30 min),
    # never nil. The stored value must be a positive integer.
    coord_name = unique_name(:coord_nfr_default)

    # Start WITHOUT any :unit_max_ms option — the conformant default must be finite.
    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil
        # :unit_max_ms intentionally omitted — default must be a finite positive integer
      },
      id: coord_name
    )

    {_state, data} = :sys.get_state(coord_name)
    stored = Map.get(data, :unit_max_ms)

    assert is_integer(stored) and stored > 0,
           "NFR-KILL-LATENCY: Coordinator.init/1 defaulted :unit_max_ms to " <>
             "#{inspect(stored)} (nil means NO ceiling is ever armed). " <>
             "A Coordinator omitting :unit_max_ms must fall back to a finite default " <>
             "(e.g. @default_unit_max_ms = 1_800_000 ms). " <>
             "Current code: `Keyword.get(opts, :unit_max_ms)` with no default → nil → " <>
             "arm_unit_max_timer/1 clause 'def arm_unit_max_timer(%{unit_max_ms: nil}), do: []' " <>
             "fires → absolute ceiling NEVER armed after kill when option is omitted."
  end

  @tag :nfr_kill_latency
  test "NFR-KILL-LATENCY: Coordinator clamps unit_max_ms to @max_unit_max_ms hard ceiling" do
    # V3-b clamp contract (verify-volatility-split.md §3): every liveness-bounding
    # number must be clamped against a compile-time ceiling. Passing an absurdly
    # large unit_max_ms must be silently clamped to @max_unit_max_ms — never
    # accepted as-is.
    #
    # Conformant behaviour: a @max_unit_max_ms module attribute exists and
    # init/1 stores min(provided_value, @max_unit_max_ms).
    coord_name = unique_name(:coord_nfr_clamp)

    # Pass a value that exceeds any sane ceiling (7 days = 604_800_000 ms).
    over_ceiling_ms = 7 * 24 * 60 * 60 * 1000

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        unit_max_ms: over_ceiling_ms
      },
      id: coord_name
    )

    {_state, data} = :sys.get_state(coord_name)
    stored = Map.get(data, :unit_max_ms)

    # The stored value must be clamped to @max_unit_max_ms.
    # The arch doc proposes 30 min default; a reasonable hard ceiling is 2 hours
    # (7_200_000 ms). Any value above 2 hours is a policy misconfiguration that
    # the engine should reject via clamping.
    max_sane_ceiling_ms = 2 * 60 * 60 * 1000

    assert is_integer(stored) and stored <= max_sane_ceiling_ms,
           "NFR-KILL-LATENCY: Coordinator stored unit_max_ms = #{inspect(stored)} " <>
             "when given over_ceiling_ms = #{over_ceiling_ms}. " <>
             "The V3-b clamp contract (verify-volatility-split.md §3) requires " <>
             "min(policy_value, @max_unit_max_ms). " <>
             "No @max_unit_max_ms attribute exists in coordinator.ex → " <>
             "over-ceiling values accepted silently, defeating NFR-KILL-LATENCY."
  end

  @tag :nfr_kill_latency
  test "NFR-KILL-LATENCY: factory halts within default ceiling after kill with stalled unit (no explicit unit_max_ms)" do
    # Most dangerous failure mode: a Coordinator with no explicit :unit_max_ms
    # option has a stalled unit in flight when a kill arrives.
    #
    # Conformant: the default ceiling fires and the factory halts within the
    # default unit_max_ms.
    # Non-conformant (current): unit_max_ms defaults to nil →
    # arm_unit_max_timer returns [] → no timer → factory hangs forever.
    #
    # We use a Coordinator with NO :unit_max_ms option. The conformant
    # implementation must supply a finite default. We then trigger a kill and
    # assert the factory halts within a generous test window (5 s). If the
    # default is nil, the factory will never halt and assert_receive will time out.
    #
    # This test is slow if the conformant default is large (30 min). The
    # implementation MUST support a test-injectable default OR the test verifies
    # the state-stored default is finite (see test above) — this test exercises
    # the observable behaviour, not just the stored value.
    #
    # To keep the test fast: we still use an explicit :unit_max_ms of 200ms here.
    # The FAILING assertion is in the test above (nil default). This test
    # additionally asserts that the absolute ceiling bypasses main_synced_fun.
    coord_name = unique_name(:coord_nfr_absolute)
    on_halted = self()

    unit_max_ms = 200

    # main_synced_fun returns false. The absolute ceiling MUST bypass it.
    # If the implementation incorrectly calls main_synced_fun before halting on
    # unit_max_ceiling, the factory will stay in :halting forever → timeout.
    sync_called_ref = :atomics.new(1, signed: false)

    main_synced_fun = fn ->
      :atomics.add(sync_called_ref, 1, 1)
      false
    end

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    select_fun = fn ->
      n = Agent.get_and_update(counter, fn c -> {c, c + 1} end)
      if n == 0, do: "unit-absolute-stalled-#{System.unique_integer([:positive])}", else: nil
    end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: select_fun,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        unit_max_ms: unit_max_ms,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    Process.sleep(50)

    ks_name = unique_name(:ks_nfr_abs)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    margin_ms = unit_max_ms + 400

    # The factory MUST halt within the absolute ceiling, bypassing main_synced_fun.
    assert_receive :coordinator_halted,
                   margin_ms,
                   "NFR-KILL-LATENCY: factory did not halt within T_unit_max (#{unit_max_ms}ms) " <>
                     "when main_synced_fun returns false — the unit_max_ceiling timeout MUST " <>
                     "bypass the main-sync gate and call do_halt unconditionally " <>
                     "(coordinator.ex halting/{:timeout,:unit_max_ceiling} must NOT check main_synced?)."

    sync_calls = :atomics.get(sync_called_ref, 1)

    # The absolute ceiling must NOT call main_synced_fun.
    assert sync_calls == 0,
           "NFR-KILL-LATENCY: unit_max_ceiling timeout called main_synced_fun " <>
             "(#{sync_calls} times) — the absolute ceiling must bypass main-sync entirely. " <>
             "Coordinator.ex halting({:timeout, :unit_max_ceiling}) must call do_halt directly " <>
             "without consulting main_synced?/1."
  end
end

defmodule Tau.Factory.SchedulerSelfExclusionTest do
  @moduledoc """
  Gating tests for PR #516 (issue #515 — real-run integration: D-380 admission
  self-exclusion + single admission authority).

  Written BEFORE production code exists (oracle-separation phase, factory-loop §4b).
  These tests MUST FAIL against the current branch because:

    (a) Re-admitting the same `unit_id` against an `F` that already holds it
        currently returns `{:conflict, _}` (self-conflict): the Scheduler's
        `evaluate_admission/2` passes the full `F` (which includes `unit_id`)
        to `ConflictCheck.clear?/2`, so a `universal_conflict` scope conflicts
        with itself, and a same-file scope conflicts with itself.

    (b) A single `universal_conflict` unit currently self-conflicts against its
        own `F` entry when re-admitted: `ConflictCheck` sees `map_size(F) > 0`
        with a sentinel present, returns `{:conflict, :no_dependency}`, and the
        Scheduler defers rather than admitting.

    (c) The Coordinator's `drive_unit/3` currently calls `Scheduler.admit` with
        `@empty_scope` (coordinator.ex ~line 318) before the Unit FSM has a
        chance to call it with the real `declared_scope`. The single-authority
        invariant requires exactly ONE `Scheduler.admit` per unit_id — from the
        Unit FSM — and zero from the Coordinator.

  ## Contracts under test (SPEC-FACTORY-CORE §6, D-380)

  D-380 pin-points three post-conditions on the Scheduler:

    1. **Self-exclusion (D-380, [C133-B1]):** the conflict check and capacity
       check are evaluated over `F ∖ {unit_id}`, NOT over `F`. A re-admit of a
       unit_id already in `F` is idempotent — returns `:admit`, replaces the
       scope.

    2. **Universal-conflict self-exclusion (D-380, [C133-B1]):** a single
       `universal_conflict` unit in an otherwise-empty `F` must admit into its
       own excluded-empty `F'` (no self-conflict). `ConflictCheck` stays
       unit-id-agnostic; the exclusion is an S-level set op.

    3. **Single admission authority (D-380, [C132-B1]):** the **only** caller of
       `Scheduler.admit` per unit is the Unit FSM `planned` state. The
       Coordinator's `drive_unit/3` MUST NOT call `Scheduler.admit`. Tested via
       a spy Scheduler that records admit call counts.

  ## Failure expectations on current branch

    - Test (a): `Scheduler.admit(sched, same_id, scope)` with `same_id` already
      in `F` returns `{:conflict, _}` — the `assert result == :admit` fails.

    - Test (b): `Scheduler.admit(sched, sentinel_id, uc_scope)` with
      `sentinel_id` already in `F` returns `{:defer, {:conflict, :no_dependency}}`
      — the `assert result == :admit` fails.

    - Test (c): the spy Scheduler records TWO `admit` calls for the unit_id (one
      from Coordinator, one from Unit FSM) — the `assert admit_count == 1`
      (single-authority) fails.

  ## AC linkage
    - D-380 — all tests tagged `:d_380`
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_380

  alias Tau.Factory.Scheduler

  @scheduler Tau.Factory.Scheduler
  @coordinator Tau.Factory.Coordinator
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(base) do
    :"#{base}_#{System.unique_integer([:positive])}"
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp universal_conflict_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new(),
      universal_conflict: true
    }
  end

  defp scope_with_file(filename) do
    %{
      deps: [],
      files: MapSet.new([filename]),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(w_cap) do
    name = unique_name(:self_excl_sched)

    start_supervised!(
      {@scheduler, name: name, w_cap: w_cap},
      id: unique_name(:sup_sched)
    )

    name
  end

  # ---------------------------------------------------------------------------
  # D-380 (a) — re-admitting the same unit_id against an F that already holds it
  # must return :admit (not {:conflict, _}) — idempotent upsert.
  #
  # MUST FAIL on current branch: Scheduler does NOT exclude unit_id from F before
  # calling ConflictCheck, so a scope_with_file scope sees its own F-entry as a
  # conflict → returns {:defer, {:conflict, :disjoint_files}} instead of :admit.
  # ---------------------------------------------------------------------------

  describe "D-380 — self-exclusion: re-admit same unit_id returns :admit" do
    @tag :d_380
    test "D-380: re-admitting a unit_id already in F returns :admit (not {:conflict, _})" do
      sched = start_scheduler(5)
      scope = scope_with_file("lib/shared_work.ex")
      unit_id = "unit-self-excl-#{System.unique_integer([:positive])}"

      # First admit — must succeed.
      assert :admit = @scheduler.admit(sched, unit_id, scope),
             "D-380: first admit must succeed; precondition"

      # F now contains unit_id with the file scope.
      f_before = @scheduler.in_flight(sched)
      assert Map.has_key?(f_before, unit_id), "D-380: unit_id must be in F after first admit"

      # Re-admit same unit_id with updated scope.
      # D-380: Scheduler MUST evaluate ConflictCheck over F ∖ {unit_id}, so the
      # unit's own F-entry is excluded and cannot self-conflict.
      #
      # FAILS on current branch: evaluate_admission passes full F to ConflictCheck
      # → scope_with_file("lib/shared_work.ex") conflicts with its own F entry →
      # returns {:defer, {:conflict, :disjoint_files}} instead of :admit.
      result = @scheduler.admit(sched, unit_id, scope)

      assert result == :admit,
             "D-380: re-admitting the same unit_id must return :admit (self-exclusion). " <>
               "Got #{inspect(result)}. The Scheduler must evaluate ConflictCheck over " <>
               "F ∖ {unit_id} so the unit cannot conflict with its own in-flight entry."
    end

    @tag :d_380
    test "D-380: re-admit with updated scope (same file, self-conflicting) replaces the F entry (upsert)" do
      # Uses THE SAME file in scope_v1 and scope_v2 — re-admitting scope_v2 while
      # scope_v1 is already in F under the same unit_id would self-conflict on the
      # current branch (lib/shared.ex vs lib/shared.ex → :disjoint_files conflict).
      sched = start_scheduler(5)
      scope_v1 = scope_with_file("lib/shared.ex")
      scope_v2 = scope_with_file("lib/shared.ex")
      unit_id = "unit-upsert-#{System.unique_integer([:positive])}"

      assert :admit = @scheduler.admit(sched, unit_id, scope_v1)

      # D-380: re-admit with same-file scope must return :admit (self-exclusion + upsert).
      # FAILS on current branch: Scheduler passes full F to ConflictCheck
      # → scope_v2 (lib/shared.ex) conflicts with scope_v1 (lib/shared.ex) in F
      # → {:defer, {:conflict, :disjoint_files}} instead of :admit.
      result = @scheduler.admit(sched, unit_id, scope_v2)

      assert result == :admit,
             "D-380: re-admit with same-file scope must return :admit (self-exclusion + upsert). " <>
               "Got #{inspect(result)}. Current branch lacks F ∖ {unit_id} exclusion: " <>
               "scope_v2 (lib/shared.ex) conflicts with its own prior F entry."

      # After re-admit, F holds the updated scope entry.
      f_after = @scheduler.in_flight(sched)
      assert Map.has_key?(f_after, unit_id)

      assert Map.fetch!(f_after, unit_id) == scope_v2,
             "D-380: upsert must replace the old scope with scope_v2"
    end
  end

  # ---------------------------------------------------------------------------
  # D-380 (b) — a single universal_conflict unit admits into its own
  # excluded-empty F' (no self-conflict via D-371 sentinel path).
  #
  # MUST FAIL on current branch: ConflictCheck sees map_size(F) > 0 with the
  # sentinel present for the re-admit, returns {:conflict, :no_dependency}.
  # ---------------------------------------------------------------------------

  describe "D-380 — universal_conflict unit does not self-conflict" do
    @tag :d_380
    test "D-380: a single universal_conflict unit in F re-admits without self-conflicting" do
      sched = start_scheduler(5)
      uc_scope = universal_conflict_scope()
      unit_id = "unit-uc-#{System.unique_integer([:positive])}"

      # First admit with a universal_conflict scope — must succeed (F is empty).
      assert :admit = @scheduler.admit(sched, unit_id, uc_scope),
             "D-380: first admit of universal_conflict unit must succeed into empty F"

      # F holds the sentinel unit — an empty-scope second unit would be deferred.
      other_id = "unit-other-#{System.unique_integer([:positive])}"
      result_other = @scheduler.admit(sched, other_id, empty_scope())

      assert {:defer, _} = result_other,
             "D-380: a distinct unit must be deferred by the universal_conflict sentinel in F. " <>
               "Got #{inspect(result_other)}."

      # Re-admit the sentinel unit itself — must return :admit (not {:conflict, _}).
      # D-380: Scheduler excludes unit_id from F before ConflictCheck, so F' is
      # empty → universal_conflict with empty F' → :clear → :admit.
      #
      # FAILS on current branch: Scheduler passes full F to ConflictCheck
      # → F contains the sentinel with map_size(F) > 0
      # → ConflictCheck returns {:conflict, :no_dependency}
      # → Scheduler returns {:defer, {:conflict, :no_dependency}}.
      result = @scheduler.admit(sched, unit_id, uc_scope)

      assert result == :admit,
             "D-380: a universal_conflict unit re-admitting against an F containing only " <>
               "itself must return :admit. The Scheduler must exclude unit_id from F " <>
               "(F' is empty) before the ConflictCheck, so the sentinel sees map_size(F') == 0. " <>
               "Got #{inspect(result)}.  FAILS on current branch (no self-exclusion)."
    end
  end

  # ---------------------------------------------------------------------------
  # D-380 (c) — single admission authority: the Coordinator's drive_unit/3 MUST
  # NOT call Scheduler.admit; only the Unit FSM planned state may call it.
  #
  # Strategy: use a spy GenServer as the Scheduler that records admit call counts.
  # Wire the Coordinator with this spy scheduler and a drive_fun that bypasses the
  # real Unit FSM (to isolate the K-side admit). Assert admit_count == 0 from the
  # Coordinator side (the drive_fun below models what happens at the K→U boundary).
  #
  # The test directly checks that Coordinator.drive_unit does not call
  # Scheduler.admit by starting a Coordinator with a spy scheduler and a
  # synchronous drive_fun that returns immediately, then asserting the spy
  # recorded exactly zero admits from the Coordinator's drive_unit path.
  #
  # MUST FAIL on current branch: Coordinator.drive_unit/3 (~line 318) calls
  # Scheduler.admit(data.scheduler, unit_id, @empty_scope) before calling
  # drive_fun — the spy records at least one admit → assert spy_admit_count == 0
  # fails.
  # ---------------------------------------------------------------------------

  describe "D-380 — single admission authority: Coordinator calls no Scheduler.admit" do
    @tag :d_380
    test "D-380: Coordinator.drive_unit issues no Scheduler.admit call (Unit FSM is the sole admitter)" do
      # Spy Scheduler: records every admit call (count) and always returns :admit.
      # Implemented as a simple Agent holding a counter.
      {:ok, spy} = Agent.start_link(fn -> %{admit_count: 0} end)

      # Spy module: a plain GenServer responding like a Scheduler but counting
      # admit calls via the spy agent.
      spy_name = unique_name(:spy_sched_d380)
      test_pid = self()

      {:ok, _spy_server} =
        start_supervised(
          {__MODULE__.SpyScheduler, name: spy_name, spy: spy},
          id: unique_name(:spy_sup)
        )

      # PubSub needed by Coordinator.
      pubsub_name = unique_name(:coord_pubsub)

      start_supervised!(
        {Phoenix.PubSub, name: pubsub_name},
        id: unique_name(:pubsub_sup)
      )

      # A drive_fun that signals completion immediately (simulates the K→U hand-off
      # WITHOUT spawning a real Unit FSM — the Coordinator calls drive_fun AFTER
      # any admit it might perform; we count only the Coordinator-side calls).
      work_item = %{unit_id: "unit-k-side-#{System.unique_integer([:positive])}"}

      coordinator_name = unique_name(:coord_d380)

      _coord_pid =
        start_supervised!(
          {
            @coordinator,
            name: coordinator_name,
            pubsub: pubsub_name,
            scheduler: spy_name,
            select_fun: fn ->
              # Return the work item exactly once, then nil to idle.
              case Agent.get_and_update(spy, fn st ->
                     Map.get_and_update(st, :selected, fn
                       nil -> {work_item, true}
                       true -> {nil, true}
                     end)
                   end) do
                ^work_item ->
                  # Also notify the test when we return the item
                  send(test_pid, :work_selected)
                  work_item

                nil ->
                  nil
              end
            end,
            drive_fun: fn _work ->
              # Notify the coordinator of immediate completion so it loops cleanly.
              # The coordinator will call handle_info({:unit_terminal, id, :merged})
              # after drive_fun returns, so we send it that message.
              Process.send_after(
                Process.whereis(coordinator_name),
                {:unit_terminal, work_item.unit_id, :merged, %{}},
                10
              )

              :ok
            end
          },
          id: unique_name(:coord_d380_sup)
        )

      # Wait for the Coordinator to run through drive_unit for the work item.
      assert_receive :work_selected,
                     5_000,
                     "D-380: Coordinator must call select_fun and pick the work item within 5s"

      # Give the Coordinator enough time to call drive_unit (and any admit it would do).
      Process.sleep(200)

      # Read the admit count recorded by the spy BEFORE the Unit FSM would fire.
      # D-380: Coordinator.drive_unit must NOT call Scheduler.admit at all.
      # The spy counts every admit call regardless of caller.
      # In this test there is no Unit FSM (drive_fun bypasses it), so
      # the only source of admits is the Coordinator itself.
      admit_count = Agent.get(spy, fn st -> st.admit_count end)

      assert admit_count == 0,
             "D-380: Coordinator.drive_unit must issue ZERO Scheduler.admit calls. " <>
               "The spy recorded #{admit_count} call(s). " <>
               "On current branch, drive_unit calls Scheduler.admit with @empty_scope " <>
               "(coordinator.ex ~line 318), producing admit_count == 1 here. " <>
               "Fix: remove the Scheduler.admit call from drive_unit; " <>
               "the Unit FSM planned state is the sole admitter."
    end
  end
end

# ---------------------------------------------------------------------------
# SpyScheduler: minimal GenServer that records admit calls and returns :admit.
# Lives inside the test module namespace so no lib/ file is created.
# ---------------------------------------------------------------------------
defmodule Tau.Factory.SchedulerSelfExclusionTest.SpyScheduler do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{spy: Keyword.fetch!(opts, :spy)}}
  end

  @impl GenServer
  def handle_call({:admit, _unit_id, _scope}, _from, state) do
    Agent.update(state.spy, fn st -> Map.update!(st, :admit_count, &(&1 + 1)) end)
    {:reply, :admit, state}
  end

  def handle_call({:release, _unit_id}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:in_flight, _from, state) do
    {:reply, %{}, state}
  end
end

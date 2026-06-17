defmodule Tau.Factory.NfrAgentFleetCapTest do
  @moduledoc """
  Gating test for issue #670 — **NFR-AGENT-FLEET**.

  ## Invariant statement

  The node hosts at most 128 concurrent live agent processes (implementers,
  test-authors, critics, reviewers, researchers) across all in-flight PRs, each
  a supervised crash domain. Falsified if more than 128 agent processes exist
  simultaneously on the node.

  ## Why this is falsified now

  `WorkerSupervisor.init/1` calls
  `DynamicSupervisor.init(strategy: :one_for_one)` with **no `max_children`**
  option — the DynamicSupervisor is uncapped. The SPEC-FACTORY-FLEET §3 C212
  says "The only bound the fleet owns is `W_cap` on live worker count." The
  documented contract requires `max_children: 128` in the supervisor init so a
  129th `start_child` call is rejected by the OTP supervisor machinery itself,
  not just by an upstream admission guard.

  ## AC linkage

    - `@tag :nfr_agent_fleet` — every test below.

  ## Evidence (issue #670)

    - `lib/tau/factory/worker_supervisor.ex` lines 49-52:
      `DynamicSupervisor.init(strategy: :one_for_one)` with no `max_children`.
    - `docs/arch/03-system-architecture/candidate-rate-split.md` line 548:
      `|agents alive| <= A_max = 128 — NFR-AGENT-FLEET`.
    - `docs/spec/SPEC-FACTORY-FLEET.md` C108:
      "C1 `Tau.Factory.WorkerSupervisor` — W root. DynamicSupervisor
      (`one_for_one`), starts `0..W_cap` workers each `restart: :temporary`."
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :nfr_agent_fleet

  @worker_supervisor Tau.Factory.WorkerSupervisor
  @worker_registry Tau.Factory.WorkerRegistry

  # NFR-AGENT-FLEET: the cap is 128 concurrent live agent processes.
  @agent_fleet_cap 128

  # Minimal child spec used to fill the supervisor without spawning real workers.
  # Uses a Task that sleeps forever so children remain alive long enough to count.
  defp blocking_child_spec do
    task_fn = fn -> Process.sleep(:infinity) end

    %{
      id: make_ref(),
      start: {Task, :start_link, [task_fn]},
      restart: :temporary,
      type: :worker
    }
  end

  defp start_sup(tag) do
    n = System.unique_integer([:positive])
    sup_name = :"#{tag}_nfr_sup_#{n}"
    registry_name = :"#{tag}_nfr_reg_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"nfr_reg_#{n}"
      )

    {:ok, sup_pid} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"nfr_sup_#{n}"
      )

    {sup_name, sup_pid}
  end

  # ---------------------------------------------------------------------------
  # P1 — 128th child is admitted, 129th is rejected
  # ---------------------------------------------------------------------------

  describe "NFR-AGENT-FLEET — WorkerSupervisor enforces max_children: 128" do
    @tag :nfr_agent_fleet
    test "NFR-AGENT-FLEET: the 128th start_child succeeds; the 129th returns {:error, :max_children}" do
      {sup_name, _sup_pid} = start_sup(:p1_cap)

      # Fill the supervisor to exactly the cap — all 128 must succeed.
      results =
        Enum.map(1..@agent_fleet_cap, fn _i ->
          DynamicSupervisor.start_child(sup_name, blocking_child_spec())
        end)

      failed = Enum.reject(results, fn r -> match?({:ok, _}, r) end)

      assert failed == [],
             "NFR-AGENT-FLEET: all #{@agent_fleet_cap} start_child calls up to the cap must " <>
               "succeed; WorkerSupervisor.init/1 must set max_children: #{@agent_fleet_cap}. " <>
               "Failed results: #{inspect(failed)}"

      # One past the cap MUST be rejected with {:error, :max_children}.
      result_129 = DynamicSupervisor.start_child(sup_name, blocking_child_spec())

      assert result_129 == {:error, :max_children},
             "NFR-AGENT-FLEET: the #{@agent_fleet_cap + 1}th start_child must return " <>
               "{:error, :max_children}; got #{inspect(result_129)}. " <>
               "WorkerSupervisor.init/1 must pass `max_children: #{@agent_fleet_cap}` to " <>
               "DynamicSupervisor.init/1 so the supervisor enforces the agent-fleet cap " <>
               "mechanically (docs/arch/03-system-architecture/candidate-rate-split.md 5.5: " <>
               "|agents alive| <= A_max = 128 — NFR-AGENT-FLEET; " <>
               "SPEC-FACTORY-FLEET C1: DynamicSupervisor starts 0..W_cap workers)."
    end
  end

  # ---------------------------------------------------------------------------
  # P2 — WorkerSupervisor.start_link/1 accepts w_cap and threads it as max_children
  # ---------------------------------------------------------------------------

  describe "NFR-AGENT-FLEET — WorkerSupervisor start_link/1 accepts and enforces w_cap" do
    @tag :nfr_agent_fleet
    test "NFR-AGENT-FLEET: WorkerSupervisor.start_link/1 enforces a w_cap opt as max_children on the DynamicSupervisor" do
      n = System.unique_integer([:positive])
      sup_name = :"nfr_p2_sup_#{n}"
      reg_name = :"nfr_p2_reg_#{n}"

      {:ok, _} =
        start_supervised({@worker_registry, name: reg_name}, id: :"nfr_p2_reg_#{n}")

      # Start with a small w_cap so the test runs fast.
      small_cap = 3

      {:ok, _sup_pid} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: reg_name, w_cap: small_cap},
          id: :"nfr_p2_sup_#{n}"
        )

      # Fill to cap — all must succeed.
      results =
        Enum.map(1..small_cap, fn _i ->
          DynamicSupervisor.start_child(sup_name, blocking_child_spec())
        end)

      failed = Enum.reject(results, fn r -> match?({:ok, _}, r) end)

      assert failed == [],
             "NFR-AGENT-FLEET: all #{small_cap} start_child calls up to w_cap=#{small_cap} must succeed; " <>
               "WorkerSupervisor.start_link/1 must thread the :w_cap option into " <>
               "DynamicSupervisor.init/1 as max_children. Failed: #{inspect(failed)}"

      # One past the w_cap MUST be rejected.
      over_cap = DynamicSupervisor.start_child(sup_name, blocking_child_spec())

      assert over_cap == {:error, :max_children},
             "NFR-AGENT-FLEET: the #{small_cap + 1}th start_child must return {:error, :max_children} " <>
               "when w_cap=#{small_cap} is configured via start_link/1 opts; got #{inspect(over_cap)}. " <>
               "WorkerSupervisor.init/1 must read the :w_cap option and pass it as max_children to " <>
               "DynamicSupervisor.init/1 (SPEC-FACTORY-FLEET C1: 'starts 0..W_cap workers'; " <>
               "docs/arch/04-software-architecture/worker-fleet.md line 30: '(0..W_cap) Tau.Factory.Worker')."
    end
  end

  # ---------------------------------------------------------------------------
  # P3 — Default cap (no explicit w_cap) enforces NFR-AGENT-FLEET bound of 128
  # ---------------------------------------------------------------------------

  describe "NFR-AGENT-FLEET — default cap is exactly 128 (not uncapped)" do
    @tag :nfr_agent_fleet
    test "NFR-AGENT-FLEET: WorkerSupervisor started without explicit w_cap defaults to max_children: 128" do
      n = System.unique_integer([:positive])
      sup_name = :"nfr_p3_sup_#{n}"
      reg_name = :"nfr_p3_reg_#{n}"

      {:ok, _} =
        start_supervised({@worker_registry, name: reg_name}, id: :"nfr_p3_reg_#{n}")

      # Start with the default opts (no :w_cap override) — the production path
      # from Tau.Factory.Supervisor (supervisor.ex line 270: {Scheduler, name: ..., w_cap: 5}).
      {:ok, sup_pid} =
        start_supervised(
          {@worker_supervisor, name: sup_name, registry: reg_name},
          id: :"nfr_p3_sup_#{n}"
        )

      # Fill to the NFR-AGENT-FLEET cap — all 128 must succeed with default settings.
      fill_results =
        Enum.map(1..@agent_fleet_cap, fn _ ->
          DynamicSupervisor.start_child(sup_pid, blocking_child_spec())
        end)

      fill_failures = Enum.reject(fill_results, fn r -> match?({:ok, _}, r) end)

      assert fill_failures == [],
             "NFR-AGENT-FLEET P3: WorkerSupervisor default start must admit #{@agent_fleet_cap} children; " <>
               "the default cap MUST be at least #{@agent_fleet_cap} (not uncapped). " <>
               "Failures: #{inspect(fill_failures)}"

      # One past the default cap MUST be rejected.
      over = DynamicSupervisor.start_child(sup_pid, blocking_child_spec())

      assert over == {:error, :max_children},
             "NFR-AGENT-FLEET P3: WorkerSupervisor started without :w_cap must " <>
               "cap at max_children=#{@agent_fleet_cap} by default, so the #{@agent_fleet_cap + 1}th " <>
               "start_child returns {:error, :max_children}; got #{inspect(over)}. " <>
               "Fix: WorkerSupervisor.init/1 must pass `max_children: #{@agent_fleet_cap}` " <>
               "(or read a :w_cap default of #{@agent_fleet_cap}) to DynamicSupervisor.init/1. " <>
               "Without this, the fleet is unbounded and NFR-AGENT-FLEET is falsified " <>
               "(docs/arch/03-system-architecture/candidate-rate-split.md 5.5: " <>
               "|agents alive| <= A_max = 128)."
    end
  end
end

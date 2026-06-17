defmodule Tau.Factory.EgressFr72ComposedChainTest do
  @moduledoc """
  Gating tests for FR-7.2 (issue #661).

  ## Audit Finding

  FR-7.2: "Outbound provider load MUST be governed by the composed chain
  rate-limiter -> circuit-breaker -> budget-ledger (NFR-EGRESS) in that
  load-bearing order. Falsified by sustained 429/5xx-driven failures under
  documented limits."

  Verdict: NOT-YET-BUILT. Evidence:

  1. `Tau.Factory.Egress` was absent (`find -iname '*egress*'` returned nothing;
     `grep 'Egress' lib/` returned zero references).
  2. `RateLimiter.acquire` was called INSIDE `stream/3` (anthropic.ex:119),
     i.e. INSIDE the `CircuitBreaker.call` wrapper — runtime order was
     circuit-breaker -> rate-limiter, INVERTED from the required order.
  3. `Budget.Owner.budget_precheck/2` was an admission-time pre-check in the
     factory Scheduler (scheduler.ex:106), absent from the provider egress path.

  All three findings have the same root cause: the three guards ran as independent
  constructs in the wrong order, rather than as a single composed egress chain.

  ## What this test suite asserts (FR-7.2 boundary)

  The boundary this invariant governs is `Tau.Factory.Egress.call/3` — the single
  chokepoint mandated by SPEC-FACTORY-GOV §4 B1 / D-351 / NFR-EGRESS.

  Tests in this file are specifically tagged `:fr_7_2` to satisfy the gate-5.1
  AC-to-test linkage requirement for FR-7.2 (issue #661).

  ### FR-7.2 / Test 1 — composed-chain existence (all three layers in one call)

  A single `Egress.call/3` invocation exercises all three guards in sequence and
  verifies the provider is called when all pass.

  ### FR-7.2 / Test 2 — composed-chain order: RL runs before CB (refutes inversion)

  With a stub RateLimiter that immediately rejects AND an open CircuitBreaker,
  `Egress.call/3` must return `{:error, :rate_limited}` — not `{:error, :circuit_open}`.
  This proves RL runs before CB, directly refuting the FR-7.2 inversion evidence
  (anthropic.ex:119: RateLimiter.acquire ran inside CircuitBreaker.call).

  ### FR-7.2 / Test 3 — Budget guard denies exhausted budgets via admit/2 (not read-only precheck)

  SPEC-FACTORY-GOV §4 B4 specifies `admit(owner, est_cost)` as the egress
  boundary — an ETS read + reserve (`update_counter`), NOT a read-only precheck.
  The read-only `budget_precheck/2` does not decrement the ETS counter; multiple
  concurrent callers can all pass simultaneously when each sees N > 0 before any
  decrement has occurred — violating the budget ceiling (D-351 / NFR-BUDGET-PRECISION).

  This test starts a real `Budget.Owner` with a limited token budget, makes a
  successful `Egress.call/3`, and then asserts the budget was DECREMENTED (i.e.
  `admit/2` was called, not just `budget_precheck/2`). It FAILS against an
  implementation that uses read-only `budget_precheck/2` because no decrement occurs.

  ### FR-7.2 / Test 4 — Budget guard denies when budget is exhausted (admission-path integration)

  When `admit/2` has exhausted the budget, the next `Egress.call/3` returns
  `{:error, :budget_exhausted}` and the provider is NOT called.

  ## Failure expectation on the current branch

  - Tests 1, 2, 4: PASS (Tau.Factory.Egress exists and the basic chain/order/denial
    logic is correct). If these fail, Tau.Factory.Egress is absent or the order
    is inverted.

  - Test 3: FAILS because the current `check_budget/1` uses `Budget.Owner.budget_precheck/2`
    (read-only ETS lookup; no decrement) rather than `Budget.Owner.admit/2` (ETS
    read + reserve via `update_counter`). After a successful `Egress.call/3`,
    the budget ETS counter remains unchanged — the assertion that the budget was
    decremented therefore fails. This test is the ORACLE for the admit/2 reservation
    contract (SPEC-FACTORY-GOV §4 B4).

  ## AC / invariant linkage

  - FR-7.2 (issue #661) — every test tagged `:fr_7_2`
  - D-351 (composed-egress load-bearing order, SPEC-FACTORY-GOV §4 B1) — every test tagged `:d_351`
  """

  use ExUnit.Case, async: true

  alias Tau.CircuitBreaker.Store
  alias Tau.Factory.Budget.Owner, as: BudgetOwner

  @moduletag :fr_7_2
  @moduletag :d_351
  @moduletag :capture_log

  @egress Tau.Factory.Egress

  # ---------------------------------------------------------------------------
  # Stub providers — each has a unique atom so CB rows do not collide.
  # ---------------------------------------------------------------------------

  defmodule StubProviderFr72Happy do
    @moduledoc false
    @behaviour Tau.Provider

    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, [%{type: :done}]}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-fr72-happy"
    def models, do: ["stub-fr72-happy-model"]
  end

  defmodule StubProviderFr72RlReject do
    @moduledoc false
    @behaviour Tau.Provider

    # CB will be tripped open; RL stub immediately rejects.
    # Expected result: {:error, :rate_limited} -- RL runs before CB.
    def stream(_messages, _opts, _ctx), do: {:ok, []}
    def context_window(_model), do: 200_000
    def name, do: "stub-fr72-rl-reject"
    def models, do: ["stub-fr72-rl-reject-model"]
  end

  defmodule StubProviderFr72BudgetAdmit do
    @moduledoc false
    @behaviour Tau.Provider

    # Used for the budget-admit reservation tests.
    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, [%{type: :done}]}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-fr72-budget-admit"
    def models, do: ["stub-fr72-budget-admit-model"]
  end

  defmodule StubProviderFr72CbOpen do
    @moduledoc false
    @behaviour Tau.Provider

    # CB is tripped open, no RL registered.
    # Expected result: {:error, :circuit_open} -- CB runs in second slot.
    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, []}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-fr72-cb-open"
    def models, do: ["stub-fr72-cb-open-model"]
  end

  # ---------------------------------------------------------------------------
  # Stub RateLimiter: always rejects immediately (simulates bucket-empty).
  # Registered via the same Registry key that RateLimiter.acquire/3 consults.
  # ---------------------------------------------------------------------------

  defmodule StubRateLimiterFr72AlwaysReject do
    @moduledoc false
    use GenServer

    def start_link(provider) do
      name = {:via, Registry, {Tau.Providers.RateLimiter.Registry, provider}}
      GenServer.start_link(__MODULE__, %{}, name: name)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:acquire, _est_tokens, _timeout, _started_at}, _from, state) do
      {:reply, {:error, :rate_limit_timeout}, state}
    end

    def handle_call(_req, _from, state), do: {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_call_recorder do
    {:ok, agent} = Agent.start_link(fn -> :not_called end)
    agent
  end

  defp stream_called?(agent), do: Agent.get(agent, & &1) == :called

  defp trip_breaker(provider) do
    threshold = Tau.CircuitBreaker.default_failure_threshold()

    for _ <- 1..(threshold + 2) do
      Tau.CircuitBreaker.call(provider, [], fn -> {:error, :stub_failure} end)
    end

    :open = Store.state_for(provider)
    :ok
  end

  # Reads the :tokens counter from the Budget.Owner's ETS table directly.
  # The table name is the same atom as the Owner's registered name
  # (Budget.Owner creates an ETS table named after itself).
  defp budget_remaining(owner_name) do
    case :ets.lookup(owner_name, :tokens) do
      [{:tokens, remaining}] -> remaining
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Test 1 — composed-chain existence: all three layers pass, provider called
  # ---------------------------------------------------------------------------

  describe "FR-7.2 -- composed egress chain existence: all three layers pass in one call" do
    @tag :fr_7_2
    @tag :d_351
    test "FR-7.2 / Test 1: Egress.call/3 composes all three guards; provider invoked when all pass" do
      # Arrange: no RateLimiter registered (Layer 1 passes).
      # CircuitBreaker is :closed (Layer 2 passes -- fresh breaker).
      # No ctx[:budget_owner] (Layer 3 skipped -- no constraint).
      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-fr72-happy-model"}}
      ctx = %{call_recorder: recorder}

      # Act: call the real Egress chokepoint.
      result = @egress.call(StubProviderFr72Happy, req, ctx)

      # Assert: all guards passed -> provider stream/3 was called -> {:ok, _}.
      assert {:ok, _} = result,
             "FR-7.2 / Test 1: expected {:ok, _} when all three egress guards pass, " <>
               "got: #{inspect(result)}. If Tau.Factory.Egress does not exist, this " <>
               "is the NOT-YET-BUILT state from the FR-7.2 audit finding."

      assert stream_called?(recorder),
             "FR-7.2 / Test 1: provider stream/3 was NOT called despite all three guards passing. " <>
               "The composed Egress chain must route to the provider when all guards clear."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 -- correct composition order: RL runs before CB (refutes the inversion)
  # ---------------------------------------------------------------------------

  describe "FR-7.2 -- composed chain order: rate-limiter runs before circuit-breaker" do
    @tag :fr_7_2
    @tag :d_351
    test "FR-7.2 / Test 2: {:error, :rate_limited} when RL rejects and CB is open -- RL runs first (correct order)" do
      # Arrange: trip the breaker open for StubProviderFr72RlReject.
      :ok = trip_breaker(StubProviderFr72RlReject)

      # Arrange: register a stub RL that immediately rejects.
      {:ok, _rl_pid} =
        start_supervised({StubRateLimiterFr72AlwaysReject, StubProviderFr72RlReject})

      req = %{messages: [], opts: %{model: "stub-fr72-rl-reject-model"}}

      # Act: call the real Egress chokepoint.
      result = @egress.call(StubProviderFr72RlReject, req, %{})

      # Assert: RL runs first -> {:error, :rate_limited} (not {:error, :circuit_open}).
      #
      # The FR-7.2 audit finding (evidence item 2) stated RateLimiter.acquire ran
      # INSIDE CircuitBreaker.call at anthropic.ex:119 -- runtime order was
      # circuit-breaker -> rate-limiter (INVERTED). If still inverted, CB is
      # consulted first and returns {:error, :circuit_open}.
      #
      # {:error, :rate_limited} proves the correct order: RL ran first and rejected
      # before CB was consulted -- directly refuting the inversion evidence.
      assert {:error, :rate_limited} = result,
             "FR-7.2 / Test 2: expected {:error, :rate_limited} (RateLimiter runs first, " <>
               "correct composed-chain order per NFR-EGRESS) but got #{inspect(result)}. " <>
               "If {:error, :circuit_open} is returned, the inverted order from FR-7.2 " <>
               "evidence item 2 is still present."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 -- Budget guard uses admit/2 (reservation), not read-only precheck
  #
  # FAILS against current implementation:
  # check_budget/1 calls Budget.Owner.budget_precheck/2 (read-only; no decrement).
  # SPEC-FACTORY-GOV §4 B4 specifies admit(owner, est_cost) -- an ETS read +
  # reserve via update_counter. The test asserts the budget counter is decremented
  # after a successful Egress.call/3, which is only true if admit/2 is called.
  # ---------------------------------------------------------------------------

  describe "FR-7.2 -- Budget guard calls admit/2 (reserves budget), not read-only precheck" do
    @tag :fr_7_2
    @tag :d_351
    test "FR-7.2 / Test 3: budget counter is DECREMENTED after successful Egress.call/3 (admit/2 semantics, not precheck)" do
      # Start a real Budget.Owner with 1000 token budget.
      # Budget.Owner creates an ETS table named after its registered name so
      # budget_remaining/1 can read it directly.
      owner_name = :"fr72_budget_admit_#{System.unique_integer([:positive])}"

      # Start a Ledger.Writer in-memory so Budget.Owner can durably record debits.
      writer_name = :"#{owner_name}_ledger_writer"

      {:ok, _writer} =
        start_supervised({Tau.Factory.Ledger.Writer, [db_path: ":memory:", name: writer_name]})

      {:ok, _owner_pid} =
        start_supervised(
          {BudgetOwner,
           [
             ledger: writer_name,
             totals: %{tokens: 1000},
             name: owner_name
           ]}
        )

      # Confirm starting budget.
      assert budget_remaining(owner_name) == 1000,
             "FR-7.2 / Test 3 setup: expected 1000 tokens before call, " <>
               "got: #{inspect(budget_remaining(owner_name))}"

      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-fr72-budget-admit-model"}}
      # ctx carries budget_owner so Egress uses the real Budget.Owner (B4 path).
      ctx = %{budget_owner: owner_name, call_recorder: recorder}

      # Act: call through the real Egress chokepoint with budget constraints active.
      result = @egress.call(StubProviderFr72BudgetAdmit, req, ctx)

      # Assert: provider was called (all guards passed).
      assert {:ok, _} = result,
             "FR-7.2 / Test 3: expected {:ok, _} with budget=1000, got: #{inspect(result)}"

      assert stream_called?(recorder),
             "FR-7.2 / Test 3: provider stream/3 was NOT called despite sufficient budget"

      # Assert: budget counter was DECREMENTED.
      #
      # SPEC-FACTORY-GOV §4 B4: `admit(owner, est_cost)` performs an ETS
      # `update_counter` reservation. After a successful call, the budget
      # counter must be less than the starting 1000.
      #
      # FAILURE MODE (current implementation): Egress.check_budget/1 calls
      # Budget.Owner.budget_precheck/2 (a read-only lookup with no decrement).
      # The budget counter remains at 1000 after the call. This assert therefore
      # FAILS -- the read-only precheck does not satisfy the B4 reservation contract.
      remaining = budget_remaining(owner_name)

      assert remaining != nil,
             "FR-7.2 / Test 3: budget ETS table has no :tokens entry after Egress.call/3"

      assert remaining < 1000,
             "FR-7.2 / Test 3: SPEC-FACTORY-GOV §4 B4 violated -- budget counter was NOT " <>
               "decremented after successful Egress.call/3 (remaining=#{remaining}, expected < 1000). " <>
               "The current implementation uses Budget.Owner.budget_precheck/2 (read-only) " <>
               "instead of Budget.Owner.admit/2 (ETS read + update_counter reservation). " <>
               "admit/2 must be called to satisfy the B4 contract: " <>
               "admit(owner, est_cost) :: :ok | {:error, :budget_exhausted}. " <>
               "Without reservation, concurrent callers can all pass budget_precheck simultaneously " <>
               "and collectively exceed the budget ceiling (D-351 / NFR-BUDGET-PRECISION violation)."
    end

    @tag :fr_7_2
    @tag :d_351
    test "FR-7.2 / Test 4: {:error, :budget_exhausted} when real Budget.Owner has 0 tokens -- Budget deny in composed chain" do
      # Start a real Budget.Owner with 0 token budget (exhausted from the start).
      owner_name = :"fr72_budget_exhausted_#{System.unique_integer([:positive])}"
      writer_name = :"#{owner_name}_ledger_writer"

      {:ok, _writer} =
        start_supervised({Tau.Factory.Ledger.Writer, [db_path: ":memory:", name: writer_name]})

      {:ok, _owner_pid} =
        start_supervised(
          {BudgetOwner,
           [
             ledger: writer_name,
             totals: %{tokens: 0},
             name: owner_name
           ]}
        )

      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-fr72-budget-admit-model"}}
      ctx = %{budget_owner: owner_name, call_recorder: recorder}

      # Act: Egress.call with exhausted Budget.Owner.
      result = @egress.call(StubProviderFr72BudgetAdmit, req, ctx)

      # Assert: Budget guard denies -> {:error, :budget_exhausted}.
      # The FR-7.2 audit finding (evidence item 3) stated Budget was admission-time
      # only (scheduler.ex:106), absent from the egress path. If still absent,
      # the provider is called despite exhausted budget and returns {:ok, _}.
      assert {:error, :budget_exhausted} = result,
             "FR-7.2 / Test 4: expected {:error, :budget_exhausted} (Budget guard in egress " <>
               "path, SPEC-FACTORY-GOV §4 B1 / D-351) but got #{inspect(result)}. " <>
               "If {:ok, _} is returned, the Budget guard is absent from the egress path."

      refute stream_called?(recorder),
             "FR-7.2 / Test 4: provider stream/3 was invoked despite exhausted Budget.Owner -- " <>
               "the composed egress chain must short-circuit at Layer 3 (Budget) before provider."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5 -- CircuitBreaker in second slot: denies after RL passes, no call made
  # ---------------------------------------------------------------------------

  describe "FR-7.2 -- CircuitBreaker is the second layer; denies without calling provider" do
    @tag :fr_7_2
    @tag :d_351
    test "FR-7.2 / Test 5: {:error, :circuit_open} when CB is open and no RL -- CB in second slot, provider NOT called" do
      # Arrange: trip the breaker open for StubProviderFr72CbOpen.
      :ok = trip_breaker(StubProviderFr72CbOpen)

      # No RateLimiter registered -> Layer 1 passes.
      # CircuitBreaker is :open -> Layer 2 DENIES.
      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-fr72-cb-open-model"}}
      ctx = %{call_recorder: recorder}

      result = @egress.call(StubProviderFr72CbOpen, req, ctx)

      assert {:error, :circuit_open} = result,
             "FR-7.2 / Test 5: expected {:error, :circuit_open} (CB in second slot) " <>
               "but got #{inspect(result)}."

      refute stream_called?(recorder),
             "FR-7.2 / Test 5: provider stream/3 was invoked despite open CircuitBreaker -- " <>
               "SPEC-FACTORY-GOV §4 B3: :open breaker must short-circuit with no call made."
    end
  end
end

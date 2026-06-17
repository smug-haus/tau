defmodule Tau.Factory.EgressOrderTest do
  @moduledoc """
  Gating tests for INV-EGRESS-ORDER (issue #548).

  ## Invariant

  INV-EGRESS-ORDER: "The egress chain MUST execute guards in the fixed order:
  RateLimiter → CircuitBreaker → Budget → Finch pool. Falsified if any guard
  is skipped, reordered, or executed concurrently with another guard in the
  chain for the same request."
  (SPEC-FACTORY-GOV §4 B1, §3 C204-B1, D-351)

  ## What is tested

  The load-bearing order is observable via the **rejection outcome** when two
  guards would both reject for the same request:

  - **Test 1 (rate_limited ≺ circuit_open):** a provider whose CircuitBreaker
    is `:open` AND whose RateLimiter stub immediately rejects must return
    `{:error, :rate_limited}` — NOT `{:error, :circuit_open}`. This proves
    RateLimiter ran first (rejected before the CircuitBreaker was consulted).
    The absence of a `[:tau,:circuit_breaker,:open]` telemetry event confirms
    the CircuitBreaker was never reached.

  - **Test 2 (rate_limiter passes → circuit_open reached):** same provider
    with `:open` breaker but NO rate-limiter registered (acquire returns `:ok`
    immediately) must return `{:error, :circuit_open}`. This proves
    CircuitBreaker runs in the second slot and is correctly reached after
    RateLimiter passes.

  Together these two tests pin the `RateLimiter → CircuitBreaker` ordering.

  ## Failure expectation on current branch

  On the wave/governance-conformance branch at the time this test was written,
  `Tau.Factory.Egress` already exists (implemented in the prior commit for
  INV-EGRESS-CHOKEPOINT / D-351). However, the INV-EGRESS-ORDER invariant
  requires a specific ordering that the existing implementation may or may not
  satisfy. If it does satisfy it, the mutation check (Gate 5.3) will catch a
  future ordering regression. If it does not, these tests fail immediately.

  Additionally, both tests are written to fail if `Tau.Factory.Egress` is
  absent (UndefinedFunctionError on `@egress.call/3`).

  ## Stub RateLimiter

  Rather than starting a real `Tau.Providers.RateLimiter` GenServer (which
  requires 30s to time out), we register a minimal stub GenServer under
  `Tau.Providers.RateLimiter.Registry` for the test provider atom. The stub
  handles `{:acquire, _, _, _}` and immediately replies
  `{:error, :rate_limit_timeout}`, as `RateLimiter.acquire/3` would return
  `{:error, :rate_limited}` to callers after a timeout.

  The stub is registered via `{:via, Registry, {...}}` using the same registry
  key `RateLimiter.via/1` uses, so `RateLimiter.acquire/3` finds it in its
  normal lookup path — the real entry point is exercised.

  ## AC / invariant linkage

  - INV-EGRESS-ORDER — every test tagged `:inv_egress_order`
  - D-351 (load-bearing order) — every test tagged `:d_351`
  """

  use ExUnit.Case, async: true

  alias Tau.CircuitBreaker.Store

  @moduletag :inv_egress_order
  @moduletag :d_351
  @moduletag :capture_log

  @egress Tau.Factory.Egress

  # ---------------------------------------------------------------------------
  # Test-specific provider modules — each has a distinct atom so circuit-
  # breaker rows don't collide between tests.
  # ---------------------------------------------------------------------------

  defmodule StubProviderOrderRL do
    @moduledoc false
    @behaviour Tau.Provider

    # Used for the RateLimiter-first test.
    def stream(_messages, _opts, _ctx), do: {:ok, []}
    def context_window(_model), do: 200_000
    def name, do: "stub-order-rl"
    def models, do: ["stub-order-rl-model"]
  end

  defmodule StubProviderOrderCB do
    @moduledoc false
    @behaviour Tau.Provider

    # Used for the CircuitBreaker-reached test.
    def stream(_messages, _opts, _ctx), do: {:ok, []}
    def context_window(_model), do: 200_000
    def name, do: "stub-order-cb"
    def models, do: ["stub-order-cb-model"]
  end

  # ---------------------------------------------------------------------------
  # Stub RateLimiter: a GenServer that handles {:acquire, _, _, _} and
  # immediately replies {:error, :rate_limit_timeout}. Registered under
  # Tau.Providers.RateLimiter.Registry so RateLimiter.acquire/3 finds it.
  # ---------------------------------------------------------------------------

  defmodule StubRateLimiterAlwaysReject do
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

  # Trips the circuit breaker for `provider` via the real CircuitBreaker public
  # API (matching the pattern from egress_chain_test.exs).
  defp trip_breaker(provider) do
    threshold = Tau.CircuitBreaker.default_failure_threshold()

    for _ <- 1..(threshold + 2) do
      Tau.CircuitBreaker.call(provider, [], fn -> {:error, :stub_failure} end)
    end

    :open = Store.state_for(provider)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Test 1 — RateLimiter rejection (rate_limited) precedes CircuitBreaker
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-ORDER — RateLimiter rejects before CircuitBreaker is consulted" do
    @tag :inv_egress_order
    @tag :d_351
    test "INV-EGRESS-ORDER: rate_limited result when both RL and CB would reject — RL runs first" do
      # Arrange: trip the breaker open for StubProviderOrderRL.
      :ok = trip_breaker(StubProviderOrderRL)

      # Arrange: subscribe to [:tau,:circuit_breaker,:open] to detect if CB is consulted.
      test_pid = self()
      handler_id = "egress_order_rl_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :circuit_breaker, :open],
        fn _event, _measurements, metadata, _config ->
          # Only capture events for our test provider to avoid noise from other tests.
          if Map.get(metadata, :provider) == StubProviderOrderRL do
            send(test_pid, {:cb_open_event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Arrange: register the stub RL that always immediately rejects.
      {:ok, _rl_pid} = start_supervised({StubRateLimiterAlwaysReject, StubProviderOrderRL})

      req = %{messages: [], opts: %{model: "stub-order-rl-model"}}

      # Act: call the real Egress chokepoint.
      result = @egress.call(StubProviderOrderRL, req, %{})

      # Assert: RateLimiter runs first — the result is :rate_limited, not :circuit_open.
      # If CircuitBreaker ran first, we would get {:error, :circuit_open} because
      # the breaker is :open. Getting {:error, :rate_limited} proves RL ran first.
      assert {:error, :rate_limited} = result,
             "INV-EGRESS-ORDER violated: expected {:error, :rate_limited} (RateLimiter runs first) " <>
               "but got #{inspect(result)}. If :circuit_open is returned, CircuitBreaker ran before RateLimiter."

      # Assert: no [:tau,:circuit_breaker,:open] event received — CB was not consulted.
      refute_received {:cb_open_event, _},
                      "INV-EGRESS-ORDER violated: [:tau,:circuit_breaker,:open] telemetry event was " <>
                        "emitted even though RateLimiter rejected first — CircuitBreaker was consulted " <>
                        "out of order (should not be reached when RateLimiter rejects)."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — CircuitBreaker is reached (second slot) when RateLimiter passes
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-ORDER — CircuitBreaker is reached in second slot when RateLimiter passes" do
    @tag :inv_egress_order
    @tag :d_351
    test "INV-EGRESS-ORDER: circuit_open result when no RL registered and CB is open — CB runs in second slot" do
      # Arrange: trip the breaker open for StubProviderOrderCB.
      :ok = trip_breaker(StubProviderOrderCB)

      # No RateLimiter registered for StubProviderOrderCB
      # → RateLimiter.acquire/3 returns :ok (no limiter configured).

      req = %{messages: [], opts: %{model: "stub-order-cb-model"}}

      # Act: call the real Egress chokepoint.
      result = @egress.call(StubProviderOrderCB, req, %{})

      # Assert: CircuitBreaker is reached (second slot) and rejects with :circuit_open.
      # This proves the ordering: RateLimiter passed → CircuitBreaker ran second → rejected.
      assert {:error, :circuit_open} = result,
             "INV-EGRESS-ORDER violated: expected {:error, :circuit_open} (CircuitBreaker in second slot) " <>
               "but got #{inspect(result)}. The CircuitBreaker must be reached when RateLimiter passes."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — Budget guard is the THIRD slot (after CircuitBreaker) in the chain
  #
  # D-351 states the chain is "RateLimiter → CircuitBreaker → Budget → Finch pool".
  # The Budget guard MUST deny an exhausted-budget request BEFORE invoking the
  # provider. Currently `check_budget/2` in Egress is a stub returning `:ok`,
  # so even with an exhausted budget the provider is invoked — this test FAILS
  # against the current implementation.
  #
  # Budget.Owner.budget_precheck/2 reads a named ETS table directly (B4 / D-320,
  # bypasses owner mailbox). The table name is passed via `ctx[:budget_owner]`
  # so Egress can locate it without config coupling. This test creates the ETS
  # table manually (simulating an exhausted Budget.Owner) and asserts the expected
  # denial.
  #
  # Note: if the SPEC does not specify `ctx[:budget_owner]` as the Budget.Owner
  # resolution mechanism, this is a SPEC gap that must be closed before the
  # implementer can satisfy this test. The test documents the CONTRACT the
  # implementer must conform to (SPEC-FACTORY-GOV §4 B4 / C204-B1 / D-351).
  # ---------------------------------------------------------------------------

  defmodule StubProviderOrderBudget do
    @moduledoc false
    @behaviour Tau.Provider

    # Used for the Budget-slot test.
    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, []}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-order-budget"
    def models, do: ["stub-order-budget-model"]
  end

  describe "INV-EGRESS-ORDER — Budget guard is third slot; denies exhausted-budget request before provider call" do
    @tag :inv_egress_order
    @tag :d_351
    test "INV-EGRESS-ORDER: budget_exhausted when budget ETS table shows 0 remaining — Budget runs third, provider not called" do
      # Arrange: create an ETS table simulating an exhausted Budget.Owner.
      # Budget.Owner.budget_precheck/2 reads :ets.lookup(name, dimension).
      # A remaining value of 0 (or absent) returns {:exhausted, dimension}.
      budget_table = :egress_order_test_budget_exhausted

      # Create the ETS table with 0 remaining tokens (exhausted budget).
      # The table is owned by the test process and is automatically deleted when
      # the test process exits — no manual cleanup needed.
      :ets.new(budget_table, [:named_table, :public, :set])
      :ets.insert(budget_table, {:tokens, 0})

      # No rate-limiter registered → RateLimiter.acquire returns :ok.
      # CircuitBreaker is closed (no trips) → check passes.
      # Budget ETS shows 0 remaining → should deny.

      recorder_pid = start_call_recorder()

      req = %{messages: [], opts: %{model: "stub-order-budget-model"}}

      # ctx carries the budget_owner name so Egress can locate the ETS table.
      ctx = %{budget_owner: budget_table, call_recorder: recorder_pid}

      # Act: call the real Egress chokepoint.
      result = @egress.call(StubProviderOrderBudget, req, ctx)

      # Assert: Egress returns {:error, :budget_exhausted} — Budget guard (slot 3)
      # denied the request before invoking the provider.
      assert {:error, :budget_exhausted} = result,
             "INV-EGRESS-ORDER violated: expected {:error, :budget_exhausted} (Budget guard, third slot) " <>
               "but got #{inspect(result)}. The current implementation's check_budget/2 stub returns :ok " <>
               "unconditionally — the Budget guard is not enforced."

      # The provider stream/3 must NOT have been called (Budget denied before Finch pool).
      refute stream_called?(recorder_pid),
             "INV-EGRESS-ORDER violated: provider stream/3 was invoked despite exhausted budget — " <>
               "the Budget guard (slot 3) must short-circuit before reaching the Finch pool."
    end

    @tag :inv_egress_order
    @tag :d_351
    test "INV-EGRESS-ORDER: provider is invoked when budget ETS table shows remaining > 0" do
      # Complementary test: when the budget has headroom, the provider IS called.
      budget_table = :egress_order_test_budget_sufficient

      # Table is owned by the test process; automatically deleted on process exit.
      :ets.new(budget_table, [:named_table, :public, :set])
      :ets.insert(budget_table, {:tokens, 1000})

      recorder_pid = start_call_recorder()

      req = %{messages: [], opts: %{model: "stub-order-budget-model"}}
      ctx = %{budget_owner: budget_table, call_recorder: recorder_pid}

      # Act.
      result = @egress.call(StubProviderOrderBudget, req, ctx)

      # All guards pass → provider called → {:ok, _}.
      assert {:ok, _} = result,
             "INV-EGRESS-ORDER: expected {:ok, _} when budget has headroom, got: #{inspect(result)}"

      assert stream_called?(recorder_pid),
             "INV-EGRESS-ORDER: provider stream/3 was NOT called despite passing all guards"
    end
  end
end

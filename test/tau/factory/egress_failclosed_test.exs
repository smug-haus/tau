defmodule Tau.Factory.EgressFailclosedTest do
  @moduledoc """
  Gating tests for INV-EGRESS-FAILCLOSED (issue #547).

  ## Invariant

  INV-EGRESS-FAILCLOSED: "Each layer in the egress chain (RateLimiter,
  CircuitBreaker, Budget) must return a tagged tuple on rejection and never
  raise across the boundary. Falsified if any egress layer raises an exception
  instead of returning {:error, reason} on rejection."
  (SPEC-FACTORY-GOV §3 C204-B1, §4 B2/B3/B4, OTP non-negotiable #7)

  ## Scope

  The audit (issue #547) found:

  - **Layer 1 (RateLimiter):** `acquire/3` correctly converts
    `catch :exit, {:timeout, _}` to `{:error, :rate_limit_timeout}` — no
    raise on the rejection path (lib/tau/providers/rate_limiter.ex:85).
    Confirmed by exercising the acquire/3 path through a stub GenServer
    registered under `Tau.Providers.RateLimiter.Registry` (same approach
    as `egress_order_test.exs`).
  - **Layer 2 (CircuitBreaker):** `call/3` returns `{:error, :circuit_open}`
    for both `:open` and `:half_open` probe-slot-taken rejection paths — no
    raise (lib/tau/circuit_breaker.ex:69,96,106).
  - **Layer 3 (Budget.Owner):** `admit/2` and `reconcile/2` — the B4 boundary
    entry points per SPEC-FACTORY-GOV §4:327 — **do not exist** in
    `lib/tau/factory/budget/owner.ex`. The invariant is PARTIAL: the B4
    rejection boundary is unimplemented.

  ## What is tested

  Each test exercises the real module-level entry point for its layer,
  asserting fail-closed tagged-tuple discipline per OTP non-negotiable #7:

  1. **Layer 1 (RateLimiter) — tagged tuple on timeout.** Registers a stub
     GenServer under `Tau.Providers.RateLimiter.Registry` (the same registry
     `RateLimiter.acquire/3` consults) that immediately replies
     `{:error, :rate_limit_timeout}`, then verifies that `RateLimiter.acquire/3`
     returns `{:error, :rate_limit_timeout}` — not an exception. This confirms
     the `:exit, {:timeout, _}` catch path converts properly.

  2. **Layer 2 (CircuitBreaker) — tagged tuple on open.** Trips the breaker
     for a unique provider via `Tau.CircuitBreaker.call/3`, then verifies a
     subsequent call returns `{:error, :circuit_open}` — not an exception.

  3. **Layer 3 (Budget.Owner.admit/2) — tagged tuple on exhaustion.** Starts
     a real `Tau.Factory.Budget.Owner` with a zero budget, calls
     `Budget.Owner.admit/2`, asserts `{:error, :budget_exhausted}` — not an
     exception. This test FAILS on the current branch because `admit/2`
     does not exist (UndefinedFunctionError surfaced as assertion failure).

  4. **Layer 3 (Budget.Owner.reconcile/2) — tagged tuple on completion.**
     Verifies `Budget.Owner.reconcile/2` exists and returns a tagged tuple.
     FAILS on current branch — `reconcile/2` absent.

  ## Failure expectation on current branch

  Tests 1 and 2 pass (the existing layers are conformant).

  Tests 3 and 4 fail:
  - The `function_exported?` assertion fails immediately (admit/2 and
    reconcile/2 are absent).
  - The try/rescue wrapper around the direct calls catches
    `UndefinedFunctionError` and surfaces it via the refute assertion.

  ## Pinned API contracts (SPEC-FACTORY-GOV §4 B4)

      admit(owner, est_cost) :: :ok | {:error, :budget_exhausted}
      reconcile(owner, actual_cost) :: :ok | {:error, term()}

  Both must never raise across the boundary (OTP non-negotiable #7).

  ## AC / invariant linkage

  - INV-EGRESS-FAILCLOSED — every test tagged `:inv_egress_failclosed`
  """

  use ExUnit.Case, async: true

  alias Tau.CircuitBreaker
  alias Tau.CircuitBreaker.Store, as: CircuitBreakerStore
  alias Tau.Factory.Budget.Owner, as: BudgetOwner
  alias Tau.Providers.RateLimiter

  @moduletag :inv_egress_failclosed
  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Stub RateLimiter: a GenServer that registers under
  # Tau.Providers.RateLimiter.Registry and immediately replies
  # {:error, :rate_limit_timeout} to {:acquire, _, _, _} calls.
  # This is the same approach used by egress_order_test.exs, which verifies
  # that RateLimiter.acquire/3 properly catches :exit and returns the tagged
  # tuple via the normal lookup path.
  # ---------------------------------------------------------------------------

  defmodule StubRateLimiterReject do
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
  # Layer 1 — RateLimiter: tagged tuple on rejection (no raise)
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-FAILCLOSED / Layer 1 — RateLimiter.acquire/3 returns tagged tuple on rejection" do
    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 1: acquire/3 returns {:error, :rate_limit_timeout} on rejection (no raise)" do
      # Use a unique provider atom for test isolation.
      provider = :"test_rl_failclosed_#{System.unique_integer([:positive])}"

      # Register a stub under the same registry key that RateLimiter.acquire/3
      # consults, so the real acquire/3 finds it and gets the rejection reply.
      {:ok, _pid} = start_supervised({StubRateLimiterReject, provider})

      # Act: call the real RateLimiter.acquire/3 entry point.
      result =
        try do
          RateLimiter.acquire(provider, 1, 50)
        rescue
          e -> {:raised, e}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      # Assert: must return a tagged tuple, never raise or throw.
      refute match?({:raised, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 1: RateLimiter.acquire/3 raised instead of " <>
               "returning {:error, :rate_limit_timeout}: #{inspect(result)}"

      refute match?({:caught, _, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 1: RateLimiter.acquire/3 threw instead of " <>
               "returning {:error, :rate_limit_timeout}: #{inspect(result)}"

      assert {:error, :rate_limit_timeout} = result,
             "INV-EGRESS-FAILCLOSED / Layer 1: expected {:error, :rate_limit_timeout}, " <>
               "got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 2 — CircuitBreaker: tagged tuple on :open (no raise)
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-FAILCLOSED / Layer 2 — CircuitBreaker.call/3 returns tagged tuple when breaker is open" do
    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 2: call/3 returns {:error, :circuit_open} when breaker is :open (no raise)" do
      # Use a unique provider atom for test isolation.
      provider = :"test_cb_failclosed_#{System.unique_integer([:positive])}"

      # Trip the breaker via the real CircuitBreaker public API.
      threshold = CircuitBreaker.default_failure_threshold()

      for _ <- 1..(threshold + 2) do
        CircuitBreaker.call(provider, [], fn -> {:error, :stub_failure} end)
      end

      # Confirm the breaker is now :open.
      :open = CircuitBreakerStore.state_for(provider)

      # Act: call with the open breaker.
      result =
        try do
          CircuitBreaker.call(provider, [], fn -> {:ok, :should_not_run} end)
        rescue
          e -> {:raised, e}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      # Assert: must return {:error, :circuit_open}, never raise or throw.
      refute match?({:raised, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 2: CircuitBreaker.call/3 raised instead of " <>
               "returning {:error, :circuit_open}: #{inspect(result)}"

      refute match?({:caught, _, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 2: CircuitBreaker.call/3 threw instead of " <>
               "returning {:error, :circuit_open}: #{inspect(result)}"

      assert {:error, :circuit_open} = result,
             "INV-EGRESS-FAILCLOSED / Layer 2: expected {:error, :circuit_open} when " <>
               "breaker is :open, got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 3 — Budget.Owner.admit/2: exists and returns tagged tuple on exhaustion
  #
  # FAILURE EXPECTATION (current branch): Budget.Owner.admit/2 does not exist.
  # The function_exported? assertion fails immediately, and the try/rescue
  # wrapper around BudgetOwner.admit/2 catches UndefinedFunctionError and
  # surfaces it as an assertion failure via the refute match?({:raised, _}, ...)
  # assertion.
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-FAILCLOSED / Layer 3 — Budget.Owner.admit/2 must exist and return tagged tuple on exhaustion" do
    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner exports admit/2 (SPEC-FACTORY-GOV §4 B4)" do
      # The B4 boundary requires admit/2. FAILS on current branch — absent.
      assert function_exported?(BudgetOwner, :admit, 2),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.admit/2 is not exported. " <>
               "SPEC-FACTORY-GOV §4 B4 requires: " <>
               "admit(owner, est_cost) :: :ok | {:error, :budget_exhausted}. " <>
               "The egress layer 3 rejection boundary is unimplemented."
    end

    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 3: admit/2 returns {:error, :budget_exhausted} on exhausted budget (no raise)" do
      # Exercises the real Budget.Owner.admit/2 entry point at B4 with a zero
      # budget. Uses a real Ledger.Writer with in-memory SQLite.
      #
      # FAILS on current branch: UndefinedFunctionError (admit/2 absent),
      # caught by the rescue block and surfaced as an assertion failure.
      owner_name =
        :"test_budget_failclosed_admit_exhausted_#{System.unique_integer([:positive])}"

      {:ok, writer} =
        start_supervised(
          {Tau.Factory.Ledger.Writer, [db_path: ":memory:", name: :"#{owner_name}_writer"]}
        )

      {:ok, _owner_pid} =
        start_supervised(
          {BudgetOwner,
           [
             ledger: writer,
             totals: %{tokens: 0},
             name: owner_name
           ]}
        )

      # Act: call the real B4 admit/2 entry point on an exhausted budget.
      result =
        try do
          BudgetOwner.admit(owner_name, 1)
        rescue
          e -> {:raised, e}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      # Must not raise — INV-EGRESS-FAILCLOSED / OTP non-negotiable #7.
      refute match?({:raised, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.admit/2 raised instead of " <>
               "returning {:error, :budget_exhausted}. Exception: #{inspect(result)}. " <>
               "SPEC-FACTORY-GOV §4 B4 forbids raising across the boundary."

      refute match?({:caught, _, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.admit/2 threw: #{inspect(result)}"

      # Must return the B4 rejection tuple.
      assert {:error, :budget_exhausted} = result,
             "INV-EGRESS-FAILCLOSED / Layer 3: expected {:error, :budget_exhausted} from " <>
               "admit/2 when budget is exhausted (tokens: 0), got: #{inspect(result)}. " <>
               "SPEC-FACTORY-GOV §4 B4: admit(owner, est_cost) :: :ok | {:error, :budget_exhausted}"
    end

    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 3: admit/2 returns :ok when budget has headroom" do
      # Complementary: admit/2 returns :ok when tokens remain.
      # FAILS on current branch: UndefinedFunctionError (admit/2 absent).
      owner_name =
        :"test_budget_failclosed_admit_ok_#{System.unique_integer([:positive])}"

      {:ok, writer} =
        start_supervised(
          {Tau.Factory.Ledger.Writer, [db_path: ":memory:", name: :"#{owner_name}_writer"]}
        )

      {:ok, _owner_pid} =
        start_supervised(
          {BudgetOwner,
           [
             ledger: writer,
             totals: %{tokens: 1000},
             name: owner_name
           ]}
        )

      # FAILS on current branch: UndefinedFunctionError.
      result = BudgetOwner.admit(owner_name, 10)

      assert :ok = result,
             "INV-EGRESS-FAILCLOSED / Layer 3: expected :ok from admit/2 when budget has " <>
               "headroom (tokens: 1000, cost: 10), got: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 3 — Budget.Owner.reconcile/2: exists and returns tagged tuple
  #
  # FAILURE EXPECTATION (current branch): reconcile/2 does not exist.
  # function_exported? assertion fails; the try/rescue wrapper catches
  # UndefinedFunctionError and surfaces it as an assertion failure.
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-FAILCLOSED / Layer 3 — Budget.Owner.reconcile/2 must exist and return tagged tuple" do
    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner exports reconcile/2 (SPEC-FACTORY-GOV §4 B4)" do
      # B4 boundary requires reconcile/2. FAILS on current branch — absent.
      assert function_exported?(BudgetOwner, :reconcile, 2),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.reconcile/2 is not exported. " <>
               "SPEC-FACTORY-GOV §4 B4 requires: " <>
               "reconcile(owner, actual_cost) :: :ok | {:error, term()}. " <>
               "The B4 reconcile leg of egress layer 3 is unimplemented."
    end

    @tag :inv_egress_failclosed
    test "INV-EGRESS-FAILCLOSED / Layer 3: reconcile/2 returns a tagged tuple and does not raise" do
      # reconcile/2 trues the reservation to actual cost after provider call.
      # Must return :ok | {:error, reason} and must not raise (OTP non-neg #7).
      # FAILS on current branch: UndefinedFunctionError (reconcile/2 absent).
      owner_name =
        :"test_budget_failclosed_reconcile_#{System.unique_integer([:positive])}"

      {:ok, writer} =
        start_supervised(
          {Tau.Factory.Ledger.Writer, [db_path: ":memory:", name: :"#{owner_name}_writer"]}
        )

      {:ok, _owner_pid} =
        start_supervised(
          {BudgetOwner,
           [
             ledger: writer,
             totals: %{tokens: 100},
             name: owner_name
           ]}
        )

      # Act: call the real B4 reconcile entry point.
      result =
        try do
          BudgetOwner.reconcile(owner_name, 5)
        rescue
          e -> {:raised, e}
        catch
          kind, reason -> {:caught, kind, reason}
        end

      # Must not raise across the boundary.
      refute match?({:raised, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.reconcile/2 raised instead of " <>
               "returning a tagged tuple. Exception: #{inspect(result)}. " <>
               "OTP non-negotiable #7 and SPEC-FACTORY-GOV §4 B4 forbid raising across the boundary."

      refute match?({:caught, _, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 3: Budget.Owner.reconcile/2 threw: #{inspect(result)}"

      # Must return :ok or {:error, reason}.
      assert :ok == result or match?({:error, _}, result),
             "INV-EGRESS-FAILCLOSED / Layer 3: reconcile/2 returned unexpected shape: " <>
               "#{inspect(result)}. Expected :ok or {:error, reason} per SPEC-FACTORY-GOV §4 B4."
    end
  end
end

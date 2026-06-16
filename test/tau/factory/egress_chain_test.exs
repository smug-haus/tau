defmodule Tau.Factory.EgressChainTest do
  @moduledoc """
  Gating tests for INV-EGRESS-CHOKEPOINT / D-351 (issue #546).

  Exercises `Tau.Factory.Egress.call/3` — the single outbound chokepoint
  mandated by SPEC-FACTORY-GOV §4 B1 / D-351.

  ## What is tested

  D-351 states: "Egress.call/3 is the single chokepoint; it applies the three
  fail-closed guards in the exact order RateLimiter → CircuitBreaker → Budget,
  each returning a tagged tuple (never raising), and no provider call bypasses
  it."

  This test suite exercises the boundary at `Tau.Factory.Egress.call/3`:

  - **Module existence (INV-EGRESS-CHOKEPOINT)**: `Tau.Factory.Egress` must
    exist and export `call/3`.
  - **Circuit-open short-circuits with no provider call (D-351 / B1 post)**:
    when the circuit breaker is open for the provider, `call/3` returns
    `{:error, :circuit_open}` and the provider `stream/3` is NEVER invoked.
  - **Happy path (D-351)**: when all guards pass, `call/3` invokes the provider
    and returns its `{:ok, stream}`.
  - **Tagged-tuple discipline (D-351 / OTP #7)**: `call/3` never raises across
    the boundary; always returns a tagged tuple.

  ## Failure expectation on current branch

  `Tau.Factory.Egress` does not exist anywhere in lib/ (grep confirms zero
  results). Tests that call `@egress.call/3` will raise
  `UndefinedFunctionError`. The module-existence test fails with an assertion
  error immediately. These are the correct fail-before states for the
  oracle-separation phase (factory-loop §4b).

  ## Pinned API contract (implementer must conform exactly)

  ### `Tau.Factory.Egress.call/3`

      call(provider, req, ctx) :: {:ok, stream} | {:error, reason}

      where reason ∈ {:rate_limited, :circuit_open, :budget_exhausted} ∪ provider
      error terms (SPEC-FACTORY-GOV §4 B1).

  The function applies guards in the load-bearing order:

      RateLimiter.acquire(provider)
        → {:error, :rate_limited} on bucket-empty (no call; visible event)
      CircuitBreaker — consulted before calling the provider
        → {:error, :circuit_open} on :open (no call;
           [:tau,:circuit_breaker,:open] event emitted)
      Budget.Owner.admit(owner, est_cost)
        → {:error, :budget_exhausted} (no call; → E-BUDGET escalation)
      provider.stream(messages, opts, ctx)     ← only if all guards pass

  `req` is a map with at minimum `%{messages: [...], opts: %{...}}`.
  `ctx` is passed through to `provider.stream/3`.

  `call/3` is the ONLY permitted caller of `provider.stream/3` in the factory
  plane (INV-EGRESS-CHOKEPOINT).

  ## AC linkage

  - INV-EGRESS-CHOKEPOINT — every test tagged `:inv_egress_chokepoint`
  - D-351 — every test tagged `:d_351`
  """

  use ExUnit.Case, async: true

  @moduletag :inv_egress_chokepoint
  @moduletag :d_351
  @moduletag :capture_log

  # Runtime module reference — avoids compile-time crash when the module does
  # not yet exist. Tests go through apply(module, :call, args) indirectly via
  # the @egress attribute so the file compiles cleanly on the current branch
  # (where Tau.Factory.Egress is absent).
  @egress Tau.Factory.Egress

  # ---------------------------------------------------------------------------
  # Stub provider — records whether stream/3 was called.
  # ---------------------------------------------------------------------------

  # We define separate stub modules per test group to avoid sharing ETS state
  # (circuit breaker rows are keyed by provider module atom).

  defmodule StubProviderOpen do
    @moduledoc false
    @behaviour Tau.Provider

    # This provider's breaker will be tripped open by the circuit-open tests.
    # stream/3 records the call into ctx[:call_recorder] if present.
    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, []}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-open"
    def models, do: ["stub-open-model"]
  end

  defmodule StubProviderHealthy do
    @moduledoc false
    @behaviour Tau.Provider

    # This provider's breaker is never tripped; used for happy-path tests.
    def stream(_messages, _opts, ctx) do
      if agent = Map.get(ctx, :call_recorder) do
        Agent.update(agent, fn _ -> :called end)
      end

      {:ok, [%{type: :done}]}
    end

    def context_window(_model), do: 200_000
    def name, do: "stub-healthy"
    def models, do: ["stub-healthy-model"]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Returns a fresh agent tracking whether a provider's stream/3 was invoked.
  defp start_call_recorder do
    {:ok, agent} = Agent.start_link(fn -> :not_called end)
    agent
  end

  defp stream_called?(agent), do: Agent.get(agent, & &1) == :called

  # Builds a minimal ctx map understood by the stub providers.
  defp ctx(call_recorder), do: %{call_recorder: call_recorder}

  # Trips the circuit breaker for `provider` by driving enough consecutive
  # failures through the real `Tau.CircuitBreaker.call/3` public API.
  # Uses a thunk that returns {:error, :provider_failure} each time.
  # Default threshold is 5 (Tau.CircuitBreaker.default_failure_threshold/0).
  defp trip_breaker(provider) do
    threshold = Tau.CircuitBreaker.default_failure_threshold()

    for _ <- 1..(threshold + 2) do
      Tau.CircuitBreaker.call(provider, [], fn -> {:error, :stub_failure} end)
    end

    # Sanity: confirm the breaker is now :open via CircuitBreaker.Store.
    :open = Tau.CircuitBreaker.Store.state_for(provider)
    :ok
  end

  # ---------------------------------------------------------------------------
  # INV-EGRESS-CHOKEPOINT — module existence (structural pre-check)
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-CHOKEPOINT — Tau.Factory.Egress module must exist and export call/3" do
    @tag :inv_egress_chokepoint
    @tag :d_351
    test "INV-EGRESS-CHOKEPOINT: Tau.Factory.Egress module is defined and exports call/3" do
      # The most direct expression of INV-EGRESS-CHOKEPOINT: the module must
      # exist and export the chokepoint function. On the current branch,
      # Code.ensure_loaded?/1 returns false, so this test fails immediately.
      assert Code.ensure_loaded?(@egress),
             "Tau.Factory.Egress module does not exist — INV-EGRESS-CHOKEPOINT requires it as the single outbound chokepoint"

      assert function_exported?(@egress, :call, 3),
             "Tau.Factory.Egress.call/3 is not exported — INV-EGRESS-CHOKEPOINT requires it"
    end
  end

  # ---------------------------------------------------------------------------
  # D-351 — circuit-open short-circuits, no provider call made
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-CHOKEPOINT / D-351 — circuit-open blocks provider call" do
    @tag :inv_egress_chokepoint
    @tag :d_351
    test "INV-EGRESS-CHOKEPOINT / D-351: Egress.call/3 returns {:error, :circuit_open} when breaker is open" do
      # Trip the breaker for StubProviderOpen via the real CircuitBreaker API.
      :ok = trip_breaker(StubProviderOpen)

      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-open-model"}}

      # This call will raise UndefinedFunctionError on the current branch
      # because Tau.Factory.Egress does not exist.
      result = @egress.call(StubProviderOpen, req, ctx(recorder))

      # Guard: Egress must return :circuit_open (not pass through to provider).
      assert {:error, :circuit_open} = result,
             "Expected {:error, :circuit_open} from Egress.call/3 when breaker is :open, got: #{inspect(result)}"

      # Critical: provider.stream/3 must NOT have been invoked (D-351 / B1 post).
      refute stream_called?(recorder),
             "Provider stream/3 was invoked despite :open circuit breaker — violates D-351 no-bypass contract"
    end

    @tag :inv_egress_chokepoint
    @tag :d_351
    test "INV-EGRESS-CHOKEPOINT / D-351: Egress.call/3 returns a tagged tuple (never raises) on circuit-open" do
      # OTP non-negotiable #7 / D-351: call/3 must never raise across the boundary.
      :ok = trip_breaker(StubProviderOpen)

      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-open-model"}}

      # Must return a tagged tuple, not raise.
      result =
        try do
          @egress.call(StubProviderOpen, req, ctx(recorder))
        rescue
          e -> {:raised, e}
        end

      refute match?({:raised, _}, result),
             "Egress.call/3 raised instead of returning a tagged tuple — violates OTP non-negotiable #7 and D-351: #{inspect(result)}"

      assert match?({:error, :circuit_open}, result) or match?({:ok, _}, result),
             "Egress.call/3 returned an unexpected shape: #{inspect(result)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-351 / C211 — circuit-open short-circuit emits visible telemetry (#661)
  #
  # FR-7.2 (issue #661) finding: the three layers are uncomposed and independent;
  # no Egress chokepoint exists. D-351 requires that every short-circuit is
  # VISIBLE — a `[:tau,:circuit_breaker,:open]` event must be emitted, never
  # silently dropped (C211: "visible telemetry event AND a tagged error to the
  # caller — never a silent swallow"). This test asserts the telemetry half.
  # ---------------------------------------------------------------------------

  describe "D-351 / C211 — circuit-open short-circuit emits [:tau,:circuit_breaker,:open] telemetry (#661)" do
    @tag :d_351
    test "D-351 / C211 (#661): open-circuit short-circuit emits [:tau,:circuit_breaker,:open] event — not a silent drop" do
      # Subscribe to the circuit-breaker open event.
      test_pid = self()
      handler_id = "egress_c211_test_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :circuit_breaker, :open],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_cb_open, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Trip the breaker for StubProviderOpen.
      :ok = trip_breaker(StubProviderOpen)

      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-open-model"}}

      # This call raises UndefinedFunctionError on the current branch
      # (Tau.Factory.Egress is absent) — the expected fail-before.
      _result = @egress.call(StubProviderOpen, req, ctx(recorder))

      # C211: the open-circuit short-circuit MUST emit a visible
      # [:tau,:circuit_breaker,:open] telemetry event.
      assert_received {:telemetry_cb_open, metadata},
                      "D-351/C211 (#661): open-circuit short-circuit must emit [:tau,:circuit_breaker,:open] telemetry; no event received — silent drop violates C211"

      assert metadata[:provider] == StubProviderOpen,
             "D-351/C211 (#661): telemetry metadata must carry the provider key; got: #{inspect(metadata)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-351 — happy path: all guards pass → provider called
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-CHOKEPOINT / D-351 — happy path routes through Egress to provider" do
    @tag :inv_egress_chokepoint
    @tag :d_351
    test "INV-EGRESS-CHOKEPOINT / D-351: Egress.call/3 with healthy guards invokes provider.stream/3 and returns {:ok, stream}" do
      # StubProviderHealthy has no tripped breaker; all guards pass.
      # This call will raise UndefinedFunctionError on the current branch.
      recorder = start_call_recorder()
      req = %{messages: [], opts: %{model: "stub-healthy-model"}}

      result = @egress.call(StubProviderHealthy, req, ctx(recorder))

      # All guards pass → Egress must invoke the provider.
      assert {:ok, _stream} = result,
             "Expected {:ok, stream} from Egress.call/3 with healthy guards, got: #{inspect(result)}"

      assert stream_called?(recorder),
             "Provider stream/3 was NOT invoked by Egress despite all guards passing — violates D-351 chokepoint contract"
    end
  end
end

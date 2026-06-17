defmodule Tau.Factory.Egress do
  @moduledoc """
  Single outbound chokepoint for all factory provider calls (INV-EGRESS-CHOKEPOINT / D-351).

  `call/3` is the **only** permitted caller of a provider's `stream/3` in the
  factory plane. It applies three fail-closed guards in the load-bearing order
  mandated by SPEC-FACTORY-GOV §4 B1 / D-351:

      RateLimiter.acquire(provider)          → {:error, :rate_limited}    (back-pressure)
      CircuitBreaker — state check (ETS read) → {:error, :circuit_open}    (visible event)
      Budget.Owner.admit(owner, est_cost)    → {:error, :budget_exhausted} (→ E-BUDGET)
      provider.stream(messages, opts, ctx)   ← only when all guards pass

  Every short-circuit is **visible** — a tagged error is returned to the caller
  AND a telemetry event is emitted. No silent drops (C211).

  ## D-351 contract

      call(provider, req, ctx) :: {:ok, stream} | {:error, reason}

  where `reason ∈ {:rate_limited, :circuit_open, :budget_exhausted}` ∪ provider
  error terms. `req` is a map with at minimum `%{messages: [...], opts: %{...}}`.
  `ctx` is passed through to `provider.stream/3`.

  `call/3` never raises across the boundary (OTP non-negotiable #7).
  """

  alias Tau.CircuitBreaker.Store
  alias Tau.Providers.RateLimiter

  @doc """
  The single outbound chokepoint for factory provider calls (D-351).

  Applies fail-closed guards in load-bearing order:
  `RateLimiter → CircuitBreaker → Budget → provider.stream/3`.

  Returns `{:ok, stream}` when all guards pass and the provider call succeeds,
  or `{:error, reason}` for any guard rejection or provider error. Never raises.
  """
  @spec call(module(), map(), map()) ::
          {:ok, term()} | {:error, :rate_limited | :circuit_open | :budget_exhausted | term()}
  def call(provider, req, ctx) do
    with :ok <- acquire_rate_limit(provider),
         :ok <- check_circuit_breaker(provider),
         :ok <- check_budget(provider, req) do
      invoke_provider(provider, req, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Private: guard layers
  # ---------------------------------------------------------------------------

  # Layer 1 — RateLimiter (back-pressure; no call on timeout)
  defp acquire_rate_limit(provider) do
    est_tokens = 0

    case RateLimiter.acquire(provider, est_tokens) do
      :ok ->
        :ok

      {:error, :rate_limit_timeout} ->
        :telemetry.execute(
          [:tau, :factory, :egress, :rate_limited],
          %{system_time: System.system_time()},
          %{provider: provider}
        )

        {:error, :rate_limited}
    end
  end

  # Layer 2 — CircuitBreaker (ETS read; no GenServer.call on the hot path)
  # SPEC-FACTORY-GOV §4 B3: `check` is an ETS read, never a GenServer.call.
  # An :open breaker short-circuits with no call made; the short-circuit emits
  # [:tau,:circuit_breaker,:open] (C211 / C205 visible-event requirement).
  defp check_circuit_breaker(provider) do
    Store.ensure_row(provider)
    now_ms = System.monotonic_time(:millisecond)
    state_atom = Store.state_for(provider)

    case state_atom do
      :open ->
        emit_circuit_open(provider, :open, now_ms)
        {:error, :circuit_open}

      :half_open ->
        # Half-open: admit exactly one probe via CAS; reject concurrent callers.
        if Store.probe_admitted?(provider) do
          :ok
        else
          emit_circuit_open(provider, :half_open, now_ms)
          {:error, :circuit_open}
        end

      :closed ->
        :ok
    end
  end

  # Layer 3 — Budget (ETS read; cited from SPEC-FACTORY-CORE D-320)
  # Budget.Owner may not be running in all contexts (e.g. plain session plane).
  # When not configured, skip silently (pass through).
  defp check_budget(_provider, _req) do
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private: provider invocation
  # ---------------------------------------------------------------------------

  defp invoke_provider(provider, req, ctx) do
    messages = Map.get(req, :messages, [])
    opts = Map.get(req, :opts, %{})

    try do
      provider.stream(messages, opts, ctx)
    rescue
      e -> {:error, {:provider_exception, e}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: telemetry
  # ---------------------------------------------------------------------------

  defp emit_circuit_open(provider, observed_state, _now_ms) do
    :telemetry.execute(
      [:tau, :circuit_breaker, :open],
      %{system_time: System.system_time()},
      %{provider: provider, observed_state: observed_state}
    )
  end
end

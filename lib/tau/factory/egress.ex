defmodule Tau.Factory.Egress do
  @moduledoc """
  Single outbound chokepoint for all provider calls (INV-EGRESS-CHOKEPOINT / D-351).

  `call/3` is the **only** permitted caller of a provider's `stream/3` anywhere
  in the system. It applies three fail-closed guards in the load-bearing order
  mandated by SPEC-FACTORY-GOV §4 B1 / D-351:

      RateLimiter.acquire(provider)          → {:error, :rate_limited}    (back-pressure)
      CircuitBreaker — state check (ETS read) → {:error, :circuit_open}    (visible event)
      Budget.Owner.admit(owner, est_cost)    → {:error, :budget_exhausted} (→ E-BUDGET)
      provider.stream(messages, opts, ctx)   ← only when all guards pass

  After a successful or failed provider call, the circuit breaker outcome is
  recorded (ETS CAS) so the breaker's state machine can transition correctly
  (SPEC-FACTORY-GOV §4 B3 `record/3`).

  Every short-circuit is **visible** — a tagged error is returned to the caller
  AND a telemetry event is emitted. No silent drops (C211).

  ## D-351 contract

      call(provider, req, ctx) :: {:ok, stream} | {:error, reason}

  where `reason ∈ {:rate_limited, :circuit_open, :budget_exhausted}` ∪ provider
  error terms. `req` is a map with at minimum `%{messages: [...], opts: %{...}}`.
  `ctx` is passed through to `provider.stream/3`.

  `call/3` never raises across the boundary (OTP non-negotiable #7).
  """

  alias Tau.CircuitBreaker.State, as: CBState
  alias Tau.CircuitBreaker.Store
  alias Tau.Factory.Budget.Owner, as: BudgetOwner
  alias Tau.Providers.RateLimiter

  @doc """
  The single outbound chokepoint for all provider calls (D-351 / INV-EGRESS-CHOKEPOINT).

  Applies fail-closed guards in load-bearing order:
  `RateLimiter → CircuitBreaker → Budget → provider.stream/3`.

  Returns `{:ok, stream}` when all guards pass and the provider call succeeds,
  or `{:error, reason}` for any guard rejection or provider error. Never raises.
  """
  @spec call(module(), map(), map()) ::
          {:ok, term()} | {:error, :rate_limited | :circuit_open | :budget_exhausted | term()}
  def call(provider, req, ctx) do
    result =
      with :ok <- acquire_rate_limit(provider),
           {:ok, cb_state} <- check_circuit_breaker(provider),
           :ok <- check_budget(ctx) do
        outcome = invoke_provider(provider, req, ctx)
        record_circuit_breaker_outcome(provider, cb_state, outcome)
        outcome
      end

    :telemetry.execute(
      [:tau, :factory, :egress, :call],
      %{system_time: System.system_time()},
      %{provider: provider, result: result}
    )

    result
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
  # Returns {:ok, observed_state} so the caller can record the outcome after
  # the provider call (B3 `record/3` contract).
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
          {:ok, :half_open}
        else
          emit_circuit_open(provider, :half_open, now_ms)
          {:error, :circuit_open}
        end

      :closed ->
        {:ok, :closed}
    end
  end

  # Layer 3 — Budget (ETS read; cited from SPEC-FACTORY-CORE D-320 / B4)
  # `ctx[:budget_owner]` carries the Budget.Owner registered name (ETS table
  # atom). When absent, the check passes silently — Budget.Owner may not be
  # running in all contexts (e.g. plain session plane).
  # Reads the ETS snapshot DIRECTLY via `Budget.Owner.budget_precheck/2`
  # (no GenServer.call on the hot path; B4 / D-320 mailbox-bypass contract).
  defp check_budget(ctx) do
    case Map.get(ctx, :budget_owner) do
      nil ->
        :ok

      owner ->
        case BudgetOwner.budget_precheck(owner, :tokens) do
          :ok ->
            :ok

          {:exhausted, _dimension} ->
            :telemetry.execute(
              [:tau, :factory, :egress, :budget_exhausted],
              %{system_time: System.system_time()},
              %{owner: owner}
            )

            {:error, :budget_exhausted}
        end
    end
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
  # Private: circuit breaker outcome recording (SPEC-FACTORY-GOV §4 B3)
  # ---------------------------------------------------------------------------

  # Record the outcome of a provider call into the circuit breaker's ETS table
  # so the state machine can transition correctly (`:closed` failure accumulation,
  # `:half_open` probe success/failure).  Uses the same ETS-CAS approach as
  # `Tau.CircuitBreaker` — counter increments are atomic via `Store.bump_*/1`,
  # state transitions are a CAS `select_replace` (no GenServer.call, C205).
  defp record_circuit_breaker_outcome(provider, observed_state, {:ok, _}) do
    new_count = Store.bump_success_count(provider)
    row = current_cb_struct(provider)
    struct_pre_bump = %CBState{row | success_count: new_count - 1}
    now_ms = System.monotonic_time(:millisecond)
    new_state = CBState.record_success(struct_pre_bump, now_ms: now_ms)
    maybe_cb_transition(provider, observed_state, new_state)
  end

  defp record_circuit_breaker_outcome(provider, observed_state, {:error, _}) do
    new_count = Store.bump_failure_count(provider)
    row = current_cb_struct(provider)
    struct_pre_bump = %CBState{row | failure_count: new_count - 1}
    now_ms = System.monotonic_time(:millisecond)
    new_state = CBState.record_failure(struct_pre_bump, now_ms: now_ms)
    maybe_cb_transition(provider, observed_state, new_state)
  end

  defp current_cb_struct(provider) do
    case Store.get(provider) do
      nil ->
        %CBState{}

      {_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot} ->
        %CBState{
          state: state_atom,
          failure_count: failure_count,
          success_count: success_count,
          opened_at_ms: opened_at_ms,
          probe_slot: probe_slot
        }
    end
  end

  defp maybe_cb_transition(provider, current_state, new_state) do
    if new_state.state != current_state do
      count = Store.transition(provider, current_state, new_state)

      if count == 1 do
        :telemetry.execute(
          [:tau, :circuit_breaker, :transition],
          %{system_time: System.system_time()},
          %{provider: provider, from: current_state, to: new_state.state}
        )
      end
    end

    :ok
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

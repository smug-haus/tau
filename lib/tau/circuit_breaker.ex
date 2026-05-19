defmodule Tau.CircuitBreaker do
  @moduledoc """
  Public façade for the per-provider circuit breaker (SPEC-CIRCUIT-BREAKER §4 B3, C3).

  Wraps a provider-call thunk with the circuit-breaker lifecycle:

  1. Ensures a row exists for `provider` (idempotent).
  2. Reads the current state from ETS via `Store`.
  3. Short-circuits with `{:error, :circuit_open}` when the breaker is `:open`.
  4. When `:half_open`, admits exactly one probe via `Store.probe_admitted?/1`
     (exclusive CAS — D-030); rejects concurrent callers as `:circuit_open`.
  5. Invokes the thunk; records the outcome; drives state transitions via
     `Store.transition/3` (select_replace CAS — D-044).

  The façade is a **stateless module** — no process, no GenServer. All
  concurrency safety is handled by ETS atomics in `Tau.CircuitBreaker.Store`.

  ## Telemetry

  - `[:tau, :circuit_breaker, :check]` — emitted before every thunk call,
    with `%{system_time: integer()}` in measurements and
    `%{provider: provider, state: state_atom}` in metadata.
  - `[:tau, :circuit_breaker, :open]` — emitted when a call is short-circuited
    because the breaker is `:open` or the probe slot is taken (C62-B3).
  - `[:tau, :circuit_breaker, :transition]` — emitted when a state transition
    occurs, with `%{from: old_state, to: new_state}` in metadata.

  ## D-043

  A chain of providers where all breakers are `:open` terminates in exactly N
  `call/3` invocations — each returns `{:error, :circuit_open}` without
  invoking the thunk. The fallback sequence MUST NOT retry on `:circuit_open`.
  """

  alias Tau.CircuitBreaker.State
  alias Tau.CircuitBreaker.Store

  @default_failure_threshold 5
  @default_success_threshold 1

  @doc """
  Wraps a provider call with circuit-breaker logic.

  ## Arguments

  - `provider` — the provider module atom (ETS key).
  - `opts` — keyword list:
    - `:failure_threshold` (default `5`) — consecutive failures before opening.
    - `:success_threshold` (default `1`) — successes in `:half_open` to close.
  - `thunk` — a zero-arity function that performs the actual provider call.

  ## Thunk contract

  The thunk MUST return `{:ok, result}` or `{:error, reason}`. The thunk MUST
  NOT raise — an exception propagates to the caller and is NOT recorded as a
  breaker failure. Only the `:ok` / `:error` tag drives the breaker transition
  (C65-B3); the full return value is forwarded unchanged.

  ## Returns

  - `{:error, :circuit_open}` — breaker is `:open`, or probe slot taken.
  - The thunk's own return value otherwise (success or error).

  The full error term from a failing thunk is preserved and returned to the
  caller; only the `:ok` / `:error` tag drives the breaker transition (C65-B3).
  """
  @spec call(module(), keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def call(provider, opts \\ [], thunk) do
    Store.ensure_row(provider)
    now_ms = System.monotonic_time(:millisecond)
    state_atom = Store.state_for(provider)

    :telemetry.execute(
      [:tau, :circuit_breaker, :check],
      %{system_time: System.system_time()},
      %{provider: provider, state: state_atom}
    )

    dispatch(provider, state_atom, now_ms, opts, thunk)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Dispatch based on the observed state at call time.
  defp dispatch(provider, :closed, now_ms, opts, thunk) do
    result = thunk.()
    record_outcome(provider, :closed, result, now_ms, opts)
    result
  end

  defp dispatch(provider, :open, _now_ms, _opts, _thunk) do
    emit_open(provider, :open)
    {:error, :circuit_open}
  end

  defp dispatch(provider, :half_open, now_ms, opts, thunk) do
    if Store.probe_admitted?(provider) do
      result = thunk.()
      record_outcome(provider, :half_open, result, now_ms, opts)
      result
    else
      emit_open(provider, :half_open)
      {:error, :circuit_open}
    end
  end

  # Record the thunk outcome and drive transitions.
  #
  # Counter increments (failure_count / success_count) go through the atomic
  # Store.bump_* primitives ([C56-B1] / [C60-B1]). The returned post-increment
  # count is then fed into the pure State functions to decide whether a
  # state-machine transition is required. The transition itself is a CAS
  # select_replace guarded on the current state atom — correct and unchanged.
  #
  # The bump returns the NEW count (post-increment). To keep State's pure
  # functions unmodified (they each do `count + 1` internally), we pass
  # `new_count - 1` as the pre-bump value so the pure function computes the
  # same `new_count`. This is safe: `new_count - 1` is the value THIS process
  # incremented from — no other process produced this specific (new_count - 1)
  # value for the same bump operation.
  defp record_outcome(provider, current_state, {:ok, _}, now_ms, opts) do
    new_count = Store.bump_success_count(provider)
    row = current_struct(provider)
    struct_pre_bump = %State{row | success_count: new_count - 1}
    new_state = State.record_success(struct_pre_bump, Keyword.put(opts, :now_ms, now_ms))
    maybe_transition(provider, current_state, new_state)
  end

  defp record_outcome(provider, current_state, {:error, _}, now_ms, opts) do
    new_count = Store.bump_failure_count(provider)
    row = current_struct(provider)
    struct_pre_bump = %State{row | failure_count: new_count - 1}

    new_state =
      State.record_failure(
        struct_pre_bump,
        opts |> Keyword.put(:now_ms, now_ms)
      )

    maybe_transition(provider, current_state, new_state)
  end

  # Build a %State{} from the current ETS row so State pure functions can compute
  # the next value. Defaults to a fresh :closed struct if no row exists.
  defp current_struct(provider) do
    case Store.get(provider) do
      nil ->
        %State{}

      {_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot} ->
        %State{
          state: state_atom,
          failure_count: failure_count,
          success_count: success_count,
          opened_at_ms: opened_at_ms,
          probe_slot: probe_slot
        }
    end
  end

  # Attempt the CAS state-machine transition. Only called when `new_state.state`
  # differs from `current_state` — i.e. a real state-machine change is required.
  # When there is no state change (counter bumped but state unchanged), this
  # function is NOT called: the atomic bump via Store.bump_*/1 is sufficient
  # and a full-row select_replace would clobber concurrent counter updates.
  #
  # When a state change IS required, the full-row CAS is necessary. If the CAS
  # loses the race (returns 0), a concurrent caller already transitioned — no-op.
  defp maybe_transition(provider, current_state, new_state) do
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

  defp emit_open(provider, observed_state) do
    :telemetry.execute(
      [:tau, :circuit_breaker, :open],
      %{system_time: System.system_time()},
      %{provider: provider, observed_state: observed_state}
    )
  end

  # Expose defaults for test helpers.
  @doc false
  def default_failure_threshold, do: @default_failure_threshold
  @doc false
  def default_success_threshold, do: @default_success_threshold
end

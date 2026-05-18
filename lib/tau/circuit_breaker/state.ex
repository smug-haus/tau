defmodule Tau.CircuitBreaker.State do
  @moduledoc """
  Pure state-machine core for the circuit breaker (SPEC-CIRCUIT-BREAKER §4 B4).

  Holds the breaker's current status and counters. All functions are pure —
  no process, no ETS, no side effects. `Tau.CircuitBreaker.Store` (PR2)
  persists instances of this struct in ETS and drives transitions via
  `Tau.CircuitBreaker` (the façade, PR3).

  ## States

  - `:closed`    — normal operation; provider calls are admitted.
  - `:open`      — short-circuiting; all calls return `{:error, :circuit_open}`.
  - `:half_open` — cooldown elapsed; exactly one probe is admitted.

  ## Defaults

  - `failure_threshold`: `5` — consecutive failures before opening.
  - `cooldown_ms`:       `30_000` — milliseconds to wait before probing.
  - `success_threshold`: `1` — successes in `:half_open` to close.

  ## D-029

  For any `%State{}` and any `now_ms`, `check/2` returns exactly one of
  `:closed`, `:open`, `:half_open`. All functions are total.
  """

  @type state_atom :: :closed | :open | :half_open

  @type t :: %__MODULE__{
          state: state_atom(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          opened_at_ms: non_neg_integer(),
          half_open_probe?: boolean()
        }

  defstruct state: :closed,
            failure_count: 0,
            success_count: 0,
            opened_at_ms: 0,
            half_open_probe?: false

  @default_failure_threshold 5
  @default_cooldown_ms 30_000
  @default_success_threshold 1

  @doc """
  Returns the observable state of the breaker at `now_ms`.

  Concretely:

  - `:closed` — breaker is healthy or success reset it.
  - `:open`   — cooldown has not yet elapsed since `opened_at_ms`.
  - `:half_open` — cooldown has elapsed; a probe may be admitted.

  `check/2` does not mutate state; the caller is responsible for
  transitioning to `:half_open` if needed (done by `Tau.CircuitBreaker.Store`).
  """
  @spec check(t(), non_neg_integer()) :: state_atom()
  def check(%__MODULE__{state: :closed}, _now_ms), do: :closed

  def check(%__MODULE__{state: :open, opened_at_ms: opened_at_ms}, now_ms) do
    if now_ms >= opened_at_ms + @default_cooldown_ms do
      :half_open
    else
      :open
    end
  end

  def check(%__MODULE__{state: :half_open}, _now_ms), do: :half_open

  @doc """
  Records a provider-call failure and returns the updated state.

  In `:closed` state, bumps `failure_count`. When `failure_count` reaches
  `failure_threshold`, transitions to `:open` and records `opened_at_ms`.

  In `:half_open` state, the probe failed — transitions back to `:open`.

  In `:open` state, the failure is a no-op (the breaker is already open).
  """
  @spec record_failure(t(), keyword()) :: t()
  def record_failure(state, opts \\ [])

  def record_failure(%__MODULE__{state: :closed} = s, opts) do
    threshold = Keyword.get(opts, :failure_threshold, @default_failure_threshold)
    now_ms = Keyword.get(opts, :now_ms, 0)
    new_count = s.failure_count + 1

    if new_count >= threshold do
      %__MODULE__{
        s
        | state: :open,
          failure_count: new_count,
          success_count: 0,
          opened_at_ms: now_ms
      }
    else
      %__MODULE__{s | failure_count: new_count}
    end
  end

  def record_failure(%__MODULE__{state: :half_open} = s, opts) do
    now_ms = Keyword.get(opts, :now_ms, 0)

    %__MODULE__{
      s
      | state: :open,
        failure_count: s.failure_count + 1,
        success_count: 0,
        opened_at_ms: now_ms,
        half_open_probe?: false
    }
  end

  def record_failure(%__MODULE__{state: :open} = s, _opts), do: s

  @doc """
  Records a provider-call success and returns the updated state.

  In `:closed` state, resets `failure_count` to `0` (consecutive-failure
  counting — a single success clears accumulated partial failures).

  In `:half_open` state, bumps `success_count`. When `success_count` reaches
  `success_threshold`, closes the breaker.

  In `:open` state, a success is a no-op (the probe has not been admitted yet;
  this path should not occur in normal façade usage).
  """
  @spec record_success(t(), keyword()) :: t()
  def record_success(state, opts \\ [])

  def record_success(%__MODULE__{state: :closed} = s, _opts) do
    %__MODULE__{s | failure_count: 0}
  end

  def record_success(%__MODULE__{state: :half_open} = s, opts) do
    threshold = Keyword.get(opts, :success_threshold, @default_success_threshold)
    new_count = s.success_count + 1

    if new_count >= threshold do
      %__MODULE__{
        s
        | state: :closed,
          failure_count: 0,
          success_count: 0,
          opened_at_ms: 0,
          half_open_probe?: false
      }
    else
      %__MODULE__{s | success_count: new_count}
    end
  end

  def record_success(%__MODULE__{state: :open} = s, _opts), do: s
end

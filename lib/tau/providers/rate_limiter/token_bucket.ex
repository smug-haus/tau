defmodule Tau.Providers.RateLimiter.TokenBucket do
  @moduledoc """
  Pure token-bucket arithmetic for `Tau.Providers.RateLimiter`.

  No process state. The owning GenServer threads `%TokenBucket{}` through
  its own state and calls into this module on every request. ADR-0011
  splits the math out so the property suite can pin the invariants
  (non-negative current count, monotonic refill, idempotent halve)
  without spinning up a process.

  ## Shape

      %TokenBucket{
        size:           non_neg_integer(),    # max capacity (refills up to here)
        current:        float() | non_neg_integer(),
        rate_per_sec:   non_neg_integer(),    # refill rate
        last_refill_ms: integer()             # System.monotonic_time(:millisecond)
      }

  `current` is allowed to be a float between refills so that a fractional
  refill (`elapsed_ms * rate_per_sec / 1000`) doesn't drop tokens to
  rounding. Callers see integer tokens via `take/3`'s contract.
  """

  defstruct size: 0, current: 0, rate_per_sec: 0, last_refill_ms: 0

  @type t :: %__MODULE__{
          size: non_neg_integer(),
          current: number(),
          rate_per_sec: non_neg_integer(),
          last_refill_ms: integer()
        }

  @doc """
  Construct a fresh bucket with `current = size`.

  `now_ms` defaults to `System.monotonic_time(:millisecond)`. Tests inject.
  """
  @spec new(non_neg_integer(), non_neg_integer(), integer()) :: t()
  def new(size, rate_per_sec, now_ms \\ System.monotonic_time(:millisecond))
      when is_integer(size) and size >= 0 and is_integer(rate_per_sec) and rate_per_sec >= 0 do
    %__MODULE__{
      size: size,
      current: size,
      rate_per_sec: rate_per_sec,
      last_refill_ms: now_ms
    }
  end

  @doc """
  Add elapsed-time refill, capped at `size`.

  `now_ms` is monotonic. If the clock somehow goes backwards (it shouldn't,
  but BEAM monotonic time is per-scheduler) we treat negative deltas as 0.
  """
  @spec refill(t(), integer()) :: t()
  def refill(%__MODULE__{rate_per_sec: 0} = b, _now_ms), do: b

  def refill(%__MODULE__{} = b, now_ms) do
    delta_ms = max(0, now_ms - b.last_refill_ms)
    add = delta_ms * b.rate_per_sec / 1000
    new_current = min(b.size, b.current + add)
    %__MODULE__{b | current: new_current, last_refill_ms: now_ms}
  end

  @doc """
  Attempt to take `n` tokens.

  Returns `{:ok, bucket}` if budget was available; `{:wait, wait_ms,
  bucket}` if the caller should park for `wait_ms` milliseconds and then
  retry. The bucket is unchanged on `:wait` — the GenServer serialises
  waiters via its mailbox.

  `n = 0` always succeeds without touching the bucket.

  Refills internally before checking, so callers don't need to call
  `refill/2` themselves. Pass `now_ms` for testability.
  """
  @spec take(t(), non_neg_integer(), integer()) ::
          {:ok, t()} | {:wait, non_neg_integer() | :infinity, t()}
  def take(%__MODULE__{} = b, 0, _now_ms), do: {:ok, b}

  def take(%__MODULE__{size: 0} = b, _n, _now_ms) do
    # Bucket fully disabled (size 0). Treat as unlimited — there's no
    # configured limit. Callers that disable a bucket via size:0 mean
    # "no gating".
    {:ok, b}
  end

  def take(%__MODULE__{} = b, n, now_ms) when is_integer(n) and n > 0 do
    b = refill(b, now_ms)

    if b.current >= n do
      {:ok, %__MODULE__{b | current: b.current - n}}
    else
      missing = n - b.current

      wait_ms =
        if b.rate_per_sec == 0 do
          :infinity
        else
          ceil(missing * 1000 / b.rate_per_sec)
        end

      {:wait, wait_ms, b}
    end
  end

  @doc """
  Halve the bucket's `size`, clipping `current` to the new ceiling.

  Floors at size = 1 to avoid driving the bucket to zero (which would be
  indistinguishable from "no gating" per `take/3`'s zero-size arm).
  """
  @spec halve(t()) :: t()
  def halve(%__MODULE__{size: size} = b) do
    new_size = max(1, div(size, 2))
    new_current = min(b.current, new_size)
    %__MODULE__{b | size: new_size, current: new_current}
  end

  @doc """
  Resize the bucket in place (used on settings reload).

  Preserves `current` (clipped to `new_size`) and `last_refill_ms`. ADR-0011
  explains why we resize rather than restart.
  """
  @spec resize(t(), non_neg_integer(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = b, new_size, new_rate_per_sec)
      when is_integer(new_size) and new_size >= 0 and is_integer(new_rate_per_sec) and
             new_rate_per_sec >= 0 do
    %__MODULE__{
      b
      | size: new_size,
        current: min(b.current, new_size),
        rate_per_sec: new_rate_per_sec
    }
  end
end

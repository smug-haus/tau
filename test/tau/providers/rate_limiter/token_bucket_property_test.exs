defmodule Tau.Providers.RateLimiter.TokenBucketPropertyTest do
  @moduledoc """
  Properties that pin `Tau.Providers.RateLimiter.TokenBucket` (the pure
  core that ADR-0011 promises to keep stable).

  Invariants tested:

    * `take/3` never produces a negative `current` count.
    * `refill/2` is monotonic in time — given t1 ≤ t2,
      `refill(b, t2).current >= refill(b, t1).current`.
    * `halve/1` halves the size each call (with a floor at 1) — two
      halves in the same instant equals dividing by 4.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Providers.RateLimiter.TokenBucket

  @moduletag :property

  defp bucket_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.integer(0..10_000),
        StreamData.integer(0..1_000)
      }),
      fn {size, rate} ->
        StreamData.constant(TokenBucket.new(size, rate, 0))
      end
    )
  end

  property "take/3 never produces negative current" do
    check all(
            b <- bucket_gen(),
            n <- StreamData.integer(0..50_000),
            t <- StreamData.integer(0..1_000_000)
          ) do
      case TokenBucket.take(b, n, t) do
        {:ok, b2} ->
          assert b2.current >= 0

        {:wait, _, b2} ->
          # On :wait the bucket isn't decremented; it may have been
          # refilled but `current` must still be >= 0.
          assert b2.current >= 0
      end
    end
  end

  property "refill/2 is monotonic in time" do
    check all(
            b <- bucket_gen(),
            t1 <- StreamData.integer(0..1_000_000),
            dt <- StreamData.integer(0..1_000_000)
          ) do
      t2 = t1 + dt
      r1 = TokenBucket.refill(b, t1)
      r2 = TokenBucket.refill(b, t2)
      assert r2.current >= r1.current or r2.current == b.size
    end
  end

  property "halve/1 applied twice in the same instant is dividing by 4 (with floor)" do
    check all(size <- StreamData.integer(2..10_000)) do
      b = TokenBucket.new(size, 0, 0)
      once = TokenBucket.halve(b)
      twice = TokenBucket.halve(once)

      expected_once = max(1, div(size, 2))
      expected_twice = max(1, div(expected_once, 2))

      assert once.size == expected_once
      assert twice.size == expected_twice
    end
  end

  property "take/3 with n=0 is a no-op" do
    check all(
            b <- bucket_gen(),
            t <- StreamData.integer(0..1_000_000)
          ) do
      assert {:ok, b2} = TokenBucket.take(b, 0, t)
      assert b2 == b
    end
  end

  property "halve/1 floors at size = 1" do
    check all(size <- StreamData.integer(0..3)) do
      b = TokenBucket.new(size, 0, 0)
      h = TokenBucket.halve(b)
      assert h.size >= 1
    end
  end

  property "resize/3 preserves last_refill_ms and clips current" do
    check all(
            b <- bucket_gen(),
            new_size <- StreamData.integer(0..10_000),
            new_rate <- StreamData.integer(0..1_000)
          ) do
      r = TokenBucket.resize(b, new_size, new_rate)
      assert r.last_refill_ms == b.last_refill_ms
      assert r.current <= new_size
      assert r.size == new_size
      assert r.rate_per_sec == new_rate
    end
  end
end

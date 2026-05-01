defmodule Tau.Providers.RateLimiter429Test do
  @moduledoc """
  End-to-end-ish: drives the rate limiter with a synthetic 429 cast and
  verifies the bucket halves. Uses `Tau.Providers.RateLimiter.state/1`
  for introspection (test-only API documented in the limiter moduledoc).
  """
  use ExUnit.Case, async: false

  alias Tau.Providers.RateLimiter

  defmodule FakeProviderForFiveTwentyNine do
    @moduledoc false
  end

  setup do
    on_exit(fn ->
      case RateLimiter.state(FakeProviderForFiveTwentyNine) do
        :no_limiter -> :ok
        _ -> Tau.Providers.RateLimiter.Supervisor.stop(FakeProviderForFiveTwentyNine)
      end
    end)

    :ok
  end

  test "429 record_response halves bucket; next acquire sees the smaller cap" do
    {:ok, _} =
      Tau.Providers.RateLimiter.Supervisor.ensure_started(
        FakeProviderForFiveTwentyNine,
        rpm: 600,
        tpm: 6_000
      )

    original = RateLimiter.state(FakeProviderForFiveTwentyNine)
    assert original.rpm_bucket.size == 600
    assert original.tpm_bucket.size == 6_000

    RateLimiter.record_response(FakeProviderForFiveTwentyNine, %{status: 429})
    Process.sleep(20)

    halved = RateLimiter.state(FakeProviderForFiveTwentyNine)
    assert halved.rpm_bucket.size == 300
    assert halved.tpm_bucket.size == 3_000

    # And acquire still works against the smaller cap.
    assert :ok = RateLimiter.acquire(FakeProviderForFiveTwentyNine, 100, 1_000)
  end

  test "telemetry :halved fires on 429" do
    {:ok, _} =
      Tau.Providers.RateLimiter.Supervisor.ensure_started(
        FakeProviderForFiveTwentyNine,
        rpm: 200,
        tpm: 2_000
      )

    test_pid = self()
    handler_id = "rl-429-#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tau, :provider, :rate_limit, :halved],
      fn _event, _m, meta, _ -> send(test_pid, {:halved, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    RateLimiter.record_response(FakeProviderForFiveTwentyNine, %{status: 429})

    assert_receive {:halved, %{provider: FakeProviderForFiveTwentyNine, new_size: 100}}, 500
  end
end

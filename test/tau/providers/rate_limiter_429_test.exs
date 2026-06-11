defmodule Tau.Providers.RateLimiter429Test do
  @moduledoc """
  End-to-end-ish: drives the rate limiter with a synthetic 429 cast and
  verifies the bucket halves. Uses `Tau.Providers.RateLimiter.state/1`
  for introspection (test-only API documented in the limiter moduledoc).
  """
  use ExUnit.Case, async: false

  alias Tau.Providers.RateLimiter

  # Each test gets a unique provider atom to prevent on_exit cleanup from a
  # prior test racing against a subsequent test's GenServer. ExUnit runs
  # on_exit callbacks in a separate cleanup process; under full-suite load
  # those can overlap with the next test's setup — stop/1 on a shared atom
  # kills the limiter mid-cast, so the telemetry event never fires.
  # See same pattern + comment in test/tau/providers/rate_limiter_test.exs.
  defp unique_provider do
    String.to_atom("FakeProvider429_#{System.unique_integer([:positive])}")
  end

  test "429 record_response halves bucket; next acquire sees the smaller cap" do
    provider = unique_provider()
    on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

    {:ok, _} =
      Tau.Providers.RateLimiter.Supervisor.ensure_started(
        provider,
        rpm: 600,
        tpm: 6_000
      )

    original = RateLimiter.state(provider)
    assert original.rpm_bucket.size == 600
    assert original.tpm_bucket.size == 6_000

    RateLimiter.record_response(provider, %{status: 429})

    # record_response/2 is a GenServer.cast (async). Flush the mailbox by
    # issuing a subsequent GenServer.call — calls queue behind casts for the
    # same process, so state/1 returns only after the cast has landed.
    halved = RateLimiter.state(provider)
    assert halved.rpm_bucket.size == 300
    assert halved.tpm_bucket.size == 3_000

    # And acquire still works against the smaller cap.
    assert :ok = RateLimiter.acquire(provider, 100, 1_000)
  end

  test "telemetry :halved fires on 429" do
    provider = unique_provider()
    on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

    {:ok, _} =
      Tau.Providers.RateLimiter.Supervisor.ensure_started(
        provider,
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

    RateLimiter.record_response(provider, %{status: 429})

    assert_receive {:halved, %{provider: ^provider, new_size: 100}}, 500
  end
end

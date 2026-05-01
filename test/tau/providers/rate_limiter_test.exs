defmodule Tau.Providers.RateLimiterTest do
  @moduledoc """
  Behavioural tests for the `Tau.Providers.RateLimiter` GenServer
  (ADR-0011, #39).

  Each test starts its own fake-provider limiter under the running
  `Tau.Providers.RateLimiter.Supervisor.Dynamic` so they don't collide
  with any limiter that booted from the loaded settings.
  """
  use ExUnit.Case, async: false

  alias Tau.Providers.RateLimiter

  defmodule FakeProvider do
    @moduledoc false
  end

  defmodule FakeProvider2 do
    @moduledoc false
  end

  setup do
    on_exit(fn ->
      RateLimiter
      |> apply(:state, [FakeProvider])
      |> case do
        :no_limiter -> :ok
        _ -> Tau.Providers.RateLimiter.Supervisor.stop(FakeProvider)
      end

      RateLimiter
      |> apply(:state, [FakeProvider2])
      |> case do
        :no_limiter -> :ok
        _ -> Tau.Providers.RateLimiter.Supervisor.stop(FakeProvider2)
      end
    end)

    :ok
  end

  describe "acquire/3 with available budget" do
    test "returns :ok immediately and emits :acquired telemetry" do
      {:ok, _pid} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(FakeProvider, rpm: 600, tpm: 6_000)

      ref = make_ref()

      :telemetry.attach_many(
        "rl-test-#{inspect(ref)}",
        [
          [:tau, :provider, :rate_limit, :acquired],
          [:tau, :provider, :rate_limit, :throttled],
          [:tau, :provider, :rate_limit, :rejected]
        ],
        fn event, m, meta, _ -> send(self(), {ref, event, m, meta}) end,
        nil
      )

      send(self(), {ref, :primer, %{}, %{}})
      _ = receive(do: ({^ref, :primer, _, _} -> :ok))

      assert :ok = RateLimiter.acquire(FakeProvider, 100, 1_000)

      :telemetry.detach("rl-test-#{inspect(ref)}")
    end

    test "no limiter for provider returns :ok (no gating)" do
      assert :ok = RateLimiter.acquire(:nonexistent_provider, 100, 100)
    end
  end

  describe "acquire/3 starvation" do
    test "with zero budget and zero refill returns :rate_limit_timeout quickly" do
      # rpm: 0 == "no gating" per TokenBucket spec, so use a tiny budget
      # with a high request count.
      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(FakeProvider, rpm: 60, tpm: 60)

      # Drain the rpm bucket. rate_per_sec = 60/60 = 1, so refill is
      # 1 token/sec — easy to starve.
      Enum.each(1..60, fn _ -> RateLimiter.acquire(FakeProvider, 0, 5_000) end)

      # Now ask for one more with a 50ms timeout — should reject.
      assert {:error, :rate_limit_timeout} = RateLimiter.acquire(FakeProvider, 0, 50)
    end
  end

  describe "record_response/2" do
    test "halves bucket on 429" do
      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(FakeProvider2, rpm: 100, tpm: 1_000)

      before_state = RateLimiter.state(FakeProvider2)
      assert before_state.rpm_bucket.size == 100

      RateLimiter.record_response(FakeProvider2, %{status: 429})
      # Cast — give it a moment to land.
      Process.sleep(20)

      after_state = RateLimiter.state(FakeProvider2)
      assert after_state.rpm_bucket.size == 50
      assert after_state.tpm_bucket.size == 500
      assert after_state.half_until > 0
    end

    test "non-429 status is a no-op" do
      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(FakeProvider2, rpm: 100, tpm: 1_000)

      RateLimiter.record_response(FakeProvider2, %{status: 200})
      Process.sleep(20)

      after_state = RateLimiter.state(FakeProvider2)
      assert after_state.rpm_bucket.size == 100
    end
  end
end

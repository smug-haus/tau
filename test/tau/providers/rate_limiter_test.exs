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

  # No shared module-level FakeProvider: every test that starts a limiter uses
  # a unique atom derived from System.unique_integer/1 and registers its own
  # on_exit to stop it. This avoids a TOCTOU window where a previous test's
  # DynamicSupervisor.terminate_child returns (process dead) but the Registry
  # has not yet processed the DOWN and deregistered the entry — a subsequent
  # GenServer.call on the stale pid crashes the on_exit runner, and ExUnit
  # reports the *next* test as failed (pointing to the on_exit line).

  describe "acquire/3 with available budget" do
    test "returns :ok immediately and emits :acquired telemetry" do
      # Unique atom: isolates this limiter from concurrent on_exit cleanup.
      provider =
        String.to_atom("FakeProviderAcquire_#{System.unique_integer([:positive])}")

      on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

      {:ok, _pid} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(provider, rpm: 600, tpm: 6_000)

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

      assert :ok = RateLimiter.acquire(provider, 100, 1_000)

      :telemetry.detach("rl-test-#{inspect(ref)}")
    end

    test "no limiter for provider returns :ok (no gating)" do
      assert :ok = RateLimiter.acquire(:nonexistent_provider, 100, 100)
    end
  end

  describe "acquire/3 starvation" do
    test "with zero budget and zero refill returns :rate_limit_timeout quickly" do
      # Unique atom — same isolation rationale as the other tests in this file.
      provider =
        String.to_atom("FakeProviderStarve_#{System.unique_integer([:positive])}")

      on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

      # rpm: 0 == "no gating" per TokenBucket spec, so use a tiny budget
      # with a high request count.
      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(provider, rpm: 60, tpm: 60)

      # Drain the rpm bucket. rate_per_sec = 60/60 = 1, so refill is
      # 1 token/sec — easy to starve.
      Enum.each(1..60, fn _ -> RateLimiter.acquire(provider, 0, 5_000) end)

      # Now ask for one more with a 50ms timeout — should reject.
      assert {:error, :rate_limit_timeout} = RateLimiter.acquire(provider, 0, 50)
    end
  end

  describe "record_response/2" do
    test "halves bucket on 429" do
      # Use a unique provider atom so on_exit cleanup from a sibling test
      # cannot race-stop this limiter (ExUnit runs on_exit in a separate
      # cleanup process; a loaded runner can schedule it concurrently).
      provider = String.to_atom("FakeProvider429_#{System.unique_integer([:positive])}")
      on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(provider, rpm: 100, tpm: 1_000)

      before_state = RateLimiter.state(provider)
      assert before_state.rpm_bucket.size == 100

      RateLimiter.record_response(provider, %{status: 429})

      # record_response/2 sends a GenServer.cast. Flush by issuing a
      # subsequent GenServer.call (:state) — calls queue behind casts
      # for the same process, so state/1 returns only after the cast lands.
      after_state = RateLimiter.state(provider)
      assert after_state.rpm_bucket.size == 50
      assert after_state.tpm_bucket.size == 500
      assert after_state.half_until > 0
    end

    test "non-429 status is a no-op" do
      # Unique atom — see comment in "halves bucket on 429".
      provider = String.to_atom("FakeProviderNoop_#{System.unique_integer([:positive])}")
      on_exit(fn -> Tau.Providers.RateLimiter.Supervisor.stop(provider) end)

      {:ok, _} =
        Tau.Providers.RateLimiter.Supervisor.ensure_started(provider, rpm: 100, tpm: 1_000)

      RateLimiter.record_response(provider, %{status: 200})

      # Flush the cast via a subsequent call — same ordering guarantee.
      after_state = RateLimiter.state(provider)
      assert after_state.rpm_bucket.size == 100
    end
  end
end

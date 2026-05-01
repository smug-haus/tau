defmodule Tau.Providers.RateLimiter do
  @moduledoc """
  Per-provider token-bucket rate limiter (ADR-0011).

  One GenServer per configured provider, registered under
  `Tau.Providers.RateLimiter.Registry` keyed by provider module. The
  process holds two `Tau.Providers.RateLimiter.TokenBucket` structs
  (RPM = requests-per-minute, TPM = tokens-per-minute) and serialises
  `acquire/3` calls through its mailbox — that's the wait queue.

  ## Public API

  - `acquire(provider, est_tokens, timeout)` — `:ok` once the budget is
    available, or `{:error, :rate_limit_timeout}` if `timeout` elapses.
    Block-and-wake — caller parks on `GenServer.call/3`.
  - `record_response(provider, response_meta)` — fire-and-forget cast.
    On `status: 429`, halves both buckets and arms a 60-second floor
    so a settings reload during the floor doesn't undo the throttle.
  - `state(provider)` — test-only introspection. Returns the limiter's
    state map. Documented as test-only; production callers go through
    telemetry.

  ## Settings

  On `init/1` the limiter reads its config from `Tau.Settings.Cache`
  (ADR-0002) and subscribes to the `"settings"` PubSub topic. On
  `{:settings_reloaded, settings}` it resizes its buckets in place via
  `TokenBucket.resize/3` — preserving `current` and `last_refill_ms` so
  the wait queue isn't flushed by a config change.

  ## Settings shape

      %{
        "rate_limits" => %{
          "Tau.Providers.Anthropic" => %{
            "rpm" => 50,
            "tpm" => 40_000
          }
        }
      }

  Both `rpm` and `tpm` default to `0` (which `TokenBucket` treats as
  "no gating"). Atom and string keys are both accepted.
  """

  use GenServer

  alias Tau.Providers.RateLimiter.TokenBucket

  @default_429_floor_ms 60_000

  # --- Public API -----------------------------------------------------------

  @doc """
  Start a rate limiter for `provider`. Registers under
  `Tau.Providers.RateLimiter.Registry`.

  `opts` accepts:
    * `:rpm` and `:tpm` — explicit bucket sizes; if absent, falls back
      to `Tau.Settings.Cache.get/0`.
    * `:name` — override the registry-name (test-only).
  """
  @spec start_link({module(), keyword()}) :: GenServer.on_start()
  def start_link({provider, opts}) when is_atom(provider) do
    name = opts[:name] || via(provider)
    GenServer.start_link(__MODULE__, {provider, opts}, name: name)
  end

  @doc """
  Block until `est_tokens` of TPM and one RPM permit are available, or
  `timeout` elapses.

  Returns `:ok | {:error, :rate_limit_timeout}`. If no limiter is running
  for `provider`, returns `:ok` (no gating configured).
  """
  @spec acquire(module(), non_neg_integer(), timeout()) ::
          :ok | {:error, :rate_limit_timeout}
  def acquire(provider, est_tokens, timeout \\ 30_000)
      when is_atom(provider) and is_integer(est_tokens) and est_tokens >= 0 do
    case Registry.lookup(Tau.Providers.RateLimiter.Registry, provider) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:acquire, est_tokens, timeout, monotonic_now()}, timeout + 1_000)
        catch
          :exit, {:timeout, _} -> {:error, :rate_limit_timeout}
          :exit, {:noproc, _} -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc """
  Record a provider response so the limiter can react.

  Fire-and-forget cast. `response_meta` should carry at least
  `:status` (HTTP status integer). On 429, halves both buckets and
  arms a 60-second floor.
  """
  @spec record_response(module(), map()) :: :ok
  def record_response(provider, %{} = meta) when is_atom(provider) do
    case Registry.lookup(Tau.Providers.RateLimiter.Registry, provider) do
      [{pid, _}] -> GenServer.cast(pid, {:record_response, meta})
      [] -> :ok
    end
  end

  @doc """
  Test-only introspection. Returns the current bucket state.
  """
  @spec state(module()) :: map() | :no_limiter
  def state(provider) when is_atom(provider) do
    case Registry.lookup(Tau.Providers.RateLimiter.Registry, provider) do
      [{pid, _}] -> GenServer.call(pid, :state)
      [] -> :no_limiter
    end
  end

  @doc false
  def via(provider), do: {:via, Registry, {Tau.Providers.RateLimiter.Registry, provider}}

  # --- GenServer ------------------------------------------------------------

  @impl true
  def init({provider, opts}) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "settings")

    {rpm, tpm} = bucket_sizes(provider, opts)
    now = monotonic_now()

    state = %{
      provider: provider,
      rpm_bucket: TokenBucket.new(rpm, div(rpm, 60), now),
      tpm_bucket: TokenBucket.new(tpm, div(tpm, 60), now),
      half_until: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, est_tokens, timeout, started_at}, from, state) do
    now = monotonic_now()
    request_result = TokenBucket.take(state.rpm_bucket, 1, now)
    token_result = TokenBucket.take(state.tpm_bucket, est_tokens, now)

    cond do
      elem(request_result, 0) == :ok and elem(token_result, 0) == :ok ->
        {:ok, rpm} = request_result
        {:ok, tpm} = token_result
        wait_ms = now - started_at
        new_state = %{state | rpm_bucket: rpm, tpm_bucket: tpm}
        emit_acquired(state.provider, wait_ms, est_tokens, rpm, tpm, wait_ms > 0)
        {:reply, :ok, new_state}

      true ->
        wait_ms =
          [wait_for(request_result), wait_for(token_result)]
          |> Enum.reject(&is_nil/1)
          |> max_wait()

        elapsed = now - started_at
        remaining = timeout - elapsed

        cond do
          remaining <= 0 ->
            emit_rejected(state.provider, elapsed)
            {:reply, {:error, :rate_limit_timeout}, state}

          wait_ms == :infinity or wait_ms > remaining ->
            Process.send_after(
              self(),
              {:retry_acquire, from, est_tokens, timeout, started_at},
              remaining
            )

            {:noreply, state}

          true ->
            Process.send_after(
              self(),
              {:retry_acquire, from, est_tokens, timeout, started_at},
              max(1, wait_ms)
            )

            {:noreply, state}
        end
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:record_response, %{status: 429}}, state) do
    rpm = TokenBucket.halve(state.rpm_bucket)
    tpm = TokenBucket.halve(state.tpm_bucket)
    half_until = monotonic_now() + @default_429_floor_ms

    :telemetry.execute(
      [:tau, :provider, :rate_limit, :halved],
      %{system_time: System.system_time()},
      %{provider: state.provider, new_size: rpm.size, tpm_size: tpm.size}
    )

    {:noreply, %{state | rpm_bucket: rpm, tpm_bucket: tpm, half_until: half_until}}
  end

  def handle_cast({:record_response, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:retry_acquire, from, est_tokens, timeout, started_at}, state) do
    now = monotonic_now()
    request_result = TokenBucket.take(state.rpm_bucket, 1, now)
    token_result = TokenBucket.take(state.tpm_bucket, est_tokens, now)

    if elem(request_result, 0) == :ok and elem(token_result, 0) == :ok do
      {:ok, rpm} = request_result
      {:ok, tpm} = token_result
      wait_ms = now - started_at
      emit_acquired(state.provider, wait_ms, est_tokens, rpm, tpm, true)
      GenServer.reply(from, :ok)
      {:noreply, %{state | rpm_bucket: rpm, tpm_bucket: tpm}}
    else
      elapsed = now - started_at
      remaining = timeout - elapsed

      if remaining <= 0 do
        emit_rejected(state.provider, elapsed)
        GenServer.reply(from, {:error, :rate_limit_timeout})
        {:noreply, state}
      else
        next_wait =
          [wait_for(request_result), wait_for(token_result)]
          |> Enum.reject(&is_nil/1)
          |> max_wait()

        sleep_for =
          case next_wait do
            :infinity -> remaining
            n -> min(n, remaining)
          end

        Process.send_after(
          self(),
          {:retry_acquire, from, est_tokens, timeout, started_at},
          max(1, sleep_for)
        )

        {:noreply, state}
      end
    end
  end

  def handle_info({:settings_reloaded, settings}, state) do
    {rpm_size, tpm_size} = sizes_from_settings(state.provider, settings)
    now = monotonic_now()

    rpm_target = ceiling_during_half(rpm_size, state.rpm_bucket.size, state.half_until, now)
    tpm_target = ceiling_during_half(tpm_size, state.tpm_bucket.size, state.half_until, now)

    rpm = TokenBucket.resize(state.rpm_bucket, rpm_target, div(rpm_target, 60))
    tpm = TokenBucket.resize(state.tpm_bucket, tpm_target, div(tpm_target, 60))

    {:noreply, %{state | rpm_bucket: rpm, tpm_bucket: tpm}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # --- helpers --------------------------------------------------------------

  defp wait_for({:ok, _}), do: nil
  defp wait_for({:wait, ms, _}), do: ms

  defp max_wait([]), do: 0

  defp max_wait(list) do
    if Enum.member?(list, :infinity) do
      :infinity
    else
      Enum.max(list)
    end
  end

  defp emit_acquired(provider, wait_ms, est_tokens, rpm, tpm, throttled?) do
    measurements = %{wait_ms: wait_ms, tokens_taken: est_tokens}

    metadata = %{
      provider: provider,
      bucket_remaining: trunc(rpm.current),
      tpm_remaining: trunc(tpm.current)
    }

    if throttled? do
      :telemetry.execute([:tau, :provider, :rate_limit, :throttled], measurements, metadata)
    end

    :telemetry.execute([:tau, :provider, :rate_limit, :acquired], measurements, metadata)
  end

  defp emit_rejected(provider, wait_ms) do
    :telemetry.execute(
      [:tau, :provider, :rate_limit, :rejected],
      %{wait_ms: wait_ms},
      %{provider: provider}
    )
  end

  defp bucket_sizes(provider, opts) do
    case {opts[:rpm], opts[:tpm]} do
      {rpm, tpm} when is_integer(rpm) and is_integer(tpm) -> {rpm, tpm}
      _ -> sizes_from_settings(provider, Tau.Settings.Cache.get())
    end
  end

  @doc false
  def sizes_from_settings(provider, settings) when is_atom(provider) do
    providers =
      Map.get(settings, :rate_limits) ||
        Map.get(settings, "rate_limits") ||
        %{}

    key_atom = provider
    key_str = to_string(provider)

    cfg =
      Map.get(providers, key_atom) ||
        Map.get(providers, key_str) ||
        %{}

    rpm = Map.get(cfg, :rpm) || Map.get(cfg, "rpm") || 0
    tpm = Map.get(cfg, :tpm) || Map.get(cfg, "tpm") || 0
    {rpm, tpm}
  end

  defp ceiling_during_half(new_target, current_size, half_until, now) do
    if now < half_until and new_target > current_size do
      current_size
    else
      new_target
    end
  end

  defp monotonic_now, do: System.monotonic_time(:millisecond)
end

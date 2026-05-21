defmodule Tau.CostTest do
  @moduledoc """
  Covers the `[:tau, :provider, :request, :stop]` -> ETS pipeline owned
  by `Tau.Cost.Tracker` (ADR-0010, #40). Events are emitted directly via
  `:telemetry.execute/3` — no need to drive a real session FSM, and the
  tracker's contract is precisely the telemetry shape.

  Runs `async: false` because `:tau_cost_counters` is a named, global
  ETS table and tests share it.
  """
  use ExUnit.Case, async: false

  setup do
    Tau.Cost.reset()
    :ok
  end

  defp emit(provider, model, session_id, usage, stop_reason \\ :end_turn) do
    :telemetry.execute(
      [:tau, :provider, :request, :stop],
      %{system_time: System.system_time(), usage: usage},
      %{provider: provider, model: model, session_id: session_id, stop_reason: stop_reason}
    )
  end

  describe "summary/0 after a single event" do
    test "lands counters in totals, by_provider, by_session" do
      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 10,
        output_tokens: 20,
        cache_read: 5,
        cache_write: 1
      })

      summary = Tau.Cost.summary()

      assert summary.totals == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read: 5,
               cache_write: 1
             }

      assert summary.by_provider[Tau.Providers.Anthropic] == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read: 5,
               cache_write: 1
             }

      assert summary.by_session["sess-1"] == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read: 5,
               cache_write: 1
             }
    end
  end

  describe "accumulation" do
    test "two events with same {provider, model, session_id} sum into a single bucket" do
      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 10,
        output_tokens: 20,
        cache_read: 5,
        cache_write: 1
      })

      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 3,
        output_tokens: 7,
        cache_read: 2,
        cache_write: 0
      })

      assert Tau.Cost.for_session("sess-1") == %{
               input_tokens: 13,
               output_tokens: 27,
               cache_read: 7,
               cache_write: 1
             }

      assert Tau.Cost.summary().totals == %{
               input_tokens: 13,
               output_tokens: 27,
               cache_read: 7,
               cache_write: 1
             }
    end
  end

  describe "multi-session aggregation" do
    test "different sessions appear separately under by_session but sum into totals" do
      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 10,
        output_tokens: 20,
        cache_read: 5,
        cache_write: 1
      })

      emit(Tau.Providers.Anthropic, "claude-x", "sess-2", %{
        input_tokens: 100,
        output_tokens: 200,
        cache_read: 0,
        cache_write: 0
      })

      summary = Tau.Cost.summary()

      assert summary.by_session["sess-1"] == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read: 5,
               cache_write: 1
             }

      assert summary.by_session["sess-2"] == %{
               input_tokens: 100,
               output_tokens: 200,
               cache_read: 0,
               cache_write: 0
             }

      assert summary.totals == %{
               input_tokens: 110,
               output_tokens: 220,
               cache_read: 5,
               cache_write: 1
             }
    end
  end

  describe "for_session/1" do
    test "returns just that session's counters across providers/models" do
      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 10,
        output_tokens: 20,
        cache_read: 5,
        cache_write: 1
      })

      emit(Tau.Providers.Anthropic, "claude-x", "sess-2", %{
        input_tokens: 999,
        output_tokens: 999,
        cache_read: 999,
        cache_write: 999
      })

      assert Tau.Cost.for_session("sess-1") == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read: 5,
               cache_write: 1
             }
    end

    test "returns zeros for an unknown session" do
      assert Tau.Cost.for_session("nope") == %{
               input_tokens: 0,
               output_tokens: 0,
               cache_read: 0,
               cache_write: 0
             }
    end
  end

  describe "AC-6 (SPEC-PROMPT-CACHING) — canonical cache-key usage map increments columns 4/5" do
    test "a canonical-key usage map bumps both cache_read and cache_write" do
      # The B3 canonical-key contract: an adapter's `merge_usage/2`
      # emits `:cache_read` / `:cache_write` (not Anthropic-wire
      # `cache_creation_input_tokens` / `cache_read_input_tokens`).
      # The Tracker reads exactly those keys — this fixture proves
      # columns 4 (cache_read) and 5 (cache_write) increment without
      # any Tracker change.
      emit(Tau.Providers.Anthropic, "claude-opus-4-7", "ac6-sess", %{
        input_tokens: 40,
        output_tokens: 12,
        cache_read: 6000,
        cache_write: 1500,
        cache_breakdown: %{ephemeral_5m: 1500, ephemeral_1h: 0}
      })

      counters = Tau.Cost.for_session("ac6-sess")
      assert counters.cache_read == 6000
      assert counters.cache_write == 1500
      assert counters.input_tokens == 40
      assert counters.output_tokens == 12
    end

    test "Anthropic-wire key names are NOT read — they leave the columns at zero" do
      # Regression guard for the bug B3 fixes: the pre-#317
      # `merge_usage/2` emitted `cache_creation_input_tokens` /
      # `cache_read_input_tokens`, which the Tracker silently
      # ignores. This documents that the wire names do not work.
      emit(Tau.Providers.Anthropic, "claude-opus-4-7", "ac6-wire-sess", %{
        input_tokens: 40,
        output_tokens: 12,
        cache_creation_input_tokens: 1500,
        cache_read_input_tokens: 6000
      })

      counters = Tau.Cost.for_session("ac6-wire-sess")
      assert counters.cache_read == 0
      assert counters.cache_write == 0
    end
  end

  describe "reset/0" do
    test "clears the table" do
      emit(Tau.Providers.Anthropic, "claude-x", "sess-1", %{
        input_tokens: 10,
        output_tokens: 20,
        cache_read: 5,
        cache_write: 1
      })

      :ok = Tau.Cost.reset()

      assert Tau.Cost.summary().totals == %{
               input_tokens: 0,
               output_tokens: 0,
               cache_read: 0,
               cache_write: 0
             }

      assert Tau.Cost.summary().by_provider == %{}
      assert Tau.Cost.summary().by_session == %{}
    end
  end
end

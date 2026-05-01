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

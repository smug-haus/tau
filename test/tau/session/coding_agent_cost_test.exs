defmodule Tau.Session.CodingAgentCostTest do
  @moduledoc """
  SPEC-CODING-AGENT §7 Q4 / D-038: when a coding-agent run emits a
  `%Event.Cost{}`, the session FSM MUST fold it into adapter-tagged
  totals so the user can see the split between provider-direct and
  coding-agent cost. The fold is observable in three places:

    * `data.coding_agent_costs` — in-memory list of
      `%Tau.CodingAgent.Cost{}` records (verified via snapshot).
    * `[:tau, :coding_agent, :cost]` telemetry — picked up by
      `Tau.Cost.Tracker` to update its ETS aggregator.
    * `~/.tau/sessions/<sid>.jsonl` — a `coding_agent_cost`
      event per fold so `/resume` can recompute totals.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.CodingAgent.Cost, as: CACost
  alias Tau.CodingAgent.Event, as: CAE
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-ca-cost-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)
    Tau.Cost.reset()

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  defp cost_fixture do
    [
      %CAE.Start{agent: :replay, version: "test"},
      %CAE.AssistantText{text: "doing work", turn: 0},
      %CAE.Cost{
        tokens: %{"input_tokens" => 100, "output_tokens" => 250, "cache_read_input_tokens" => 5},
        usd: 0.0123,
        duration_ms: 1234
      },
      %CAE.Done{exit_status: 0, final_message: nil}
    ]
  end

  defp start_with_fixture(fixture) do
    sid = "ca-cost-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        coding_agent: Tau.CodingAgents.Replay,
        coding_agent_workspace_backend: Tau.CodingAgent.Workspace.Cwd,
        coding_agent_ctx: %{replay_fixture: fixture}
      )

    sid
  end

  describe "Cost event folds into session totals" do
    test "[:tau, :coding_agent, :cost] telemetry fires with source tag" do
      parent = self()
      handler_id = "tau-ca-cost-tel-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :coding_agent, :cost],
        fn _e, m, meta, _ -> send(parent, {:tel_cost, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      sid = start_with_fixture(cost_fixture())
      Tau.send(sid, "do work")

      assert_receive {:tel_cost, m, meta}, 2_000

      assert m.usd > 0.0
      assert m.duration_ms == 1234
      assert m.input_tokens == 100
      assert m.output_tokens == 250
      assert m.cache_read == 5

      assert meta.session_id == sid
      assert meta.agent == Tau.CodingAgents.Replay
      assert meta.source == "coding_agent.replay"
    end

    test "Tau.Cost.Tracker picks the event up and adds a coding-agent row" do
      sid = start_with_fixture(cost_fixture())
      Tau.send(sid, "do work")

      assert_receive %SE.MessageEnd{}, 2_000
      # Tracker handler runs synchronously from :telemetry.execute/3,
      # so by the time MessageEnd is delivered the row is in ETS.

      summary = Tau.Cost.summary()

      assert is_integer(summary.totals.input_tokens)
      assert summary.totals.input_tokens >= 100
      assert summary.totals.output_tokens >= 250

      # by_provider keys carry the adapter module for coding-agent
      # rows; provider-direct rows keep their provider module.
      assert Map.has_key?(summary.by_provider, Tau.CodingAgents.Replay)
      replay_row = summary.by_provider[Tau.CodingAgents.Replay]
      assert replay_row.input_tokens == 100
      assert replay_row.output_tokens == 250
    end

    test "JSONL persists a coding_agent_cost line carrying the tagged record" do
      sid = start_with_fixture(cost_fixture())
      Tau.send(sid, "do work")

      assert_receive %SE.MessageEnd{}, 2_000

      events = Tau.Persistence.impl().stream(sid) |> Enum.to_list()

      cost_events =
        Enum.filter(events, &match?(%{"kind" => "coding_agent_cost"}, &1))

      assert length(cost_events) == 1
      [evt] = cost_events
      d = evt["data"]

      assert d["agent"] == "Elixir.Tau.CodingAgents.Replay"
      assert d["source"] == "coding_agent.replay"
      assert d["session_id"] == sid
      assert d["usd"] == 0.0123
      assert d["duration_ms"] == 1234
      assert d["input_tokens"] == 100
      assert d["output_tokens"] == 250
      assert d["cache_read"] == 5
    end

    test "from_jsonl round-trips a persisted record" do
      tagged = %CACost{
        agent: :claude_code,
        session_id: "sess-1",
        adapter_session_id: "claude-abc",
        usd: 0.05,
        duration_ms: 5000,
        input_tokens: 1_000,
        output_tokens: 2_500,
        cache_read: 0,
        cache_write: 0,
        raw_tokens: %{"input_tokens" => 1_000}
      }

      jsonl = CACost.to_jsonl(tagged)
      back = CACost.from_jsonl(jsonl)

      assert back.session_id == "sess-1"
      assert back.adapter_session_id == "claude-abc"
      assert back.usd == 0.05
      assert back.input_tokens == 1_000
      assert back.output_tokens == 2_500
    end

    test "totals/1 sums dollar and token columns and breaks down by source" do
      records = [
        %CACost{
          agent: :claude_code,
          usd: 0.10,
          duration_ms: 100,
          input_tokens: 10,
          output_tokens: 20
        },
        %CACost{
          agent: :claude_code,
          usd: 0.05,
          duration_ms: 50,
          input_tokens: 5,
          output_tokens: 10
        },
        %CACost{agent: :replay, usd: nil, duration_ms: 1, input_tokens: 1, output_tokens: 1}
      ]

      t = CACost.totals(records)

      assert_in_delta t.usd, 0.15, 1.0e-6
      assert t.duration_ms == 151
      assert t.input_tokens == 16
      assert t.output_tokens == 31
      assert_in_delta t.by_source["coding_agent.claude_code"], 0.15, 1.0e-6
      # `usd: nil` is treated as 0.0 for the totals — explicit "unknown" sentinel.
      assert_in_delta t.by_source["coding_agent.replay"], 0.0, 1.0e-6
    end
  end

  describe "D-035 — folding never crashes the session" do
    test "a malformed Cost event still finishes the turn cleanly" do
      fixture = [
        %CAE.Start{agent: :replay, version: "test"},
        %CAE.AssistantText{text: "ok", turn: 0},
        # Tokens is non-map: from_event/2 normalises to zeros without raising.
        %CAE.Cost{tokens: :bogus, usd: nil, duration_ms: 0},
        %CAE.Done{exit_status: 0, final_message: nil}
      ]

      sid = start_with_fixture(fixture)
      Tau.send(sid, "anything")

      assert_receive %SE.MessageEnd{message: msg}, 2_000
      assert msg.stop_reason == :end_turn
    end
  end
end

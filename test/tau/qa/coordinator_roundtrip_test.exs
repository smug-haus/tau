defmodule Tau.QA.CoordinatorRoundtripTest do
  @moduledoc """
  Layer (F) of `mix tau.qa` (issue #268).

  End-to-end smoke for the WHOLE coordinator pipeline: persona load
  → tool exposure → `Agent` dispatch → child session lifecycle →
  `ToolResult` return → parent terminal turn → JSONL persistence.

  Uses `Tau.Test.MultiFixtureProvider` scripted with:

    * Turn 1 (parent): an `Agent` tool_call (`subagent_type:
      "tau-implementer"`, a trivial brief).
    * Child session: a single `:end_turn` text turn.
    * Turn 2 (parent): a terminal text/`:end_turn` turn.

  Assertions:

    * The parent reaches `:awaiting_user` (i.e. `start_session` →
      `Tau.send/2` → `MessageEnd{stop_reason: :end_turn}` ran clean
      end-to-end with no exception bubbling out).
    * The parent JSONL contains an `assistant_message` whose
      `data.content` includes a block with
      `%{"type" => "tool_call", "name" => "Agent"}`.
    * The parent JSONL contains a subsequent `tool_result` record.

  These two records together demonstrate the whole pipeline — if the
  `Agent` tool dispatch is broken (the #264-class regression where
  the model can call its tools but the dispatcher silently drops the
  call, or the child cascade never returns a result), one or both
  records is absent and the test FAILS.

  `async: false` because (a) `:data_dir` is overridden via
  `Application.put_env/3` and (b) the test subscribes to the parent's
  PubSub topic.
  """

  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE
  alias Tau.Test.MultiFixtureProvider

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "tau-qa-coordinator-roundtrip-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{tmp: tmp}
  end

  defp jsonl_rows(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "parent → Agent tool_call → child → tool_result → terminal text round-trip",
       %{tmp: tmp} do
    parent_sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent_sid}")

    call_id = "qa-rt-agent-call"
    brief = "Trivial brief: respond with 'ok' and terminate."

    # Turn 1: parent emits a single `Agent` tool_call.
    parent_first =
      [
        %Event.Start{request_id: "parent-r1", model: "multi-fixture"},
        %Event.ToolCallStart{tool_call_id: call_id, name: "Agent"},
        %Event.ToolCallEnd{
          tool_call_id: call_id,
          params: %{
            "description" => brief,
            "subagent_type" => "tau-implementer"
          }
        },
        %Event.Done{stop_reason: :tool_use, usage: %{}}
      ]

    # Turn 2: parent emits a terminal text + end_turn.
    parent_second =
      [
        %Event.Start{request_id: "parent-r2", model: "multi-fixture"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "parent terminal"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :end_turn, usage: %{}}
      ]

    # Child: one end_turn text turn.
    child =
      [
        %Event.Start{request_id: "child-r1", model: "multi-fixture"},
        %Event.TextStart{block_id: "b0"},
        %Event.TextDelta{block_id: "b0", text: "child ok"},
        %Event.TextEnd{block_id: "b0"},
        %Event.Done{stop_reason: :end_turn, usage: %{}}
      ]

    provider_ctx = %{
      parent_session_id: parent_sid,
      parent_first_fixture: parent_first,
      parent_second_fixture: parent_second,
      child_fixture: child
    }

    {:ok, ^parent_sid} =
      start_session_for_test(
        provider: MultiFixtureProvider,
        session_id: parent_sid,
        cwd: tmp,
        # SPEC-PERMISSION-PROMPTS: bypass permissions — this test exercises
        # the coordinator round-trip, not the permission system.
        metadata: %{permissions_mode: :bypass},
        provider_ctx: provider_ctx
      )

    Tau.send(parent_sid, "please delegate to a sub-agent")

    # Parent's Agent ToolEnd lands.
    assert_receive %SE.ToolEnd{
                     tool_call_id: ^call_id,
                     result: %Tau.Message.ToolResult{
                       tool_name: "Agent",
                       is_error: false
                     }
                   },
                   15_000

    # Parent's terminal end_turn.
    assert_receive %SE.MessageEnd{message: %{stop_reason: :end_turn}}, 15_000

    {:ok, snap} = Tau.snapshot(parent_sid)
    assert snap.state == :awaiting_user

    # Inspect parent JSONL — must contain both the Agent tool_call
    # (as a block inside an assistant_message) AND a tool_result
    # record. These two records prove the whole pipeline ran.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{parent_sid}.jsonl"))
    rows = jsonl_rows(path)

    assistant_msgs = Enum.filter(rows, &(&1["kind"] == "assistant_message"))

    agent_tool_calls =
      assistant_msgs
      |> Enum.flat_map(fn row ->
        case get_in(row, ["data", "content"]) do
          blocks when is_list(blocks) ->
            Enum.filter(blocks, fn b ->
              is_map(b) and b["type"] == "tool_call" and b["name"] == "Agent"
            end)

          _ ->
            []
        end
      end)

    assert agent_tool_calls != [],
           "expected parent JSONL to contain an assistant_message with a tool_call(name: \"Agent\") block; got kinds=#{inspect(Enum.map(rows, & &1["kind"]))}"

    tool_results = Enum.filter(rows, &(&1["kind"] == "tool_result"))

    assert tool_results != [],
           "expected parent JSONL to contain a tool_result record after the Agent dispatch; got kinds=#{inspect(Enum.map(rows, & &1["kind"]))}"
  end
end

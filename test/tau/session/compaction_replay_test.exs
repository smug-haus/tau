defmodule Tau.Session.CompactionReplayTest do
  @moduledoc """
  Verifies that a `compaction` event in a persisted JSONL transcript
  is reconstructed as a synthetic user message when the session is
  forked. Issue #5: previously `events_to_messages/1` matched only
  user/assistant/tool_result kinds and the compaction event fell into
  the catch-all `nil` clause, so forks lost the summary.

  Drives `Tau.fork/2` against a hand-crafted JSONL log to exercise the
  whole replay path without needing to trigger a real compaction by
  pushing past the message threshold.
  """
  use ExUnit.Case, async: false

  alias Tau.Persistence.Jsonl

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "tau-compaction-replay-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    cwd = Path.join(System.tmp_dir!(), "tau-compaction-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".git"))

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf!(cwd)
      Application.delete_env(:tau, :data_dir)
    end)

    # No provider_ctx needed: this test exercises Tau.fork/2 only,
    # which never drives the provider — it just reads the freshly-forked
    # session's data.messages.
    %{cwd: cwd, data_dir: tmp}
  end

  test "fork/2 replays compaction events as system-tagged summary messages",
       %{cwd: cwd} do
    parent_sid = "compaction-parent-#{System.unique_integer([:positive])}"
    cutoff_event_id = "evt_cutoff_#{System.unique_integer([:positive])}"

    # Write a JSONL transcript by hand: header, user, compaction (with summary),
    # then a final user message we'll fork at.
    path = Jsonl.path_for(parent_sid, cwd)
    File.mkdir_p!(Path.dirname(path))

    header = %{
      "id" => "header_" <> parent_sid,
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "session_header",
      "data" => %{
        "session_id" => parent_sid,
        "cwd" => cwd,
        "provider" => inspect(Tau.Providers.Replay),
        "model" => "replay-test",
        "metadata" => %{}
      }
    }

    user_msg = %{
      "id" => "evt_user_a",
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "user_message",
      "data" => %{"role" => "user", "content" => "first"}
    }

    compaction = %{
      "id" => "evt_compact",
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "compaction",
      "data" => %{
        "before_count" => 50,
        "after_count" => 21,
        "summary" =>
          "<conversation_summary>\nThe user asked about X and we did Y.\n</conversation_summary>"
      }
    }

    user_after = %{
      "id" => cutoff_event_id,
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "user_message",
      "data" => %{"role" => "user", "content" => "after compaction"}
    }

    File.write!(
      path,
      Enum.map_join([header, user_msg, compaction, user_after], "\n", &Jason.encode!/1) <> "\n"
    )

    # Fork at the post-compaction user event — should pull all four events in.
    # The fork spawns a fresh session FSM; stop it on test exit so it doesn't
    # leak across the suite (#52).
    {:ok, child_sid} = Tau.fork(parent_sid, cutoff_event_id)
    on_exit(fn -> Tau.stop(child_sid) end)
    assert child_sid != parent_sid

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, child_sid)
    {_state, data} = :sys.get_state(pid)

    summary_msg =
      Enum.find(data.messages, fn
        %Tau.Message.User{metadata: %{role: :compaction_summary}} -> true
        _ -> false
      end)

    assert summary_msg, "fork should reconstruct the compaction summary as a user message"
    assert summary_msg.content =~ "asked about X"

    # Original user messages should still be present (full-history replay).
    assert Enum.any?(data.messages, fn
             %Tau.Message.User{content: "first"} -> true
             _ -> false
           end)

    assert Enum.any?(data.messages, fn
             %Tau.Message.User{content: "after compaction"} -> true
             _ -> false
           end)
  end

  test "compaction events without a :summary field are silently dropped on replay",
       %{cwd: cwd} do
    # Backwards-compatibility check: pre-#5 transcripts have only
    # before_count/after_count. Replay should not synthesise an empty
    # summary message.
    parent_sid = "compaction-legacy-#{System.unique_integer([:positive])}"
    cutoff_event_id = "evt_legacy_#{System.unique_integer([:positive])}"

    path = Jsonl.path_for(parent_sid, cwd)
    File.mkdir_p!(Path.dirname(path))

    header = %{
      "id" => "header_" <> parent_sid,
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "session_header",
      "data" => %{
        "session_id" => parent_sid,
        "cwd" => cwd,
        "provider" => inspect(Tau.Providers.Replay),
        "model" => "replay-test",
        "metadata" => %{}
      }
    }

    legacy_compaction = %{
      "id" => "evt_legacy_c",
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "compaction",
      "data" => %{"before_count" => 50, "after_count" => 21}
    }

    user_after = %{
      "id" => cutoff_event_id,
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "user_message",
      "data" => %{"role" => "user", "content" => "later turn"}
    }

    File.write!(
      path,
      Enum.map_join([header, legacy_compaction, user_after], "\n", &Jason.encode!/1) <> "\n"
    )

    {:ok, child_sid} = Tau.fork(parent_sid, cutoff_event_id)
    on_exit(fn -> Tau.stop(child_sid) end)
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, child_sid)
    {_state, data} = :sys.get_state(pid)

    refute Enum.any?(data.messages, fn
             %Tau.Message.User{metadata: %{role: :compaction_summary}} -> true
             _ -> false
           end)
  end
end

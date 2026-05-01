defmodule Tau.Persistence.ThinkingRoundtripPropertyTest do
  @moduledoc """
  Audit: thinking-block signature byte-exact preservation through the
  JSONL persistence layer and through Tau.fork/2 session reconstruction.

  Anthropic's signed thinking blocks reject the *next* request if the
  signature does not byte-exactly match what the model emitted on the
  previous turn. Any silent normalisation (whitespace trimming,
  base64 re-encoding, Jason quirks, FSM serialisation drift) corrupts
  the signature and surfaces in production as opaque 4xx responses.

  These properties pin the contract:

  1. The JSONL line written for an `assistant_message` event preserves
     the signature byte-for-byte. Driven through a Replay session so
     `Tau.Session`'s `serialize_block/1` participates.

  2. `Tau.fork/2` reconstructs the message stream via the inverse path
     (`events_to_messages/1` → `deserialize_block/1`) and yields a
     `%Tau.Message.Assistant{}` whose thinking-block signature is
     byte-for-byte equal to what was on disk.

  Issue #68. Adopted from Opal's audit of the same pattern.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Persistence.Jsonl
  alias Tau.Provider.Event

  @moduletag :property

  setup do
    # Per-test data dir so JSONL files don't collide between iterations.
    tmp = Path.join(System.tmp_dir!(), "tau-thinking-rt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    cwd = Path.join(tmp, "cwd")
    File.mkdir_p!(cwd)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp, cwd: cwd}
  end

  # ------------------------------------------------------------------
  # Generators
  # ------------------------------------------------------------------

  # Anthropic signatures are emitted as base64 strings — ASCII-safe and
  # round-trippable through JSON. We exercise the full base64 alphabet
  # plus printable ASCII (the realistic on-the-wire case).
  defp base64_signature_gen do
    StreamData.bind(
      StreamData.binary(min_length: 1, max_length: 256),
      fn raw -> StreamData.constant(Base.encode64(raw)) end
    )
  end

  # A broader generator: any printable Unicode string. Includes whitespace,
  # control chars, and non-ASCII codepoints so we catch any pipeline that
  # strips them. Stays UTF-8-valid because Jason.encode!/1 requires UTF-8.
  defp printable_signature_gen do
    StreamData.string(:printable, min_length: 1, max_length: 128)
  end

  defp signature_gen do
    StreamData.one_of([base64_signature_gen(), printable_signature_gen()])
  end

  defp thinking_text_gen do
    StreamData.string(:printable, min_length: 0, max_length: 32)
  end

  # ------------------------------------------------------------------
  # Property 1 — End-to-end: a Replay session emits a thinking block
  # carrying signature S; the JSONL line for the assistant_message
  # event has signature byte-equal to S.
  #
  # This exercises the full *write* path: Assembler → Tau.Session
  # serialize_block/1 → Tau.Persistence.Jsonl.append/2 → Jason.encode!.
  # ------------------------------------------------------------------

  property "JSONL persistence preserves thinking-signature byte-for-byte" do
    check all(
            signature <- signature_gen(),
            text <- thinking_text_gen()
          ),
          max_runs: 25 do
      {sid, path} = drive_session_with_thinking(signature, text)

      lines = read_jsonl(path)
      assistant = find_assistant_event(lines)
      refute is_nil(assistant), "no assistant_message event in JSONL"

      block = thinking_block(assistant)
      refute is_nil(block), "no thinking block in assistant content"

      assert block["signature"] == signature,
             "signature drift: expected #{inspect(signature)}, got #{inspect(block["signature"])}"

      # Byte-equality check: identical byte_size and identical bytes.
      assert byte_size(block["signature"]) == byte_size(signature)
      assert :erlang.binary_to_list(block["signature"]) == :erlang.binary_to_list(signature)

      # Text round-trips too — sanity-check we didn't lose the rest of
      # the block while preserving the signature.
      assert block["text"] == text

      # Stop the session and unsubscribe before the next iteration so the
      # JSONL writer process is closed, the file descriptor released, and
      # this test's mailbox isn't flooded with stale broadcasts.
      Tau.stop(sid)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end
  end

  # ------------------------------------------------------------------
  # Property 2 — Fork-and-resume bit-equality.
  #
  # Hand-write a JSONL transcript containing an assistant_message with
  # a thinking block carrying signature S, then call Tau.fork/2. Read
  # the reconstructed session's snapshot and assert the assembled
  # %Tau.Message.Assistant{} has a thinking block whose signature is
  # byte-equal to S.
  #
  # This exercises the full *read* path: File.stream! → Jason.decode! →
  # Tau.Session.events_to_messages/1 → deserialize_block/1.
  #
  # Hand-writing the JSONL (as test/tau/session/compaction_replay_test.exs
  # does) bypasses the :delayed_write writer-buffer race that would
  # otherwise let the fork see partial data.
  # ------------------------------------------------------------------

  property "Tau.fork/2 reconstructs thinking-signature byte-for-byte", %{cwd: cwd} do
    check all(
            signature <- signature_gen(),
            text <- thinking_text_gen()
          ),
          max_runs: 25 do
      parent_sid = "thinking-parent-#{System.unique_integer([:positive])}"
      asst_event_id = "evt_asst_#{System.unique_integer([:positive])}"

      write_thinking_transcript(parent_sid, cwd, asst_event_id, signature, text)

      {:ok, child_sid} = Tau.fork(parent_sid, asst_event_id)
      on_exit(fn -> Tau.stop(child_sid) end)

      {:ok, snap} = Tau.Session.snapshot(child_sid)

      assistant_msg =
        Enum.find(snap.messages, fn
          %Tau.Message.Assistant{} -> true
          _ -> false
        end)

      refute is_nil(assistant_msg), "fork did not preload an Assistant message"

      block = Enum.find(assistant_msg.content, &(&1.type == :thinking))
      refute is_nil(block), "fork did not preload a thinking block"

      assert block.signature == signature,
             "fork signature drift: expected #{inspect(signature)}, got #{inspect(block.signature)}"

      assert byte_size(block.signature) == byte_size(signature)
      assert :erlang.binary_to_list(block.signature) == :erlang.binary_to_list(signature)

      assert block.text == text

      # Stop the forked child so we don't leak FSMs across iterations.
      Tau.stop(child_sid)
    end
  end

  # ------------------------------------------------------------------
  # Example anchors — explicit edge-case fixtures, checked once each.
  # Useful as regression markers when the property generators above
  # ever shrink to a less interesting case. Per non-negotiable #6:
  # examples come second, as illustrations of the property.
  # ------------------------------------------------------------------

  test "edge-case signatures round-trip byte-exact through fork", %{cwd: cwd} do
    edge_cases = [
      # Realistic Anthropic signature shape (~ 1 KiB base64).
      Base.encode64(:crypto.strong_rand_bytes(768)),
      # Whitespace-bearing — would be corrupted by any trim step.
      "sig with spaces  and\ttabs",
      "leading-newline\nstill-here",
      # Unicode in case any future provider includes non-ASCII.
      "signature-Ω-✓-中",
      # Empty-but-present (treated as a binary, not nil).
      ""
    ]

    Enum.each(edge_cases, fn signature ->
      parent_sid = "thinking-edge-#{System.unique_integer([:positive])}"
      asst_event_id = "evt_edge_#{System.unique_integer([:positive])}"

      write_thinking_transcript(parent_sid, cwd, asst_event_id, signature, "thought")

      {:ok, child_sid} = Tau.fork(parent_sid, asst_event_id)
      on_exit(fn -> Tau.stop(child_sid) end)

      {:ok, snap} = Tau.Session.snapshot(child_sid)
      msg = Enum.find(snap.messages, &match?(%Tau.Message.Assistant{}, &1))
      block = Enum.find(msg.content, &(&1.type == :thinking))

      assert block.signature == signature,
             "edge-case drift on #{inspect(signature)}: got #{inspect(block.signature)}"
    end)
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Drive a Replay session that emits exactly one thinking block carrying
  # the given signature. Wait until the JSONL writer has flushed the
  # assistant_message line to disk (`:delayed_write` 100 ms timer), then
  # return the session id and JSONL path.
  defp drive_session_with_thinking(signature, text) do
    fixture = [
      %Event.Start{request_id: "r", model: "replay-test"},
      %Event.ThinkingStart{block_id: "t0"},
      %Event.ThinkingDelta{block_id: "t0", text: text},
      %Event.ThinkingEnd{block_id: "t0", signature: signature},
      %Event.Done{stop_reason: :stop, usage: %{output_tokens: 1}}
    ]

    sid = "test-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay-test",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture}
      )

    Tau.send(sid, "drive thinking")
    wait_for_message_end(sid, 2_000)
    path = locate_jsonl(sid)

    # The JSONL writer uses :delayed_write with a 100 ms idle flush. A
    # fresh File.read! does not see process-buffered bytes, so we wait
    # until the assistant_message line is visible on disk.
    wait_for_assistant_line(path, 2_000)

    {sid, path}
  end

  defp wait_for_message_end(sid, timeout_ms) do
    receive do
      %Tau.Session.Events.MessageEnd{session_id: ^sid} -> :ok
      %Tau.Session.Events.SessionEnd{session_id: ^sid} -> :ok
      _other -> wait_for_message_end(sid, timeout_ms)
    after
      timeout_ms -> flunk("session #{sid} did not emit MessageEnd within #{timeout_ms}ms")
    end
  end

  defp wait_for_assistant_line(path, deadline_ms) do
    end_at = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_for_assistant_line(path, end_at)
  end

  defp do_wait_for_assistant_line(path, end_at) do
    visible? =
      File.exists?(path) and
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case Jason.decode(line) do
            {:ok, %{"kind" => "assistant_message"}} -> true
            _ -> false
          end
        end)

    cond do
      visible? ->
        :ok

      System.monotonic_time(:millisecond) > end_at ->
        flunk("assistant_message not on disk within deadline")

      true ->
        Process.sleep(20)
        do_wait_for_assistant_line(path, end_at)
    end
  end

  defp locate_jsonl(sid) do
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))
    path
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp find_assistant_event(lines) do
    Enum.find(lines, &(&1["kind"] == "assistant_message"))
  end

  defp thinking_block(assistant_event) do
    Enum.find(assistant_event["data"]["content"], &(&1["type"] == "thinking"))
  end

  # Hand-written JSONL transcript carrying a single assistant_message with
  # a thinking block. Mirrors Tau.Session.message_to_data/1 and
  # serialize_block/1 exactly so the Tau.fork/2 deserialiser sees the
  # canonical on-disk shape.
  defp write_thinking_transcript(parent_sid, cwd, asst_event_id, signature, text) do
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

    user = %{
      "id" => "evt_user_#{System.unique_integer([:positive])}",
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "user_message",
      "data" => %{"role" => "user", "content" => "ping"}
    }

    assistant = %{
      "id" => asst_event_id,
      "parent_id" => nil,
      "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "kind" => "assistant_message",
      "data" => %{
        "role" => "assistant",
        "content" => [
          %{"type" => "thinking", "text" => text, "signature" => signature}
        ],
        "stop_reason" => "stop",
        "usage" => %{},
        "model" => "replay-test"
      }
    }

    File.write!(
      path,
      Enum.map_join([header, user, assistant], "\n", &Jason.encode!/1) <> "\n"
    )
  end
end

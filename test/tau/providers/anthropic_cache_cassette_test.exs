defmodule Tau.Providers.AnthropicCacheCassetteTest do
  @moduledoc """
  SPEC-PROMPT-CACHING AC-2 — the response-side B3 normalisation path,
  end-to-end (hops 1 → 5).

  A `Bypass`-served Anthropic SSE response drives the *real*
  `Tau.Providers.Anthropic.decode/2` → `merge_usage/2` path — the same
  harness used by `anthropic/http_error_stream_test.exs`.
  `Tau.Providers.Replay` is deliberately NOT used: it is a distinct
  adapter that never runs `Anthropic.decode/2` and so cannot exercise
  B3 hop 1.

  Coverage:

    * hop 1 — `merge_usage/2` emits canonical `:cache_read` /
      `:cache_write` keys on the `%Event.Done{}.usage` map;
    * hops 2–5 — when driven through a real `Tau.Session`, the
      `[:tau, :session, :cache_usage]` telemetry fires with the
      correct split and the `Tau.Cost.Tracker` ETS row for the
      session shows the `cache_read` / `cache_write` columns
      incremented.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Message.User
  alias Tau.Provider.Event
  alias Tau.Providers.Anthropic
  alias Tau.Session.Events, as: SE

  # A minimal but well-formed Anthropic SSE response. `cache_*` token
  # values are injected by the caller into the `message_start` usage
  # block so each test exercises a distinct cache scenario.
  defp sse_body(usage) do
    [
      sse("message_start", %{
        "type" => "message_start",
        "message" => %{"id" => "msg_cache_test", "model" => "claude-opus-4-7", "usage" => usage}
      }),
      sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "hi"}
      }),
      sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 7}
      }),
      sse("message_stop", %{"type" => "message_stop"})
    ]
    |> Enum.join()
  end

  defp sse(event, json), do: "event: #{event}\ndata: #{Jason.encode!(json)}\n\n"

  defp serve(bypass, usage) do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.resp(200, sse_body(usage))
    end)
  end

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    Application.put_env(:tau, Tau.Providers.Anthropic,
      base_url: base_url,
      api_key: "sk-ant-api03-cache-cassette-test"
    )

    tmp = Path.join(System.tmp_dir!(), "tau-cache-cassette-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.Anthropic)
      Application.delete_env(:tau, :data_dir)
      File.rm_rf!(tmp)
    end)

    %{bypass: bypass}
  end

  describe "hop 1 — Anthropic.decode/2 + merge_usage/2 emit canonical keys" do
    test "a cache-write response yields canonical :cache_write on %Event.Done{}.usage",
         %{bypass: bypass} do
      serve(bypass, %{
        "input_tokens" => 12,
        "cache_creation_input_tokens" => 2048,
        "cache_read_input_tokens" => 0
      })

      {:ok, stream} =
        Anthropic.stream([User.new("hello")], %{model: "claude-opus-4-7"}, %{})

      done = Enum.find(Enum.to_list(stream), &match?(%Event.Done{}, &1))
      assert %Event.Done{usage: usage} = done

      assert usage.cache_write == 2048
      assert usage.cache_read == 0
      refute Map.has_key?(usage, :cache_creation_input_tokens)
      refute Map.has_key?(usage, :cache_read_input_tokens)
    end

    test "a cache-read response yields canonical :cache_read on %Event.Done{}.usage",
         %{bypass: bypass} do
      serve(bypass, %{
        "input_tokens" => 9,
        "cache_creation_input_tokens" => 0,
        "cache_read_input_tokens" => 4096
      })

      {:ok, stream} =
        Anthropic.stream([User.new("hello")], %{model: "claude-opus-4-7"}, %{})

      done = Enum.find(Enum.to_list(stream), &match?(%Event.Done{}, &1))
      assert %Event.Done{usage: usage} = done

      assert usage.cache_read == 4096
      assert usage.cache_write == 0
    end
  end

  describe "hops 2-5 — session telemetry + cost tracker" do
    test "a cache-write turn fires [:tau, :session, :cache_usage] and bumps the cost tracker",
         %{bypass: bypass} do
      Tau.Cost.reset()

      serve(bypass, %{
        "input_tokens" => 30,
        "cache_creation_input_tokens" => 1500,
        "cache_read_input_tokens" => 6000
      })

      sid = "cache-cassette-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

      test_pid = self()
      handler_id = "cache-usage-tel-#{sid}"

      :telemetry.attach(
        handler_id,
        [:tau, :session, :cache_usage],
        fn _ev, m, meta, _ -> send(test_pid, {:cache_usage, m, meta}) end,
        nil
      )

      try do
        {:ok, ^sid} =
          start_session_for_test(
            session_id: sid,
            provider: Tau.Providers.Anthropic,
            model: "claude-opus-4-7"
          )

        :ok = Tau.send(sid, "hello")

        # hop 5 — the cache-usage telemetry fires with the split.
        assert_receive {:cache_usage, %{write_tokens: 1500, read_tokens: 6000, storage_tokens: 0},
                        %{session_id: ^sid, provider: Tau.Providers.Anthropic}},
                       5_000

        # The turn completes cleanly.
        assert_receive %SE.MessageEnd{
                         session_id: ^sid,
                         message: %Tau.Message.Assistant{stop_reason: stop_reason}
                       },
                       5_000

        refute stop_reason == :error

        # hop 4 — the cost tracker's ETS row for this session shows
        # both cache columns incremented.
        counters = Tau.Cost.for_session(sid)
        assert counters.cache_write == 1500
        assert counters.cache_read == 6000
      after
        :telemetry.detach(handler_id)
        Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
      end
    end
  end
end

defmodule Tau.Providers.MistralTest do
  @moduledoc """
  Enforces the OTP non-negotiable (B5, SPEC-USER-TURN §4): non-2xx HTTP
  responses from the Mistral API MUST yield `%Tau.Provider.Event.Error{}`
  stream items — never raise. Missing API key MUST yield a synchronous
  `{:error, :missing_api_key}` without a network call.

  Uses Bypass to stub the Mistral endpoint; no real network call is made.
  """
  use ExUnit.Case, async: false

  alias Tau.Message.User
  alias Tau.Provider.Event
  alias Tau.Providers.Mistral

  @sse_text_chunk Jason.encode!(%{
                    "id" => "chatcmpl-m1",
                    "model" => "mistral-large-latest",
                    "choices" => [
                      %{
                        "delta" => %{"role" => "assistant", "content" => "Hello"},
                        "finish_reason" => nil,
                        "index" => 0
                      }
                    ]
                  })

  @sse_done_chunk Jason.encode!(%{
                    "id" => "chatcmpl-m1",
                    "model" => "mistral-large-latest",
                    "choices" => [
                      %{
                        "delta" => %{},
                        "finish_reason" => "stop",
                        "index" => 0
                      }
                    ]
                  })

  defp sse_body(chunks) do
    data_lines = Enum.map(chunks, fn c -> "data: #{c}\n\n" end)
    Enum.join(data_lines) <> "data: [DONE]\n\n"
  end

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}/v1"

    Application.put_env(:tau, Tau.Providers.Mistral,
      api_key: "mistral-test-key",
      base_url: base_url
    )

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.Mistral)
    end)

    %{bypass: bypass}
  end

  describe "api_key/0 missing → synchronous error" do
    test "stream/3 returns {:error, :missing_api_key} when no key configured" do
      # Remove the key set by setup
      Application.put_env(:tau, Tau.Providers.Mistral,
        api_key: nil,
        base_url: "http://localhost:9999/v1"
      )

      result = Mistral.stream([User.new("hi")], %{}, %{})
      assert {:error, :missing_api_key} = result
    end
  end

  describe "happy-path stream" do
    test "text delta emits Event.Start, TextStart, TextDelta, TextEnd, Done", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
      end)

      assert {:ok, stream} = Mistral.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?(%Event.Start{}, &1)),
             "Expected Event.Start; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.TextStart{block_id: "text"}, &1)),
             "Expected Event.TextStart; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.TextDelta{block_id: "text", text: "Hello"}, &1)),
             "Expected Event.TextDelta with 'Hello'; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.Done{stop_reason: :stop}, &1)),
             "Expected Event.Done{stop_reason: :stop}; got: #{inspect(events)}"
    end
  end

  describe "HTTP error responses yield in-stream Event.Error, no raise" do
    test "HTTP 401 → %Event.Error{reason: {:http_status, 401, _}, retryable?: false}",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => %{
              "type" => "authentication_error",
              "message" => "Invalid API key"
            }
          })
        )
      end)

      assert {:ok, stream} = Mistral.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.Error{reason: {:http_status, 401, _}, retryable?: false} -> true
               _ -> false
             end),
             "Expected non-retryable Event.Error for 401; got: #{inspect(events)}"
    end

    test "HTTP 429 → %Event.Error{reason: {:http_status, 429, _}, retryable?: true}",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{
            "error" => %{
              "type" => "rate_limit_error",
              "message" => "Rate limit exceeded"
            }
          })
        )
      end)

      assert {:ok, stream} = Mistral.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.Error{reason: {:http_status, 429, _}, retryable?: true} -> true
               _ -> false
             end),
             "Expected retryable Event.Error for 429; got: #{inspect(events)}"
    end

    test "stream does not raise on 401 or 429", %{bypass: bypass} do
      for status <- [401, 429] do
        Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            status,
            Jason.encode!(%{"error" => %{"type" => "error", "message" => "error"}})
          )
        end)

        assert {:ok, stream} = Mistral.stream([User.new("hello")], %{}, %{})
        events = Enum.to_list(stream)

        assert Enum.any?(events, &match?(%Event.Error{}, &1)),
               "Expected Event.Error for #{status}; got: #{inspect(events)}"
      end
    end
  end
end

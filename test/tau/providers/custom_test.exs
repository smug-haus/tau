defmodule Tau.Providers.CustomTest do
  @moduledoc """
  Enforces C81 (SPEC-USER-TURN §3): `Tau.Providers.Custom` is a
  configure-by-URL OpenAI-Chat-compatible provider.

  - Missing base_url → synchronous `{:error, :missing_base_url}`, no network call.
  - nil api_key is valid → stream/3 returns `{:ok, stream}`; no `Authorization` header emitted.
  - configured `:headers` extras are forwarded on the request.
  - opts[:model] overrides the configured default (request body `model` field).
  - HTTP 401 → in-stream `%Event.Error{retryable?: false}`; 429 → `retryable?: true`.
  - stream/3 never raises on network errors.

  Uses Bypass to stub the endpoint; no real network calls are made.
  """
  use ExUnit.Case, async: false

  alias Tau.Message.User
  alias Tau.Provider.Event
  alias Tau.Providers.Custom

  @sse_text_chunk Jason.encode!(%{
                    "id" => "chatcmpl-cu1",
                    "model" => "custom-model",
                    "choices" => [
                      %{
                        "delta" => %{"role" => "assistant", "content" => "Hello"},
                        "finish_reason" => nil,
                        "index" => 0
                      }
                    ]
                  })

  @sse_done_chunk Jason.encode!(%{
                    "id" => "chatcmpl-cu1",
                    "model" => "custom-model",
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
    base_url = "http://localhost:#{bypass.port}"

    Application.put_env(:tau, Tau.Providers.Custom,
      base_url: base_url,
      api_key: "custom-test-key"
    )

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.Custom)
    end)

    %{bypass: bypass, base_url: base_url}
  end

  describe "missing base_url → synchronous error, no network call" do
    test "stream/3 returns {:error, :missing_base_url} when no base_url configured" do
      Application.put_env(:tau, Tau.Providers.Custom,
        base_url: nil,
        api_key: "some-key"
      )

      result = Custom.stream([User.new("hi")], %{}, %{})
      assert {:error, :missing_base_url} = result
    end

    test "empty string base_url → {:error, :missing_base_url}" do
      Application.put_env(:tau, Tau.Providers.Custom,
        base_url: "",
        api_key: "some-key"
      )

      result = Custom.stream([User.new("hi")], %{}, %{})
      assert {:error, :missing_base_url} = result
    end
  end

  describe "C81: nil api_key is valid — no Authorization header emitted" do
    test "nil api_key: stream/3 returns {:ok, stream} and request has no authorization header",
         %{bypass: bypass} do
      Application.put_env(:tau, Tau.Providers.Custom,
        base_url: "http://localhost:#{bypass.port}",
        api_key: nil
      )

      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(parent, {:auth_header, auth_header})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
      Enum.to_list(stream)

      assert_received {:auth_header, []}
    end
  end

  describe "happy-path stream" do
    test "text delta emits Event.Start, TextStart, TextDelta, Done", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?(%Event.Start{}, &1)),
             "Expected Event.Start; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.TextStart{block_id: "text"}, &1)),
             "Expected Event.TextStart; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.TextDelta{block_id: "text", text: "Hello"}, &1)),
             "Expected Event.TextDelta 'Hello'; got: #{inspect(events)}"

      assert Enum.any?(events, &match?(%Event.Done{stop_reason: :stop}, &1)),
             "Expected Event.Done{stop_reason: :stop}; got: #{inspect(events)}"
    end
  end

  describe "configured :headers extras are forwarded on the request" do
    test "extra headers from app env appear on the outbound request", %{bypass: bypass} do
      Application.put_env(:tau, Tau.Providers.Custom,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "custom-test-key",
        headers: [{"x-custom-header", "custom-value"}]
      )

      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        custom_hdr = Plug.Conn.get_req_header(conn, "x-custom-header")
        send(parent, {:custom_header, custom_hdr})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
      Enum.to_list(stream)

      assert_received {:custom_header, ["custom-value"]}
    end
  end

  describe "opts[:model] overrides configured default" do
    test "request body model field reflects opts[:model]", %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(parent, {:request_model, decoded["model"]})

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{model: "llama3-override"}, %{})
      Enum.to_list(stream)

      assert_received {:request_model, "llama3-override"}
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
            "error" => %{"type" => "authentication_error", "message" => "Invalid API key"}
          })
        )
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
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
            "error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}
          })
        )
      end)

      assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
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

        assert {:ok, stream} = Custom.stream([User.new("hello")], %{}, %{})
        events = Enum.to_list(stream)

        assert Enum.any?(events, &match?(%Event.Error{}, &1)),
               "Expected Event.Error for #{status}; got: #{inspect(events)}"
      end
    end
  end
end

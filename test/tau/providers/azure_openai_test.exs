defmodule Tau.Providers.AzureOpenAITest do
  @moduledoc """
  Enforces C80 (SPEC-USER-TURN §3): Azure OpenAI MUST use `api-key` header
  (not `Authorization: Bearer`) and the deployment-based URL with `api-version`.

  Missing api_key/endpoint/deployment → synchronous tagged error; no network call.
  HTTP 401/429 → in-stream `%Tau.Provider.Event.Error{}`; stream/3 does not raise.

  Uses Bypass to stub the Azure endpoint; no real network call is made.
  """
  use ExUnit.Case, async: false

  alias Tau.Message.User
  alias Tau.Provider.Event
  alias Tau.Providers.AzureOpenAI

  @deployment "my-gpt4o"
  @api_version "2024-12-01-preview"

  @sse_text_chunk Jason.encode!(%{
                    "id" => "chatcmpl-az1",
                    "model" => "gpt-4o",
                    "choices" => [
                      %{
                        "delta" => %{"role" => "assistant", "content" => "Hello"},
                        "finish_reason" => nil,
                        "index" => 0
                      }
                    ]
                  })

  @sse_done_chunk Jason.encode!(%{
                    "id" => "chatcmpl-az1",
                    "model" => "gpt-4o",
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

    Application.put_env(:tau, Tau.Providers.AzureOpenAI,
      api_key: "az-test-key",
      endpoint: base_url,
      deployment: @deployment,
      api_version: @api_version
    )

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.AzureOpenAI)
    end)

    %{bypass: bypass, base_url: base_url}
  end

  describe "missing config → synchronous error, no network call" do
    test "missing api_key → {:error, :missing_api_key}" do
      Application.put_env(:tau, Tau.Providers.AzureOpenAI,
        api_key: nil,
        endpoint: "http://localhost:9999",
        deployment: "dep"
      )

      assert {:error, :missing_api_key} = AzureOpenAI.stream([User.new("hi")], %{}, %{})
    end

    test "missing endpoint → {:error, :missing_endpoint}" do
      Application.put_env(:tau, Tau.Providers.AzureOpenAI,
        api_key: "key",
        endpoint: nil,
        deployment: "dep"
      )

      assert {:error, :missing_endpoint} = AzureOpenAI.stream([User.new("hi")], %{}, %{})
    end

    test "missing deployment → {:error, :missing_deployment}" do
      Application.put_env(:tau, Tau.Providers.AzureOpenAI,
        api_key: "key",
        endpoint: "http://localhost:9999",
        deployment: nil
      )

      assert {:error, :missing_deployment} = AzureOpenAI.stream([User.new("hi")], %{}, %{})
    end
  end

  describe "C80: request shape — api-key header and deployment URL" do
    test "request carries api-key header (not Authorization) and hits deployment path with api-version",
         %{bypass: bypass} do
      parent = self()

      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/#{@deployment}/chat/completions",
        fn conn ->
          # C80: verify api-key header is present
          api_key_header = Plug.Conn.get_req_header(conn, "api-key")
          authorization_header = Plug.Conn.get_req_header(conn, "authorization")

          send(parent, {:headers, %{api_key: api_key_header, authorization: authorization_header}})
          send(parent, {:query, conn.query_string})

          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
        end
      )

      assert {:ok, stream} = AzureOpenAI.stream([User.new("hello")], %{}, %{})
      Enum.to_list(stream)

      assert_received {:headers, %{api_key: ["az-test-key"], authorization: []}}
      assert_received {:query, query}
      assert query =~ "api-version=#{@api_version}"
    end
  end

  describe "happy-path stream" do
    test "text delta emits Event.Start, TextStart, TextDelta, Done", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/#{@deployment}/chat/completions",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_resp(200, sse_body([@sse_text_chunk, @sse_done_chunk]))
        end
      )

      assert {:ok, stream} = AzureOpenAI.stream([User.new("hello")], %{}, %{})
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

  describe "HTTP error responses yield in-stream Event.Error, no raise" do
    test "HTTP 401 → %Event.Error{reason: {:http_status, 401, _}, retryable?: false}",
         %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/#{@deployment}/chat/completions",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            401,
            Jason.encode!(%{"error" => %{"code" => "Unauthorized", "message" => "Invalid API key"}})
          )
        end
      )

      assert {:ok, stream} = AzureOpenAI.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.Error{reason: {:http_status, 401, _}, retryable?: false} -> true
               _ -> false
             end),
             "Expected non-retryable Event.Error for 401; got: #{inspect(events)}"
    end

    test "HTTP 429 → %Event.Error{reason: {:http_status, 429, _}, retryable?: true}",
         %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/openai/deployments/#{@deployment}/chat/completions",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.send_resp(
            429,
            Jason.encode!(%{
              "error" => %{"code" => "TooManyRequests", "message" => "Rate limit exceeded"}
            })
          )
        end
      )

      assert {:ok, stream} = AzureOpenAI.stream([User.new("hello")], %{}, %{})
      events = Enum.to_list(stream)

      assert Enum.any?(events, fn
               %Event.Error{reason: {:http_status, 429, _}, retryable?: true} -> true
               _ -> false
             end),
             "Expected retryable Event.Error for 429; got: #{inspect(events)}"
    end

    test "stream does not raise on 401 or 429", %{bypass: bypass} do
      for status <- [401, 429] do
        Bypass.expect_once(
          bypass,
          "POST",
          "/openai/deployments/#{@deployment}/chat/completions",
          fn conn ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.send_resp(
              status,
              Jason.encode!(%{"error" => %{"code" => "error", "message" => "error"}})
            )
          end
        )

        assert {:ok, stream} = AzureOpenAI.stream([User.new("hello")], %{}, %{})
        events = Enum.to_list(stream)

        assert Enum.any?(events, &match?(%Event.Error{}, &1)),
               "Expected Event.Error for #{status}; got: #{inspect(events)}"
      end
    end
  end
end

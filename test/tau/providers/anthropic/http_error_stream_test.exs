defmodule Tau.Providers.Anthropic.HttpErrorStreamTest do
  @moduledoc """
  Enforces the OTP non-negotiable: non-2xx HTTP responses from the
  Anthropic API MUST yield `%Tau.Provider.Event.Error{}` stream items —
  never raise. Specifically covers B5 (SPEC-USER-TURN §4): the session
  FSM only sees `Event` structs; providers do not raise on network/HTTP
  errors.

  Uses Bypass to stub the Anthropic endpoint so no real network call
  is made.
  """
  use ExUnit.Case, async: false

  alias Tau.Message.User
  alias Tau.Provider.Event
  alias Tau.Providers.Anthropic

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    Application.put_env(:tau, Tau.Providers.Anthropic, base_url: base_url)

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.Anthropic)
    end)

    %{bypass: bypass}
  end

  test "HTTP 429 response yields %Event.Error{reason: {:http_status, 429, _}} in stream",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(
        429,
        Jason.encode!(%{
          "error" => %{
            "type" => "rate_limit_error",
            "message" => "Rate limit exceeded. Please retry after 60 seconds."
          }
        })
      )
    end)

    assert {:ok, stream} =
             Anthropic.stream(
               [User.new("hello")],
               %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
               %{}
             )

    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %Event.Error{reason: {:http_status, 429, _}} -> true
             _ -> false
           end),
           "Expected at least one %Event.Error{reason: {:http_status, 429, _}} in stream; got: #{inspect(events)}"
  end

  test "HTTP 429 Event.Error has retryable?: true", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(
        429,
        Jason.encode!(%{
          "error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}
        })
      )
    end)

    assert {:ok, stream} =
             Anthropic.stream(
               [User.new("hello")],
               %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
               %{}
             )

    events = Enum.to_list(stream)

    error_event =
      Enum.find(events, fn
        %Event.Error{reason: {:http_status, 429, _}} -> true
        _ -> false
      end)

    assert %Event.Error{reason: {:http_status, 429, _}, retryable?: true} = error_event,
           "Expected retryable?: true for 429; got: #{inspect(error_event)}"
  end

  test "HTTP 500 response yields retryable %Event.Error{reason: {:http_status, 500, _}}",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(
        500,
        Jason.encode!(%{
          "error" => %{"type" => "api_error", "message" => "Internal server error"}
        })
      )
    end)

    assert {:ok, stream} =
             Anthropic.stream(
               [User.new("hello")],
               %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
               %{}
             )

    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %Event.Error{reason: {:http_status, 500, _}, retryable?: true} -> true
             _ -> false
           end),
           "Expected retryable %Event.Error for 500; got: #{inspect(events)}"
  end

  test "HTTP 401 response yields non-retryable %Event.Error{reason: {:http_status, 401, _}}",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(
        401,
        Jason.encode!(%{
          "error" => %{"type" => "authentication_error", "message" => "Invalid API key"}
        })
      )
    end)

    assert {:ok, stream} =
             Anthropic.stream(
               [User.new("hello")],
               %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
               %{}
             )

    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %Event.Error{reason: {:http_status, 401, _}, retryable?: false} -> true
             _ -> false
           end),
           "Expected non-retryable %Event.Error for 401; got: #{inspect(events)}"
  end

  test "stream does not raise on any non-2xx HTTP response", %{bypass: bypass} do
    for status <- [400, 401, 403, 429, 500, 502, 503] do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          status,
          Jason.encode!(%{"error" => %{"type" => "error", "message" => "error"}})
        )
      end)

      assert {:ok, stream} =
               Anthropic.stream(
                 [User.new("hello")],
                 %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
                 %{}
               )

      # Must not raise; must yield at least one Error event.
      events = Enum.to_list(stream)

      assert Enum.any?(events, &match?(%Event.Error{}, &1)),
             "Expected %Event.Error{} for status #{status}; got: #{inspect(events)}"
    end
  end
end

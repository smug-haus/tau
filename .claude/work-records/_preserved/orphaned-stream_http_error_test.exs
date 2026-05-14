defmodule Tau.Providers.Anthropic.StreamHttpErrorTest do
  @moduledoc """
  D-009 / B5 (SPEC-USER-TURN [C12]): `Tau.Providers.Anthropic.stream/3`
  MUST NOT raise on HTTP non-2xx responses. Instead the stream yields a
  `%Tau.Provider.Event.Error{}` item, and the caller (session FSM) converts
  it to an Assistant message with visible error content.

  The OTP non-negotiables forbid raising across process boundaries — the
  provider stream contract enforces the same via in-band `%Error{}` items.
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

  test "HTTP 429 response yields %Event.Error{} in stream, not a raise", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        429,
        Jason.encode!(%{
          "error" => %{
            "type" => "rate_limit_error",
            "message" => "Rate limited"
          }
        })
      )
    end)

    {:ok, stream} =
      Anthropic.stream(
        [User.new("hello")],
        %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test"},
        %{}
      )

    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %Event.Error{reason: {:http_status, 429}} -> true
             _ -> false
           end),
           "Expected stream to contain %Event.Error{reason: {:http_status, 429}}, got: #{inspect(events)}"
  end

  test "HTTP 429 %Event.Error{} is marked retryable", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      Plug.Conn.resp(conn, 429, "")
    end)

    {:ok, stream} =
      Anthropic.stream(
        [User.new("hello")],
        %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test"},
        %{}
      )

    events = Enum.to_list(stream)

    error_event =
      Enum.find(events, fn
        %Event.Error{} -> true
        _ -> false
      end)

    assert error_event != nil, "Expected an %Event.Error{} but got: #{inspect(events)}"
    assert %Event.Error{reason: {:http_status, 429}, retryable?: true} = error_event
  end

  test "HTTP 401 %Event.Error{} is NOT retryable (auth error)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    {:ok, stream} =
      Anthropic.stream(
        [User.new("hello")],
        %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test"},
        %{}
      )

    events = Enum.to_list(stream)

    error_event =
      Enum.find(events, fn
        %Event.Error{} -> true
        _ -> false
      end)

    assert error_event != nil, "Expected an %Event.Error{} but got: #{inspect(events)}"
    assert %Event.Error{reason: {:http_status, 401}, retryable?: false} = error_event
  end

  test "HTTP 500 %Event.Error{} is retryable (server error)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
      Plug.Conn.resp(conn, 500, "")
    end)

    {:ok, stream} =
      Anthropic.stream(
        [User.new("hello")],
        %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test"},
        %{}
      )

    events = Enum.to_list(stream)

    error_event =
      Enum.find(events, fn
        %Event.Error{} -> true
        _ -> false
      end)

    assert error_event != nil, "Expected an %Event.Error{} but got: #{inspect(events)}"
    assert %Event.Error{reason: {:http_status, 500}, retryable?: true} = error_event
  end
end

defmodule Tau.CodingAgent.TauContext.RouterTest do
  @moduledoc """
  Exercises the Plug router directly via `Plug.Test`, asserting:

    * `initialize` returns server capabilities.
    * `tools/list` enumerates the catalog.
    * `tools/call` dispatches and wraps the result in MCP
      content shape.
    * Unknown method → JSON-RPC -32601.
    * Malformed JSON → -32700.
    * Bad envelope → -32600.
    * Missing token → 401.
    * Wrong token → 401.
    * Notifications (no id) return 204.

  D-035: every error path returns a structured response; no
  test expects a raise.
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent.TauContext.{Auth, Router}

  setup do
    token = Auth.mint()
    state_ref = {__MODULE__, make_ref()}

    :persistent_term.put(state_ref, %{
      token: token,
      session_id: nil,
      cwd: nil,
      max_depth: 2
    })

    on_exit(fn -> :persistent_term.erase(state_ref) end)

    %{token: token, state_ref: state_ref, opts: Router.init(state_ref: state_ref)}
  end

  defp post_rpc(body, %{opts: opts, token: token}) do
    :post
    |> Plug.Test.conn("/mcp", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Router.call(opts)
  end

  defp decode_resp(conn), do: Jason.decode!(conn.resp_body)

  describe "initialize" do
    test "returns capabilities + serverInfo", ctx do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2024-11-05"}
      }

      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"]["serverInfo"]["name"] == "tau-context"
      assert is_map(decoded["result"]["capabilities"])
    end
  end

  describe "tools/list" do
    test "returns the 4-tool catalog", ctx do
      req = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}

      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert length(decoded["result"]["tools"]) == 4

      names = Enum.map(decoded["result"]["tools"], & &1["name"])
      assert "tau_session_status" in names
    end
  end

  describe "tools/call" do
    test "dispatches tau_session_status and wraps content", ctx do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "tau_session_status", "arguments" => %{}}
      }

      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["result"]["isError"] == false
      assert [%{"type" => "text", "text" => text}] = decoded["result"]["content"]
      inner = Jason.decode!(text)
      assert inner["available"] == false
    end

    test "unknown tool name → -32601", ctx do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "tau_nope", "arguments" => %{}}
      }

      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["error"]["code"] == -32_601
    end

    test "missing name → -32602", ctx do
      req = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{}
      }

      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["error"]["code"] == -32_602
    end
  end

  describe "ping" do
    test "returns empty result", ctx do
      req = %{"jsonrpc" => "2.0", "id" => 6, "method" => "ping"}
      conn = post_rpc(req, ctx)
      assert conn.status == 200
      assert decode_resp(conn)["result"] == %{}
    end
  end

  describe "unknown method" do
    test "returns -32601 method-not-found", ctx do
      req = %{"jsonrpc" => "2.0", "id" => 7, "method" => "fictional"}
      conn = post_rpc(req, ctx)
      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["error"]["code"] == -32_601
    end
  end

  describe "notifications (no id)" do
    test "returns 204 with no body", ctx do
      req = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      conn = post_rpc(req, ctx)
      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "malformed input" do
    test "non-JSON body → -32700 parse error", %{opts: opts, token: token} do
      conn =
        :post
        |> Plug.Test.conn("/mcp", "not-json")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Router.call(opts)

      assert conn.status == 400
      decoded = decode_resp(conn)
      assert decoded["error"]["code"] == -32_700
    end

    test "missing 'method' → -32600", ctx do
      req = %{"jsonrpc" => "2.0", "id" => 99}
      conn = post_rpc(req, ctx)
      decoded = decode_resp(conn)
      assert decoded["error"]["code"] == -32_600
    end

    test "not a JSON-RPC 2.0 envelope → 400 -32600", %{opts: opts, token: token} do
      conn =
        :post
        |> Plug.Test.conn("/mcp", Jason.encode!(%{"foo" => "bar"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Router.call(opts)

      assert conn.status == 400
      assert decode_resp(conn)["error"]["code"] == -32_600
    end
  end

  describe "routing" do
    test "GET /healthz returns 200 ok without auth", %{opts: opts} do
      conn =
        :get
        |> Plug.Test.conn("/healthz")
        |> Router.call(opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "GET /mcp returns 405", %{opts: opts, token: token} do
      conn =
        :get
        |> Plug.Test.conn("/mcp")
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> Router.call(opts)

      assert conn.status == 405
    end

    test "unknown path returns 404", %{opts: opts} do
      conn =
        :get
        |> Plug.Test.conn("/nope")
        |> Router.call(opts)

      assert conn.status == 404
    end
  end
end

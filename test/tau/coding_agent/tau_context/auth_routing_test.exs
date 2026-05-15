defmodule Tau.CodingAgent.TauContext.AuthRoutingTest do
  @moduledoc """
  Auth gate over the full router. Asserts:

    * Missing token → 401.
    * Wrong token → 401.
    * Correct token via header → 200.
    * Correct token via ?token= query → 200.
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

    %{token: token, opts: Router.init(state_ref: state_ref)}
  end

  defp post_body do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
  end

  test "missing token → 401", %{opts: opts} do
    conn =
      :post
      |> Plug.Test.conn("/mcp", post_body())
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_001
  end

  test "wrong token → 401", %{opts: opts} do
    conn =
      :post
      |> Plug.Test.conn("/mcp", post_body())
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer wrong-secret")
      |> Router.call(opts)

    assert conn.status == 401
  end

  test "correct token via header → 200", %{opts: opts, token: tok} do
    conn =
      :post
      |> Plug.Test.conn("/mcp", post_body())
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
      |> Router.call(opts)

    assert conn.status == 200
  end

  test "correct token via query parameter → 200", %{opts: opts, token: tok} do
    conn =
      :post
      |> Plug.Test.conn("/mcp?token=#{tok}", post_body())
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Router.call(opts)

    assert conn.status == 200
  end
end

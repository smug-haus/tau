defmodule Tau.CodingAgent.TauContext.AuthTest do
  use ExUnit.Case, async: true

  alias Tau.CodingAgent.TauContext.Auth

  describe "mint/0" do
    test "produces a high-entropy URL-safe token" do
      tok = Auth.mint()
      assert is_binary(tok)
      assert byte_size(tok) >= 40
      # URL-safe alphabet only — no '+' / '/' / '='.
      assert Regex.match?(~r/^[A-Za-z0-9_\-]+$/, tok)
    end

    test "subsequent mints differ" do
      assert Auth.mint() != Auth.mint()
    end
  end

  describe "verify/2" do
    test "true for an exact match" do
      tok = Auth.mint()
      assert Auth.verify(tok, tok)
    end

    test "false for a mismatch" do
      a = Auth.mint()
      b = Auth.mint()
      refute Auth.verify(a, b)
    end

    test "false for nil" do
      refute Auth.verify(nil, "anything")
    end

    test "false for non-binary" do
      refute Auth.verify(:atom, "expected")
      refute Auth.verify(123, "expected")
    end

    test "false on length mismatch (constant-time still rejects)" do
      refute Auth.verify("short", "much-longer-token")
    end
  end

  describe "extract_token/1" do
    test "reads Authorization: Bearer <tok>" do
      conn =
        :get
        |> Plug.Test.conn("/mcp")
        |> Plug.Conn.put_req_header("authorization", "Bearer abc123")

      assert Auth.extract_token(conn) == "abc123"
    end

    test "lowercase 'bearer' is also accepted" do
      conn =
        :get
        |> Plug.Test.conn("/mcp")
        |> Plug.Conn.put_req_header("authorization", "bearer abc123")

      assert Auth.extract_token(conn) == "abc123"
    end

    test "falls back to ?token= query parameter" do
      conn = Plug.Test.conn(:get, "/mcp?token=qtok123")
      assert Auth.extract_token(conn) == "qtok123"
    end

    test "returns nil when neither is present" do
      conn = Plug.Test.conn(:get, "/mcp")
      assert Auth.extract_token(conn) == nil
    end

    test "header takes precedence over query" do
      conn =
        :get
        |> Plug.Test.conn("/mcp?token=fromquery")
        |> Plug.Conn.put_req_header("authorization", "Bearer fromheader")

      assert Auth.extract_token(conn) == "fromheader"
    end

    test "empty token query parameter returns nil" do
      conn = Plug.Test.conn(:get, "/mcp?token=")
      assert Auth.extract_token(conn) == nil
    end

    test "non-bearer Authorization is ignored" do
      conn =
        :get
        |> Plug.Test.conn("/mcp")
        |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")

      assert Auth.extract_token(conn) == nil
    end
  end
end

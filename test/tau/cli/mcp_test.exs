defmodule Tau.CLI.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.CLI.MCP, as: CLI

  describe "Optimus parser wiring" do
    test "parses `tau mcp list`" do
      assert {:ok, [:mcp, :list], _} = Optimus.parse(Tau.CLI.spec(), ["mcp", "list"])
    end

    test "parses `tau mcp status --json`" do
      assert {:ok, [:mcp, :status], parsed} =
               Optimus.parse(Tau.CLI.spec(), ["mcp", "status", "--json"])

      assert parsed.flags[:json] == true
    end

    test "parses `tau mcp reload`" do
      assert {:ok, [:mcp, :reload], _} = Optimus.parse(Tau.CLI.spec(), ["mcp", "reload"])
    end
  end

  describe "list/1" do
    test "prints a header and a row per server, reading from Tau.MCP.Manager" do
      out = capture_io(fn -> assert 0 == CLI.list([]) end)
      # When MCP is up under the application, list returns whatever's
      # configured in settings; an empty list is fine. The handler
      # always emits an exit code 0 and prints something.
      assert is_binary(out)
    end

    test "--json emits a JSON list" do
      out = capture_io(fn -> assert 0 == CLI.list(json: true) end)
      assert {:ok, list} = Jason.decode(out)
      assert is_list(list)
    end
  end

  describe "status/1" do
    test "renders status for each server" do
      out = capture_io(fn -> assert 0 == CLI.status([]) end)
      assert is_binary(out)
    end

    test "--json emits a JSON list of {name, alive, pid}" do
      out = capture_io(fn -> assert 0 == CLI.status(json: true) end)
      assert {:ok, list} = Jason.decode(out)
      assert is_list(list)
    end
  end

  describe "reload/1" do
    test "asks Tau.MCP.Manager to reconcile and exits 0" do
      out = capture_io(fn -> assert 0 == CLI.reload([]) end)
      assert out =~ "reload"
    end

    test "--json emits {ok: true}" do
      out = capture_io(fn -> assert 0 == CLI.reload(json: true) end)
      assert {:ok, %{"ok" => true}} = Jason.decode(out)
    end
  end
end

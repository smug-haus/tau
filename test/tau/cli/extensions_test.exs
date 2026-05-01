defmodule Tau.CLI.ExtensionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.CLI.Extensions, as: CLI

  describe "Optimus parser wiring" do
    test "parses `tau extensions list`" do
      assert {:ok, {[:extensions, :list], _}} =
               Optimus.parse(Tau.CLI.spec(), ["extensions", "list"])
    end

    test "parses `tau extensions reload --json`" do
      assert {:ok, {[:extensions, :reload], parsed}} =
               Optimus.parse(Tau.CLI.spec(), ["extensions", "reload", "--json"])

      assert parsed.flags[:json] == true
    end
  end

  describe "list/1" do
    test "exits 0 and prints something" do
      out = capture_io(fn -> assert 0 == CLI.list([]) end)
      assert is_binary(out)
    end

    test "--json emits a JSON list" do
      out = capture_io(fn -> assert 0 == CLI.list(json: true) end)
      assert {:ok, list} = Jason.decode(out)
      assert is_list(list)
    end
  end

  describe "reload/1" do
    test "asks Tau.Extensions.Loader to reload all and exits 0" do
      out = capture_io(fn -> assert 0 == CLI.reload([]) end)
      assert out =~ "reload"
    end

    test "--json emits {ok: true}" do
      out = capture_io(fn -> assert 0 == CLI.reload(json: true) end)
      assert {:ok, %{"ok" => true}} = Jason.decode(out)
    end
  end
end

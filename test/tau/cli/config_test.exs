defmodule Tau.CLI.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tau.CLI.Config

  setup do
    cwd = Path.join(System.tmp_dir!(), "tau-cli-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(cwd, ".tau"))
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  describe "show/1" do
    test "renders the cascade with sources and merged map", %{cwd: cwd} do
      File.write!(
        Path.join(cwd, ".tau/settings.json"),
        Jason.encode!(%{model: "sonnet"})
      )

      out = capture_io(fn -> assert 0 == Config.show(cwd: cwd) end)
      assert out =~ "settings cascade"
      assert out =~ ".tau/settings.json"
      assert out =~ "sonnet"
    end

    test "--json mode emits a parseable payload", %{cwd: cwd} do
      File.write!(
        Path.join(cwd, ".tau/settings.json"),
        Jason.encode!(%{theme: "dark"})
      )

      out = capture_io(fn -> assert 0 == Config.show(cwd: cwd, json: true) end)
      assert {:ok, %{"settings" => %{"theme" => "dark"}, "sources" => [_ | _]}} = Jason.decode(out)
    end
  end

  describe "get/2" do
    test "reads a top-level key", %{cwd: cwd} do
      File.write!(
        Path.join(cwd, ".tau/settings.json"),
        Jason.encode!(%{model: "haiku"})
      )

      out = capture_io(fn -> assert 0 == Config.get("model", cwd: cwd) end)
      assert out =~ "haiku"
    end

    test "exits 1 when key is unset", %{cwd: cwd} do
      err =
        capture_io(:stderr, fn ->
          assert 1 == Config.get("model", cwd: cwd)
        end)

      assert err =~ "not set"
    end
  end

  describe "set/3" do
    test "writes a string value to .tau/settings.local.json", %{cwd: cwd} do
      capture_io(fn -> assert 0 == Config.set("model", "opus", cwd: cwd) end)

      contents = File.read!(Path.join(cwd, ".tau/settings.local.json")) |> Jason.decode!()
      assert contents == %{"model" => "opus"}
    end

    test "decodes JSON values (lists, maps)", %{cwd: cwd} do
      capture_io(fn ->
        assert 0 == Config.set("extensions", ~s(["a","b"]), cwd: cwd)
      end)

      contents = File.read!(Path.join(cwd, ".tau/settings.local.json")) |> Jason.decode!()
      assert contents == %{"extensions" => ["a", "b"]}
    end

    test "rejects unknown top-level keys", %{cwd: cwd} do
      err =
        capture_io(:stderr, fn ->
          assert 1 == Config.set("not_a_real_key", "x", cwd: cwd)
        end)

      assert err =~ "not a known top-level"
      refute File.exists?(Path.join(cwd, ".tau/settings.local.json"))
    end

    test "rejects values that fail schema validation", %{cwd: cwd} do
      err =
        capture_io(:stderr, fn ->
          # theme is enum-restricted to light/dark/auto
          assert 1 == Config.set("theme", "neon", cwd: cwd)
        end)

      assert err =~ "schema validation failed"
      refute File.exists?(Path.join(cwd, ".tau/settings.local.json"))
    end
  end

  describe "Optimus parser wiring" do
    test "parses `tau config get model` to the get subcommand" do
      assert {:ok, [:config, :get], parsed} =
               Optimus.parse(Tau.CLI.spec(), ["config", "get", "model"])

      assert parsed.args.key == "model"
    end

    test "parses `tau config set theme dark`" do
      assert {:ok, [:config, :set], parsed} =
               Optimus.parse(Tau.CLI.spec(), ["config", "set", "theme", "dark"])

      assert parsed.args.key == "theme"
      assert parsed.args.value == "dark"
    end

    test "parses `--json` flag on bare `config`" do
      assert {:ok, [:config], parsed} =
               Optimus.parse(Tau.CLI.spec(), ["config", "--json"])

      assert parsed.flags[:json] == true
    end
  end
end

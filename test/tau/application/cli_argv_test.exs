defmodule Tau.Application.CliArgvTest do
  @moduledoc """
  Unit tests for `Tau.Application.cli_argv/0` and `Tau.Application.encode_cli_argv/1`.

  Covers all three dispatch sources and the env-marker scrub invariant (D-040 / [C53-B2]).
  """
  use ExUnit.Case, async: false

  @env_key "TAU_CLI_ARGV"

  setup do
    on_exit(fn -> System.delete_env(@env_key) end)
  end

  test "single token dispatch" do
    System.put_env(@env_key, "tui")
    on_exit(fn -> System.delete_env(@env_key) end)
    assert Tau.Application.cli_argv() == {:dispatch, ["tui"]}
  end

  test "multi-token dispatch with US-separated args" do
    System.put_env(@env_key, "tui\x1f--provider\x1freplay")
    on_exit(fn -> System.delete_env(@env_key) end)
    assert Tau.Application.cli_argv() == {:dispatch, ["tui", "--provider", "replay"]}
  end

  test "space-containing token preserved" do
    System.put_env(@env_key, "run\x1fsay hello")
    on_exit(fn -> System.delete_env(@env_key) end)
    assert Tau.Application.cli_argv() == {:dispatch, ["run", "say hello"]}
  end

  test "absent env var yields :no_cli" do
    System.delete_env(@env_key)
    assert Tau.Application.cli_argv() == :no_cli
  end

  test "empty env var yields :no_cli" do
    System.put_env(@env_key, "")
    on_exit(fn -> System.delete_env(@env_key) end)
    assert Tau.Application.cli_argv() == :no_cli
  end

  test "round-trip: encode_cli_argv then cli_argv" do
    encoded = Tau.Application.encode_cli_argv(["tui", "--provider", "replay"])
    System.put_env(@env_key, encoded)
    on_exit(fn -> System.delete_env(@env_key) end)
    assert Tau.Application.cli_argv() == {:dispatch, ["tui", "--provider", "replay"]}
  end

  test "env marker is deleted after a :dispatch resolution (D-040 scrub)" do
    System.put_env(@env_key, "tui")
    on_exit(fn -> System.delete_env(@env_key) end)
    assert {:dispatch, _} = Tau.Application.cli_argv()
    assert System.get_env(@env_key) == nil
  end
end

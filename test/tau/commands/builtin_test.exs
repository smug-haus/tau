defmodule Tau.Commands.BuiltinTest do
  @moduledoc """
  Tests for the built-in slash-command registry and the Ping seed entry.

  Covers:
  - `Tau.Commands.Builtin.table/0` shape and content
  - `Tau.Commands.Builtin.Ping` implements the behaviour correctly
  - `Tau.Commands.Parser.lookup_builtin/1` resolves /ping and returns :error for unknowns
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin
  alias Tau.Commands.Builtin.Ping
  alias Tau.Commands.Parser

  describe "Builtin.table/0" do
    test "returns a map" do
      assert is_map(Builtin.table())
    end

    test "contains /ping => Tau.Commands.Builtin.Ping" do
      assert Builtin.table()["/ping"] == Tau.Commands.Builtin.Ping
    end

    test "all values are modules (atoms)" do
      Builtin.table()
      |> Map.values()
      |> Enum.each(fn mod -> assert is_atom(mod) end)
    end

    test "all keys start with /" do
      Builtin.table()
      |> Map.keys()
      |> Enum.each(fn k ->
        assert String.starts_with?(k, "/"), "key #{inspect(k)} does not start with /"
      end)
    end
  end

  describe "Tau.Commands.Builtin.Ping" do
    test "name/0 returns \"/ping\"" do
      assert Ping.name() == "/ping"
    end

    test "run/2 returns {:notice, \"pong\"}" do
      assert Ping.run("", %{}) == {:notice, "pong"}
    end

    test "run/2 ignores args" do
      assert Ping.run("whatever args", %{some: :data}) == {:notice, "pong"}
    end

    test "implements the Tau.Commands.Builtin behaviour" do
      assert function_exported?(Ping, :name, 0)
      assert function_exported?(Ping, :run, 2)
    end
  end

  describe "Parser.lookup_builtin/1" do
    test "resolves /ping to Tau.Commands.Builtin.Ping" do
      assert Parser.lookup_builtin("/ping") == {:ok, Tau.Commands.Builtin.Ping}
    end

    test "returns :error for an unknown command" do
      assert Parser.lookup_builtin("/notabuiltin") == :error
    end

    test "returns :error for empty string" do
      assert Parser.lookup_builtin("") == :error
    end

    test "returns :error for a command without leading slash" do
      assert Parser.lookup_builtin("ping") == :error
    end
  end
end

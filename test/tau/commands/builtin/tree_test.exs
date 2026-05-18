defmodule Tau.Commands.Builtin.TreeTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Tree`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Tree

  describe "name/0" do
    test "returns \"/tree\"" do
      assert Tree.name() == "/tree"
    end
  end

  describe "run/2 — root session (no fork ancestry)" do
    test "returns {:notice, lines} for a root session" do
      data = %{id: "root-session-1", metadata: %{}, messages: []}
      assert {:notice, lines} = Tree.run("", data)
      assert is_list(lines)
      assert lines != []
    end

    test "includes the session id in the output" do
      sid = "my-root-session"
      data = %{id: sid, metadata: %{}, messages: []}
      {:notice, lines} = Tree.run("", data)
      assert Enum.any?(lines, &String.contains?(&1, sid))
    end

    test "includes 'root' label for a session with no forked_from" do
      data = %{id: "root-sess", metadata: %{}, messages: []}
      {:notice, lines} = Tree.run("", data)
      assert Enum.any?(lines, &String.contains?(&1, "root"))
    end

    test "args are ignored" do
      data = %{id: "root-sess-2", metadata: %{}, messages: []}
      assert {:notice, _} = Tree.run("anything", data)
    end
  end

  describe "run/2 — metadata with forked_from (no live persistence)" do
    test "returns {:notice, lines} when forked_from is present but parent not in persistence" do
      # Persistence will return an empty stream for an unknown session.
      data = %{
        id: "child-session",
        metadata: %{forked_from: %{session: "parent-session-id", event: "evt-1"}},
        messages: []
      }

      assert {:notice, lines} = Tree.run("", data)
      assert is_list(lines)
      # Should mention both sessions
      assert Enum.any?(lines, &String.contains?(&1, "child-session"))
    end

    test "handles string-keyed forked_from (JSON round-trip form)" do
      data = %{
        id: "child-str-keys",
        metadata: %{forked_from: %{"session" => "parent-str", "event" => "e1"}},
        messages: []
      }

      assert {:notice, lines} = Tree.run("", data)
      assert is_list(lines)
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Tree)
      assert function_exported?(Tree, :name, 0)
      assert function_exported?(Tree, :run, 2)
    end
  end
end

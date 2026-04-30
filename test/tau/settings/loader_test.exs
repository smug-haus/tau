defmodule Tau.Settings.LoaderTest do
  use ExUnit.Case, async: true

  alias Tau.Settings.Loader

  describe "merge/2" do
    test "later overrides earlier scalars" do
      assert Loader.merge(%{model: "a"}, %{model: "b"}) == %{model: "b"}
    end

    test "deep-merges nested maps" do
      a = %{permissions: %{allow: ["X"], deny: []}}
      b = %{permissions: %{deny: ["Y"]}}
      merged = Loader.merge(a, b)
      assert merged[:permissions][:allow] == ["X"]
      assert merged[:permissions][:deny] == ["Y"]
    end

    test "concatenates lists at known list-keys" do
      a = %{hooks: [%{e: 1}], extensions: ["ext-a"]}
      b = %{hooks: [%{e: 2}], extensions: ["ext-b"]}
      merged = Loader.merge(a, b)
      assert merged[:hooks] == [%{e: 1}, %{e: 2}]
      assert merged[:extensions] == ["ext-a", "ext-b"]
    end

    test "deny rules from layered permissions concatenate" do
      a = %{permissions: %{deny: ["Bash(rm *)"]}}
      b = %{permissions: %{deny: ["Bash(sudo *)"]}}
      merged = Loader.merge(a, b)
      assert merged[:permissions][:deny] == ["Bash(rm *)", "Bash(sudo *)"]
    end
  end
end

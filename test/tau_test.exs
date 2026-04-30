defmodule TauTest do
  use ExUnit.Case, async: true

  describe "application boot" do
    test "the supervision tree is up" do
      assert Process.whereis(Tau.Supervisor)
      assert Process.whereis(Tau.Tools.Registry)
      assert Process.whereis(Tau.Sessions.Registry)
      assert Process.whereis(Tau.Sessions.Supervisor)
      assert Process.whereis(Tau.MCP.Supervisor)
      assert Process.whereis(Tau.PubSub)
    end

    test "settings cache publishes empty defaults" do
      assert Tau.Settings.Cache.get() == %{}
    end

    test "permissions rule set publishes empty tuple" do
      assert Tau.Permissions.RuleSet.get() == {}
    end
  end

  describe "public API surface (M0 — stubs)" do
    test "start_session returns :not_implemented" do
      assert Tau.start_session() == {:error, :not_implemented}
    end

    test "list_sessions returns []" do
      assert Tau.list_sessions() == []
    end
  end
end

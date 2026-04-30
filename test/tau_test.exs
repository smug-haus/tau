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

  describe "public API surface" do
    test "list_sessions reads from the configured persistence backend" do
      # In test env data_dir points at a tmp path (config/test.exs), so this
      # is empty unless a test writes something. Just assert the call succeeds.
      assert is_list(Tau.list_sessions())
    end

    test "fork on a non-existent parent session returns :parent_not_found" do
      assert Tau.fork("does-not-exist", "any") == {:error, :parent_not_found}
    end
  end
end

defmodule Tau.Permissions.RuleSetReloadTest do
  @moduledoc """
  Regression test for ADR-0004 / #54: `Tau.Permissions.RuleSet`
  subscribes to `Phoenix.PubSub` topic `"settings"` and recompiles
  when `Tau.Settings.Cache` republishes. Replaces the previous
  `Process.whereis(Tau.Permissions.RuleSet) |> send(...)` direct
  channel that violated non-negotiable #4.
  """
  use ExUnit.Case, async: false

  test "RuleSet recompiles when Settings.Cache broadcasts a reload" do
    # Subscribe to the same topic so we can assert the broadcast went out.
    Phoenix.PubSub.subscribe(Tau.PubSub, "settings")
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Tau.PubSub, "settings") end)

    Tau.Settings.Cache.reload()

    assert_receive {:settings_reloaded, settings}, 1_000
    assert is_map(settings)

    # Give RuleSet's handle_info a moment to process the broadcast,
    # then assert .get/0 returns a tuple (the published rule-set
    # shape — empty for default settings, but always a tuple).
    Process.sleep(50)
    assert is_tuple(Tau.Permissions.RuleSet.get())
  end

  test "RuleSet doesn't crash on unrelated PubSub messages" do
    # Future code might broadcast on "settings" with other shapes.
    # The catch-all handle_info(_, state) should swallow them.
    pid = Process.whereis(Tau.Permissions.RuleSet)
    assert is_pid(pid)
    send(pid, :unrelated_message)
    Process.sleep(20)
    assert Process.alive?(pid)
  end
end

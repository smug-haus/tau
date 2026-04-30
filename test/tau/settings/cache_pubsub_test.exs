defmodule Tau.Settings.CachePubSubTest do
  @moduledoc """
  Verifies that `Tau.Settings.Cache.reload/0` broadcasts
  `{:settings_reloaded, settings}` on `Phoenix.PubSub` topic
  `"settings"`. Per Phase 8, sessions and other observers opt into
  reload reactions through this topic. Issue #7.
  """
  use ExUnit.Case, async: false

  setup do
    Phoenix.PubSub.subscribe(Tau.PubSub, "settings")
    on_exit(fn -> Phoenix.PubSub.unsubscribe(Tau.PubSub, "settings") end)
    :ok
  end

  test "Cache.reload/0 broadcasts {:settings_reloaded, settings} on the \"settings\" topic" do
    Tau.Settings.Cache.reload()

    assert_receive {:settings_reloaded, settings}, 1_000
    assert is_map(settings)
  end
end

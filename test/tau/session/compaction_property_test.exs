defmodule Tau.Session.CompactionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Session.Compaction

  defp make_data(failures \\ 0) do
    %{
      id: "test-session",
      messages: [],
      compaction_failures: failures,
      provider: Tau.Providers.Replay,
      model: "replay"
    }
  end

  property "emit_cache_usage does not crash on any integer inputs" do
    check all(
            read <- integer(0..1_000_000),
            write <- integer(0..1_000_000)
          ) do
      data = make_data()
      usage = %{cache_read: read, cache_write: write}
      assert :ok = Compaction.emit_cache_usage(data, usage)
    end
  end

  property "emit_cache_usage treats nil values as 0" do
    check all(_ <- constant(nil)) do
      data = make_data()
      assert :ok = Compaction.emit_cache_usage(data, %{cache_read: nil, cache_write: nil})
    end
  end

  property "emit_cache_usage handles missing keys gracefully" do
    check all(_ <- constant(nil)) do
      data = make_data()
      assert :ok = Compaction.emit_cache_usage(data, %{})
    end
  end
end

defmodule Tau.Session.ToolDispatchPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Session.ToolDispatch

  defp tool_name_generator do
    string(:alphanumeric, min_length: 1, max_length: 32)
  end

  defp args_generator do
    map_of(string(:alphanumeric, min_length: 1, max_length: 16), integer())
  end

  property "tool_args_hash is deterministic for the same arguments" do
    check all(args <- args_generator()) do
      h1 = ToolDispatch.tool_args_hash(args)
      h2 = ToolDispatch.tool_args_hash(args)
      assert h1 == h2
    end
  end

  property "tool_args_hash is the same regardless of map key insertion order" do
    check all(
            keys <- uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 1),
            vals <- list_of(integer(), length: length(keys))
          ) do
      pairs = Enum.zip(keys, vals)
      args1 = Enum.into(pairs, %{})
      args2 = Enum.into(Enum.reverse(pairs), %{})
      assert ToolDispatch.tool_args_hash(args1) == ToolDispatch.tool_args_hash(args2)
    end
  end

  property "tool_args_hash returns a 64-char hex string" do
    check all(args <- args_generator()) do
      hash = ToolDispatch.tool_args_hash(args)
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert hash =~ ~r/^[0-9a-f]+$/
    end
  end

  property "tool_args_hash handles nil args" do
    check all(_ <- constant(nil)) do
      hash = ToolDispatch.tool_args_hash(nil)
      assert String.length(hash) == 64
    end
  end

  defp tool_call_generator do
    gen all(name <- tool_name_generator()) do
      %{name: name, id: "id_#{name}", arguments: %{}}
    end
  end

  property "split_tools_whitelist with :all returns empty filtered list" do
    check all(calls <- list_of(tool_call_generator())) do
      {filtered, kept} = ToolDispatch.split_tools_whitelist(calls, :all)
      assert filtered == []
      assert kept == calls
    end
  end

  property "split_tools_whitelist with explicit list partitions correctly" do
    check all(
            allowed <- list_of(tool_name_generator(), min_length: 1),
            calls <- list_of(tool_call_generator(), min_length: 0, max_length: 10)
          ) do
      {filtered, kept} = ToolDispatch.split_tools_whitelist(calls, allowed)
      assert Enum.all?(filtered, fn %{name: n} -> n not in allowed end)
      assert Enum.all?(kept, fn %{name: n} -> n in allowed end)
      assert length(filtered) + length(kept) == length(calls)
    end
  end

  property "maybe_apply_tool_loop_brake does not brake on successful result" do
    check all(
            name <- tool_name_generator(),
            hash <- string(:alphanumeric, length: 64)
          ) do
      data = %{
        tool_loop_state: %{{name, hash} => %{count: 10, error: "err"}},
        tool_loop_brake_threshold: 3
      }

      result = %Tau.Message.ToolResult{
        tool_call_id: "id",
        tool_name: name,
        content: "ok",
        is_error: false,
        timestamp: DateTime.utc_now()
      }

      assert {:continue, updated} =
               ToolDispatch.maybe_apply_tool_loop_brake(data, {name, hash}, result)

      assert updated.tool_loop_state == %{}
    end
  end

  property "maybe_apply_tool_loop_brake increments counter for repeated errors" do
    check all(
            name <- tool_name_generator(),
            hash <- string(:alphanumeric, length: 64),
            error_text <- string(:printable, min_length: 1)
          ) do
      key = {name, hash}

      data = %{
        tool_loop_state: %{},
        tool_loop_brake_threshold: 5
      }

      result = %Tau.Message.ToolResult{
        tool_call_id: "id",
        tool_name: name,
        content: error_text,
        is_error: true,
        timestamp: DateTime.utc_now()
      }

      {tag1, data1} = ToolDispatch.maybe_apply_tool_loop_brake(data, {name, hash}, result)
      assert tag1 == :continue
      assert get_in(data1, [:tool_loop_state, key, :count]) == 1

      {tag2, data2} = ToolDispatch.maybe_apply_tool_loop_brake(data1, {name, hash}, result)
      assert tag2 == :continue
      assert get_in(data2, [:tool_loop_state, key, :count]) == 2
    end
  end

  property "whitelist_size returns :all for :all and length for lists" do
    check all(list <- list_of(tool_name_generator())) do
      assert ToolDispatch.whitelist_size(:all) == :all
      assert ToolDispatch.whitelist_size(list) == length(list)
    end
  end
end

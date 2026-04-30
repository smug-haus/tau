defmodule Tau.Permissions.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.{Evaluator, Parser}

  @moduletag :property

  defp tool_name_gen, do: StreamData.member_of(["Read", "Write", "Edit", "Bash", "WebFetch"])

  defp simple_pattern_gen do
    StreamData.bind(tool_name_gen(), fn tool ->
      StreamData.frequency([
        {1, StreamData.constant(tool)},
        {2,
         StreamData.bind(
           StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
           fn s -> StreamData.constant("#{tool}(#{s}*)") end
         )}
      ])
    end)
  end

  defp args_gen do
    StreamData.fixed_map(%{
      "command" => StreamData.string(:printable, max_length: 24),
      "path" => StreamData.string(:printable, max_length: 24),
      "url" => StreamData.member_of(["https://github.com/x", "https://evil.com/y", ""])
    })
  end

  property "deny rules always win regardless of allow rules ordering" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            extra_allows <- StreamData.list_of(simple_pattern_gen(), max_length: 5)
          ) do
      # rule_set with a blanket deny on this tool — every call must :deny
      # no matter what allow rules surround it.
      perms = %{deny: [tool], allow: extra_allows ++ [tool]}
      rs = Parser.compile(perms) |> List.to_tuple()
      assert Evaluator.evaluate(rs, tool, args, %{}) == :deny
    end
  end

  property "evaluator is deterministic for the same input" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            allows <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            denies <- StreamData.list_of(simple_pattern_gen(), max_length: 4)
          ) do
      perms = %{allow: allows, deny: denies}
      rs = Parser.compile(perms) |> List.to_tuple()
      a = Evaluator.evaluate(rs, tool, args, %{})
      b = Evaluator.evaluate(rs, tool, args, %{})
      assert a == b
    end
  end

  property "empty rule set returns :ask in :default mode for all inputs" do
    check all(tool <- tool_name_gen(), args <- args_gen()) do
      assert Evaluator.evaluate({}, tool, args, %{}, :default) == :ask
    end
  end

  property ":bypass mode allows everything except deny rules" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            allows <- StreamData.list_of(simple_pattern_gen(), max_length: 3)
          ) do
      perms = %{allow: allows, deny: []}
      rs = Parser.compile(perms) |> List.to_tuple()
      assert Evaluator.evaluate(rs, tool, args, %{}, :bypass) == :allow
    end
  end
end

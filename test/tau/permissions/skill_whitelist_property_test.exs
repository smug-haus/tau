defmodule Tau.Permissions.SkillWhitelistPropertyTest do
  @moduledoc """
  Property + example coverage for issue #16 / ADR-0013: when an
  `active_skill` is set on the evaluator's `ctx`, its `allowed_tools`
  list acts as a necessary-but-not-sufficient gate over the regular
  rule-based decision.

  The three properties are:

    1. Tool **not** on the whitelist always denies, regardless of the
       underlying rule set (admin-level deny rules already won; this
       gate runs after them and short-circuits everything else).
    2. Tool **on** the whitelist falls through to the underlying rules
       — the result matches what a `nil`-skill evaluation produces for
       the same input.
    3. `nil` skill or `[]`/`nil` whitelist is a no-op: behaviour is
       identical to pre-#16 evaluation.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.{Evaluator, Parser}
  alias Tau.Skill

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
      "command" => StreamData.string(:printable, max_length: 12),
      "path" => StreamData.string(:printable, max_length: 12),
      "url" => StreamData.member_of(["https://github.com/x", "https://evil.com/y", ""])
    })
  end

  defp whitelist_gen do
    # A non-empty subset of the tool universe — properties 1 and 2 only
    # exercise the gate when there's at least one entry. The empty-list
    # case is covered by property 3.
    StreamData.bind(
      StreamData.list_of(tool_name_gen(), min_length: 1, max_length: 5),
      fn xs -> StreamData.constant(Enum.uniq(xs)) end
    )
  end

  defp skill(allowed) do
    %Skill{
      name: "test_skill",
      body: "",
      path: "test",
      allowed_tools: allowed
    }
  end

  property "tool not on whitelist always denies (deny rules already won)" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            allows <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            asks <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            whitelist <- whitelist_gen(),
            mode <- StreamData.member_of([:default, :auto, :accept_edits, :plan, :dont_ask])
          ) do
      # Force "tool not on whitelist".
      whitelist = Enum.reject(whitelist, &(&1 == tool))
      whitelist = if whitelist == [], do: ["__never_match__"], else: whitelist

      # No deny rules — so the only thing that can produce :deny here is
      # the skill gate (or :plan/:dont_ask defaults; both correct).
      perms = %{allow: allows, ask: asks, deny: []}
      rs = Parser.compile(perms) |> List.to_tuple()

      decision =
        Evaluator.evaluate(
          rs,
          tool,
          args,
          %{cwd: "/", active_skill: skill(whitelist)},
          mode
        )

      assert decision == :deny
    end
  end

  property "tool on whitelist falls through to base rules" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            allows <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            denies <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            extra_whitelist <- StreamData.list_of(tool_name_gen(), max_length: 4),
            mode <- StreamData.member_of([:default, :auto, :accept_edits, :bypass])
          ) do
      whitelist = Enum.uniq([tool | extra_whitelist])
      perms = %{allow: allows, deny: denies}
      rs = Parser.compile(perms) |> List.to_tuple()

      with_skill =
        Evaluator.evaluate(
          rs,
          tool,
          args,
          %{cwd: "/", active_skill: skill(whitelist)},
          mode
        )

      without_skill = Evaluator.evaluate(rs, tool, args, %{cwd: "/"}, mode)
      assert with_skill == without_skill
    end
  end

  property "nil skill / empty whitelist is a no-op" do
    check all(
            tool <- tool_name_gen(),
            args <- args_gen(),
            allows <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            denies <- StreamData.list_of(simple_pattern_gen(), max_length: 4),
            mode <- StreamData.member_of([:default, :auto, :plan, :dont_ask, :bypass]),
            skill_choice <- StreamData.member_of([:nil_skill, :empty_list])
          ) do
      perms = %{allow: allows, deny: denies}
      rs = Parser.compile(perms) |> List.to_tuple()

      ctx =
        case skill_choice do
          :nil_skill -> %{cwd: "/", active_skill: nil}
          :empty_list -> %{cwd: "/", active_skill: skill([])}
        end

      with_field = Evaluator.evaluate(rs, tool, args, ctx, mode)
      without_field = Evaluator.evaluate(rs, tool, args, %{cwd: "/"}, mode)

      assert with_field == without_field
    end
  end

  describe "examples" do
    test "skill whitelist denies a tool absent from allowed_tools" do
      rs = Parser.compile(%{allow: ["Bash"]}) |> List.to_tuple()
      ctx = %{cwd: "/", active_skill: skill(["Read"])}
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "ls"}, ctx, :default) == :deny
    end

    test "deny rule still wins over a whitelisted tool" do
      rs = Parser.compile(%{deny: ["Bash(rm *)"]}) |> List.to_tuple()
      ctx = %{cwd: "/", active_skill: skill(["Bash"])}
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "rm -rf /"}, ctx, :bypass) == :deny
    end

    test "tool on whitelist + allow rule → allow" do
      rs = Parser.compile(%{allow: ["Read"]}) |> List.to_tuple()
      ctx = %{cwd: "/", active_skill: skill(["Read", "Write"])}
      assert Evaluator.evaluate(rs, "Read", %{"path" => "x"}, ctx, :default) == :allow
    end

    test "nil active_skill in ctx → behaves like pre-#16" do
      rs = Parser.compile(%{allow: ["Read"]}) |> List.to_tuple()
      ctx = %{cwd: "/", active_skill: nil}
      assert Evaluator.evaluate(rs, "Read", %{"path" => "x"}, ctx, :default) == :allow
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "ls"}, ctx, :default) == :ask
    end

    test "ctx without :active_skill key at all → behaves like pre-#16" do
      rs = Parser.compile(%{allow: ["Read"]}) |> List.to_tuple()
      assert Evaluator.evaluate(rs, "Read", %{"path" => "x"}, %{cwd: "/"}, :default) == :allow
    end
  end
end

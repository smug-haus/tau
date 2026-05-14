defmodule Tau.Permissions.Evaluator do
  @moduledoc """
  Pure evaluation of permission rules.

  Rules are pre-compiled by `Tau.Permissions.RuleSet` into a list of
  `{decision, matcher_module, compiled_rule}` triples. This module just
  walks them in deny → ask → allow order; first match wins.

  Modes:

    * `:default`        — fall through to `:ask` when no rule matches
    * `:accept_edits`   — auto-allow tool calls that don't include
                         destructive shells (Bash commands run through
                         `Tau.Permissions.Heuristics.destructive_bash?/1`);
                         deny rules still apply
    * `:plan`           — read-only: only Read/Grep/etc. allowed
    * `:auto`           — auto-allow non-destructive; ask on writes
    * `:dont_ask`       — only pre-approved tools; default deny otherwise
    * `:bypass`         — allow everything (used for non-interactive runs;
                          deny rules still apply for safety)
  """

  @type decision :: :allow | :deny | :ask

  @doc """
  Evaluate a single tool call.

  `rule_set` is the precompiled tuple of triples from
  `Tau.Permissions.RuleSet.get/0`. `mode` is the current permissions mode.

  ## Skill activation (issue #16)

  When `ctx` carries an `:active_skill` whose `allowed_tools` is a
  non-empty list, the requested `tool_name` must appear on that list
  for the call to proceed. If it does not, the result is `:deny`
  regardless of any `allow`/`ask` rule that would otherwise match;
  admin-level `deny` rules still win first (skill whitelist is
  necessary, not sufficient — see ADR-0013).

  An `:active_skill` of `nil` or one whose `allowed_tools` is `nil`
  or `[]` is a no-op: behaviour is identical to pre-#16 evaluation.
  """
  @spec evaluate(
          rule_set :: tuple(),
          tool_name :: String.t(),
          args :: map(),
          ctx :: map(),
          mode :: atom()
        ) :: decision()
  def evaluate(rule_set, tool_name, args, ctx, mode \\ :default) do
    rules = Tuple.to_list(rule_set)

    cond do
      match_any(rules, :deny, tool_name, args, ctx) ->
        :deny

      skill_blocked?(ctx, tool_name) ->
        :deny

      mode == :bypass ->
        :allow

      match_any(rules, :allow, tool_name, args, ctx) ->
        :allow

      match_any(rules, :ask, tool_name, args, ctx) ->
        :ask

      true ->
        default_for_mode(mode, tool_name, args)
    end
  end

  # Skill whitelist gate. Returns true iff an active skill is set AND its
  # allowed_tools list is non-empty AND the requested tool is NOT on the
  # list. nil skill / empty whitelist / membership all return false (no
  # block).
  defp skill_blocked?(%{active_skill: %Tau.Skill{allowed_tools: list}}, tool_name)
       when is_list(list) and list != [] do
    tool_name not in list
  end

  defp skill_blocked?(_ctx, _tool_name), do: false

  defp match_any(rules, decision, tool_name, args, ctx) do
    Enum.any?(rules, fn {d, mod, rule} ->
      d == decision and mod.match?(rule, tool_name, args, ctx)
    end)
  end

  defp default_for_mode(:default, _, _), do: :ask
  defp default_for_mode(:dont_ask, _, _), do: :deny
  # "Agent" is dispatch infrastructure, not a content tool. Denying it under
  # :plan kills sub-agent delegation entirely, which is too blunt — :plan
  # mode's read-only intent targets content tools (Bash, Write, Edit), not
  # synthetic dispatch primitives. The child session inherits :plan as its
  # ceiling via Tau.Permissions.Mode.clamp/2, so the read-only constraint is
  # still enforced inside the child. (Issue #166, Option 1.)
  defp default_for_mode(:plan, tool, _) when tool in ["Read", "Grep", "Glob", "Agent"],
    do: :allow

  defp default_for_mode(:plan, _, _), do: :deny

  defp default_for_mode(:accept_edits, tool, _) when tool in ["Read", "Write", "Edit", "Grep"],
    do: :allow

  defp default_for_mode(:accept_edits, "Bash", args) do
    if Tau.Permissions.Heuristics.destructive_bash?(args), do: :deny, else: :allow
  end

  defp default_for_mode(:auto, tool, _) when tool in ["Read", "Grep", "Glob"], do: :allow
  defp default_for_mode(:auto, _, _), do: :ask
  defp default_for_mode(_, _, _), do: :ask
end

defmodule Tau.Permissions.Evaluator do
  @moduledoc """
  Pure evaluation of permission rules.

  Rules are pre-compiled by `Tau.Permissions.RuleSet` into a list of
  `{decision, matcher_module, compiled_rule}` triples. This module just
  walks them in deny → ask → allow order; first match wins.

  Modes:

    * `:default`        — fall through to `:ask` when no rule matches
    * `:accept_edits`   — auto-allow tool calls that don't include
                         destructive shells; deny rules still apply
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
      match_any(rules, :deny, tool_name, args, ctx) -> :deny
      mode == :bypass -> :allow
      match_any(rules, :allow, tool_name, args, ctx) -> :allow
      match_any(rules, :ask, tool_name, args, ctx) -> :ask
      true -> default_for_mode(mode, tool_name)
    end
  end

  defp match_any(rules, decision, tool_name, args, ctx) do
    Enum.any?(rules, fn {d, mod, rule} ->
      d == decision and mod.match?(rule, tool_name, args, ctx)
    end)
  end

  defp default_for_mode(:default, _), do: :ask
  defp default_for_mode(:dont_ask, _), do: :deny
  defp default_for_mode(:plan, tool) when tool in ["Read", "Grep", "Glob"], do: :allow
  defp default_for_mode(:plan, _), do: :deny

  defp default_for_mode(:accept_edits, tool) when tool in ["Read", "Write", "Edit", "Grep"],
    do: :allow

  defp default_for_mode(:accept_edits, "Bash"), do: :ask
  defp default_for_mode(:auto, tool) when tool in ["Read", "Grep", "Glob"], do: :allow
  defp default_for_mode(:auto, _), do: :ask
  defp default_for_mode(_, _), do: :ask
end

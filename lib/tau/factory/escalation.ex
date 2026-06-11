defmodule Tau.Factory.Escalation do
  @moduledoc """
  Pure escalation classifier (SPEC-FACTORY-CORE §5, D-317).

  Maps a trigger term to an `{e, scope}` pair. The function is total over
  `term()` — it never raises for any input (D-317 totality invariant).
  Unknown inputs fall through to `{:"E-UNCLASSIFIED", :global}`.
  """

  @type e ::
          :"E-RETRY-EXHAUSTED"
          | :"E-AMBIGUITY"
          | :"E-CHALLENGE"
          | :"E-DESTRUCTIVE"
          | :"E-BUDGET"
          | :"E-RED-MAIN"
          | :"E-CONFLICT"
          | :"E-UNCLASSIFIED"

  @type scope :: :unit | :global

  @doc """
  Classifies a trigger into an `{e, scope}` pair.

  Known trigger shapes:

    {:retry_exhausted, _}  → {:"E-RETRY-EXHAUSTED", :unit}
    {:ambiguity, _}        → {:"E-AMBIGUITY", :unit}
    {:challenge, _}        → {:"E-CHALLENGE", :unit}
    {:destructive, _}      → {:"E-DESTRUCTIVE", :unit}
    {:budget, _}           → {:"E-BUDGET", :global}
    {:red_main, _}         → {:"E-RED-MAIN", :global}
    {:conflict, _}         → {:"E-CONFLICT", :unit}
    _                      → {:"E-UNCLASSIFIED", :global}

  The catch-all clause makes `classify/1` total over `term()` (D-317).
  """
  @spec classify(term()) :: {e(), scope()}
  def classify({:retry_exhausted, _}), do: {:"E-RETRY-EXHAUSTED", :unit}
  def classify({:ambiguity, _}), do: {:"E-AMBIGUITY", :unit}
  def classify({:challenge, _}), do: {:"E-CHALLENGE", :unit}
  def classify({:destructive, _}), do: {:"E-DESTRUCTIVE", :unit}
  def classify({:budget, _}), do: {:"E-BUDGET", :global}
  def classify({:red_main, _}), do: {:"E-RED-MAIN", :global}
  def classify({:conflict, _}), do: {:"E-CONFLICT", :unit}
  def classify(_), do: {:"E-UNCLASSIFIED", :global}
end

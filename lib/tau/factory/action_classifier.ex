defmodule Tau.Factory.ActionClassifier do
  @moduledoc """
  Pure action classifier (C7) — the structural deny boundary for destructive
  factory actions (SPEC-FACTORY-GOV §4 B7, §6 D-319).

  `classify/1` is a pure, total function over a compile-time denylist MapSet.
  Every `kind ∈ @destructive` yields `{:deny, :destructive}`; any other input
  yields `:allow`. The function never raises on any input (C219).

  D-319: the deny is structural — every effecting path (notably M's `cas_push`)
  MUST call `classify/1` *before* executing. A deny routes to K as E-DESTRUCTIVE
  with the action never auto-executing (INV-20 □(destructive(a) → escalate ∧
  ¬auto_execute)).

  The denylist is a compile-time constant (C203-B7); it has no runtime
  configuration surface. A missing entry is a code change, not a config change.

  ## Denylist (SPEC-FACTORY-GOV §4 B7)

  - `:force_push` — `--force-with-lease` push to `origin/main`
  - `:history_rewrite` — any `git rebase -i`, `git commit --amend`, or force
    history mutation
  - `:release` — any publishing action that creates a release artifact
  - `:external_publish` — any action that publishes to an external registry or
    package manager
  - `:data_migration` — any irreversible data migration action
  """

  @destructive MapSet.new([
                 :force_push,
                 :history_rewrite,
                 :release,
                 :external_publish,
                 :data_migration
               ])

  @doc """
  Classify an action kind.

  Returns `{:deny, :destructive}` for any `kind ∈ @destructive`; `:allow` for
  all other inputs. Total — never raises on any input (C219-B7).

  ## Examples

      iex> Tau.Factory.ActionClassifier.classify(:force_push)
      {:deny, :destructive}

      iex> Tau.Factory.ActionClassifier.classify(:merge)
      :allow

      iex> Tau.Factory.ActionClassifier.classify(nil)
      :allow
  """
  @spec classify(atom() | struct() | term()) :: :allow | {:deny, :destructive}
  def classify(kind) when is_atom(kind) do
    if MapSet.member?(@destructive, kind) do
      {:deny, :destructive}
    else
      :allow
    end
  end

  def classify(_other), do: :allow
end

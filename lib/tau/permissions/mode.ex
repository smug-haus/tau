defmodule Tau.Permissions.Mode do
  @moduledoc """
  Pure helpers for the permissions-mode lattice (ADR-0015).

  The harness models its permissions modes as a partial order from
  most-permissive to most-restrictive:

      :bypass  >  :auto  >  :default  >  {:accept_edits, :dont_ask, :plan}

  `:accept_edits`, `:dont_ask`, and `:plan` each restrict different
  operations and are therefore unordered against each other; for the
  ceiling check used by sub-agent spawn (ADR-0014/0015) any of them is
  treated as strictly below `:default`.

  The `Agent` tool computes its child's effective permissions mode via
  `clamp/2`: a child can never request a mode more permissive than its
  parent's. This module is the canonical place to evolve the lattice;
  the evaluator (`Tau.Permissions.Evaluator`) consumes the **resolved**
  mode and is unconcerned with how it was negotiated.
  """

  @typedoc """
  Concrete permissions modes recognised by `Tau.Permissions.Evaluator`.
  """
  @type mode :: :bypass | :auto | :default | :accept_edits | :dont_ask | :plan

  # Lattice rank: lower numbers are MORE permissive. `:accept_edits`,
  # `:dont_ask`, and `:plan` share the same restrictiveness tier — none
  # of them dominates either of the others. Strict ordering against
  # `:default` and above is preserved.
  @ranks %{
    bypass: 0,
    auto: 1,
    default: 2,
    accept_edits: 3,
    dont_ask: 3,
    plan: 3
  }

  @doc """
  Return `true` iff `m` is a recognised mode atom.
  """
  @spec mode?(term()) :: boolean()
  def mode?(m), do: is_map_key(@ranks, m)

  @doc """
  Clamp `requested` against `parent` so the result is no more permissive
  than `parent`. Concretely:

    * if `requested` is at or below `parent` in the lattice, it stands
      (the child may ask for *stricter* than its parent);
    * otherwise `parent` wins (the child cannot escalate).

  Unknown / `nil` `requested` returns `parent` unchanged. An unknown
  `parent` falls back to `:default` — the safer choice when callers
  pass something the evaluator won't recognise.

  ## Examples

      iex> Tau.Permissions.Mode.clamp(:bypass, :plan)
      :plan
      iex> Tau.Permissions.Mode.clamp(:plan, :default)
      :plan
      iex> Tau.Permissions.Mode.clamp(:default, :default)
      :default
      iex> Tau.Permissions.Mode.clamp(nil, :auto)
      :auto
  """
  @spec clamp(term(), term()) :: mode()
  def clamp(requested, parent) do
    parent = normalise_parent(parent)

    cond do
      not mode?(requested) ->
        parent

      requested == parent ->
        parent

      at_or_below?(requested, parent) ->
        requested

      true ->
        parent
    end
  end

  @doc """
  Return `true` iff `child` is at or below `parent` in the lattice (i.e.
  the spawn would not escalate). Same family as `clamp/2`'s decision
  rule, exposed for tests and ceilings-only callers.
  """
  @spec at_or_below?(mode(), mode()) :: boolean()
  def at_or_below?(child, parent) when is_map_key(@ranks, child) and is_map_key(@ranks, parent) do
    Map.fetch!(@ranks, child) >= Map.fetch!(@ranks, parent)
  end

  @doc """
  Lattice rank for a mode (lower = more permissive). Useful for
  property tests asserting the clamp invariant.
  """
  @spec rank(mode()) :: 0..3
  def rank(m) when is_map_key(@ranks, m), do: Map.fetch!(@ranks, m)

  defp normalise_parent(p) when is_map_key(@ranks, p), do: p
  defp normalise_parent(_), do: :default
end

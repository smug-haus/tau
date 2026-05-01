defmodule Tau.Permissions.ModeTest do
  @moduledoc """
  Coverage for `Tau.Permissions.Mode.clamp/2` — the lattice helper that
  the `Agent` tool (ADR-0014, ADR-0015, issue #32) uses to compute a
  child sub-agent's effective permissions mode against its parent.

  The lattice (most permissive → most restrictive) is

      :bypass > :auto > :default > {:accept_edits, :dont_ask, :plan}

  The clamp invariant: a child can request stricter than its parent,
  never broader. `clamp(requested, parent)` is therefore always
  `<= parent` in the lattice (rank-wise), and is `requested` exactly
  when `requested` is at-or-below `parent`.

  Example tests pin every interesting (requested, parent) combination
  on the lattice; the property pins the invariant for arbitrary inputs.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.Mode

  @modes [:bypass, :auto, :default, :accept_edits, :dont_ask, :plan]

  describe "mode?/1" do
    test "recognises every concrete mode atom" do
      for m <- @modes, do: assert(Mode.mode?(m))
    end

    test "rejects non-mode terms" do
      refute Mode.mode?(nil)
      refute Mode.mode?(:nope)
      refute Mode.mode?("default")
      refute Mode.mode?(42)
    end
  end

  describe "rank/1" do
    test "lattice tiers: bypass(0) < auto(1) < default(2) < accept_edits/dont_ask/plan(3)" do
      assert Mode.rank(:bypass) == 0
      assert Mode.rank(:auto) == 1
      assert Mode.rank(:default) == 2
      assert Mode.rank(:accept_edits) == 3
      assert Mode.rank(:dont_ask) == 3
      assert Mode.rank(:plan) == 3
    end
  end

  describe "at_or_below?/2" do
    test "child at-or-below parent in the lattice" do
      assert Mode.at_or_below?(:plan, :default)
      assert Mode.at_or_below?(:default, :auto)
      assert Mode.at_or_below?(:auto, :bypass)
      assert Mode.at_or_below?(:plan, :plan)
      assert Mode.at_or_below?(:dont_ask, :accept_edits)
      assert Mode.at_or_below?(:accept_edits, :dont_ask)
    end

    test "child above parent — escalation — is rejected" do
      refute Mode.at_or_below?(:bypass, :default)
      refute Mode.at_or_below?(:default, :plan)
      refute Mode.at_or_below?(:auto, :default)
    end
  end

  describe "clamp/2 — equal modes" do
    test "every mode clamped against itself returns itself" do
      for m <- @modes do
        assert Mode.clamp(m, m) == m
      end
    end
  end

  describe "clamp/2 — child stricter than parent (no escalation, child wins)" do
    test "plan child under default parent stays plan" do
      assert Mode.clamp(:plan, :default) == :plan
    end

    test "default child under auto parent stays default" do
      assert Mode.clamp(:default, :auto) == :default
    end

    test "auto child under bypass parent stays auto" do
      assert Mode.clamp(:auto, :bypass) == :auto
    end

    test "plan child under bypass parent stays plan" do
      assert Mode.clamp(:plan, :bypass) == :plan
    end

    test "dont_ask child under default parent stays dont_ask" do
      assert Mode.clamp(:dont_ask, :default) == :dont_ask
    end

    test "accept_edits child under auto parent stays accept_edits" do
      assert Mode.clamp(:accept_edits, :auto) == :accept_edits
    end
  end

  describe "clamp/2 — child more permissive than parent (escalation, parent wins)" do
    test "bypass requested under plan parent clamps to plan" do
      assert Mode.clamp(:bypass, :plan) == :plan
    end

    test "auto requested under default parent clamps to default" do
      assert Mode.clamp(:auto, :default) == :default
    end

    test "default requested under plan parent clamps to plan" do
      assert Mode.clamp(:default, :plan) == :plan
    end

    test "bypass requested under default parent clamps to default" do
      assert Mode.clamp(:bypass, :default) == :default
    end

    test "auto requested under dont_ask parent clamps to dont_ask" do
      assert Mode.clamp(:auto, :dont_ask) == :dont_ask
    end
  end

  describe "clamp/2 — peer modes (accept_edits, dont_ask, plan share rank 3)" do
    # Peer modes share rank 3 — `at_or_below?` returns true in either
    # direction, so the requested mode stands. This is the `Agent`
    # tool's contract: a peer child mode is treated as already
    # restricted enough to satisfy the ceiling against another peer
    # parent.
    test "plan under accept_edits stays plan" do
      assert Mode.clamp(:plan, :accept_edits) == :plan
    end

    test "accept_edits under plan stays accept_edits" do
      assert Mode.clamp(:accept_edits, :plan) == :accept_edits
    end

    test "dont_ask under plan stays dont_ask" do
      assert Mode.clamp(:dont_ask, :plan) == :dont_ask
    end
  end

  describe "clamp/2 — degenerate inputs" do
    test "nil requested returns parent verbatim" do
      assert Mode.clamp(nil, :default) == :default
      assert Mode.clamp(nil, :plan) == :plan
      assert Mode.clamp(nil, :bypass) == :bypass
    end

    test "unknown atom requested returns parent" do
      assert Mode.clamp(:nope, :default) == :default
    end

    test "unknown parent normalises to :default" do
      # Per the moduledoc: an unknown `parent` falls back to `:default`.
      assert Mode.clamp(:plan, :nope) == :plan
      assert Mode.clamp(:bypass, :nope) == :default
      assert Mode.clamp(nil, :nope) == :default
    end
  end

  # ---- Property: clamp result is never more permissive than parent --------
  #
  # The core sub-agent invariant — `Tau.Tools.Builtin.Agent` relies on
  # this for ADR-0014's ceiling. For arbitrary `(requested, parent)`,
  # the result rank must be `>=` parent's rank (lower rank == more
  # permissive). When `requested` is at-or-below parent, the result
  # equals `requested`; otherwise the result equals parent.

  @moduletag :property

  defp mode_or_garbage_gen do
    StreamData.one_of([
      StreamData.member_of(@modes),
      StreamData.constant(nil),
      StreamData.constant(:not_a_mode),
      StreamData.constant("default")
    ])
  end

  property "clamp/2 result never more permissive than parent" do
    check all(
            requested <- mode_or_garbage_gen(),
            parent <- mode_or_garbage_gen()
          ) do
      result = Mode.clamp(requested, parent)
      # The result is always a recognised mode atom.
      assert Mode.mode?(result)

      effective_parent = if Mode.mode?(parent), do: parent, else: :default

      # Result rank must be >= parent rank (lower rank == more permissive).
      assert Mode.rank(result) >= Mode.rank(effective_parent)
    end
  end

  property "clamp/2 returns requested when requested is a mode at-or-below parent" do
    check all(
            requested <- StreamData.member_of(@modes),
            parent <- StreamData.member_of(@modes)
          ) do
      result = Mode.clamp(requested, parent)

      if Mode.at_or_below?(requested, parent) do
        assert result == requested
      else
        assert result == parent
      end
    end
  end
end

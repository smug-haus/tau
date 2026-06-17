defmodule Tau.Factory.GateFloorHR6Test do
  @moduledoc """
  Gating tests for HR-6 / D-322 / D-323 — mechanical gate halves `:lint` and
  `:spec_membership` MUST be members of the engine-fixed gate floor.

  Written BEFORE the production fix exists (oracle-separation phase, D-304).
  The current `lib/tau/factory/gate.ex` has `@gate_floor [:mutation, :critic,
  :reviewer]` — `:lint` and `:spec_membership` are absent. These tests FAIL
  (assertion failure) until the implementer adds them to the floor and wires
  `run_half/4` clauses for them.

  ## Invariant

  HR-6 (issue #542): All mechanizable halves of spec-discipline invariants
  (INV-23, INV-24) MUST move from critic prose into mechanical gate halves.
  Falsified if a mechanizable check (`:lint` — D-323 / INV-24; `:spec_membership`
  — D-322 / INV-23) is absent from the engine-fixed floor.

  The SPEC-FACTORY-GATE §3 constraints are:
  - **D-354** — floor `{mutation, critic, reviewer}` [currently missing :lint and
    :spec_membership] is engine-fixed and non-shrinkable by policy.
  - **D-322** — `Gate.SpecMembership` is a **mechanical gate half** (C5); it MUST
    appear in the floor (B2).
  - **D-323** — the lint half runs through `Toolchain.lint/1` as a **gate half**;
    it MUST appear in the floor.
  - **C208-B2** — the two oracle halves back the mechanical floor; they cannot
    substitute for it. An operator cannot policy away a floor member.

  ## Entry points exercised

  - `Tau.Factory.Gate.gate_floor/0` — the real public accessor for the
    engine-fixed floor list. The test asserts members directly.
  - `Tau.Factory.Gate.compose/1` — the real floor-enforcement entry point.
    The test asserts that `:lint` and `:spec_membership` are required floor
    members (omitting them raises a floor violation).

  AC linkage: HR-6, D-322, D-323 (the `@tag :hr_6` / `@tag :d_322` /
  `@tag :d_323` tokens satisfy Gate 5.1).
  """

  use ExUnit.Case, async: true

  @moduletag :hr_6
  @moduletag :d_322
  @moduletag :d_323

  # Runtime reference — file compiles even before the module exists.
  @gate Tau.Factory.Gate

  # ---------------------------------------------------------------------------
  # HR-6 / D-322 — :spec_membership MUST be in the engine-fixed floor
  #
  # `gate_floor/0` returns the engine-fixed, non-shrinkable floor list.
  # The SPEC (D-322, C5, B2) requires `:spec_membership` to be a member.
  # The current implementation has [:mutation, :critic, :reviewer] — absent.
  # ---------------------------------------------------------------------------

  @tag :hr_6
  @tag :d_322
  test "HR-6 D-322: gate_floor/0 includes :spec_membership as a mechanical gate half" do
    floor = @gate.gate_floor()

    assert is_list(floor),
           "gate_floor/0 must return a list; got #{inspect(floor)}"

    assert :spec_membership in floor,
           "HR-6/D-322: :spec_membership MUST be in the engine-fixed floor " <>
             "(mechanizes INV-23; currently absent). Got: #{inspect(floor)}"
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-323 — :lint MUST be in the engine-fixed floor
  #
  # `gate_floor/0` returns the engine-fixed, non-shrinkable floor list.
  # The SPEC (D-323, B4) requires the lint half (Toolchain.lint/1 executed by
  # the engine) to be a floor member.  The current implementation omits :lint.
  # ---------------------------------------------------------------------------

  @tag :hr_6
  @tag :d_323
  test "HR-6 D-323: gate_floor/0 includes :lint as a mechanical gate half" do
    floor = @gate.gate_floor()

    assert is_list(floor),
           "gate_floor/0 must return a list; got #{inspect(floor)}"

    assert :lint in floor,
           "HR-6/D-323: :lint MUST be in the engine-fixed floor " <>
             "(mechanizes INV-24 / OTP non-negotiable lint; currently absent). " <>
             "Got: #{inspect(floor)}"
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-354 — compose/1 rejects a policy_pin that omits :lint
  #
  # Once :lint is in the floor, a manifest that explicitly omits it MUST
  # produce {:error, {:gate_floor_violation, missing}} where :lint ∈ missing.
  # This mirrors the existing floor-violation contract for :mutation/:critic.
  # ---------------------------------------------------------------------------

  @tag :hr_6
  @tag :d_354
  test "HR-6 D-354: compose/1 rejects a manifest that omits :lint (floor violation)" do
    # A manifest that declares the old floor plus :spec_membership but omits :lint.
    policy_pin_missing_lint = %{
      gate_manifest: [:mutation, :critic, :reviewer, :spec_membership]
    }

    result = @gate.compose(policy_pin_missing_lint)

    assert match?({:error, {:gate_floor_violation, _}}, result),
           "HR-6/D-354: compose/1 must return {:error, {:gate_floor_violation, _}} " <>
             "when :lint is omitted from the manifest (once :lint is in the floor). " <>
             "Got: #{inspect(result)}"

    {:error, {:gate_floor_violation, missing}} = result

    assert :lint in missing,
           "HR-6/D-354: :lint must appear in the gate_floor_violation missing list. " <>
             "Got: #{inspect(missing)}"
  end

  # ---------------------------------------------------------------------------
  # HR-6 / D-354 — compose/1 rejects a manifest that omits :spec_membership
  #
  # Once :spec_membership is in the floor, a manifest that explicitly omits it
  # MUST produce {:error, {:gate_floor_violation, missing}}.
  # ---------------------------------------------------------------------------

  @tag :hr_6
  @tag :d_354
  test "HR-6 D-354: compose/1 rejects a manifest that omits :spec_membership (floor violation)" do
    # A manifest that declares the old floor plus :lint but omits :spec_membership.
    policy_pin_missing_sm = %{
      gate_manifest: [:mutation, :critic, :reviewer, :lint]
    }

    result = @gate.compose(policy_pin_missing_sm)

    assert match?({:error, {:gate_floor_violation, _}}, result),
           "HR-6/D-354: compose/1 must return {:error, {:gate_floor_violation, _}} " <>
             "when :spec_membership is omitted from the manifest (once it is in the floor). " <>
             "Got: #{inspect(result)}"

    {:error, {:gate_floor_violation, missing}} = result

    assert :spec_membership in missing,
           "HR-6/D-354: :spec_membership must appear in the gate_floor_violation missing list. " <>
             "Got: #{inspect(missing)}"
  end

  # ---------------------------------------------------------------------------
  # HR-6 — compose/1 returns {:ok, manifest} when ALL floor members present
  #
  # When a manifest includes the full floor (mutation + critic + reviewer +
  # lint + spec_membership), compose/1 must accept it and return {:ok, _}.
  # This is the positive-path conformance assertion.
  # ---------------------------------------------------------------------------

  @tag :hr_6
  test "HR-6: compose/1 accepts a manifest containing all five floor members" do
    policy_pin_full = %{
      gate_manifest: [:mutation, :critic, :reviewer, :lint, :spec_membership]
    }

    result = @gate.compose(policy_pin_full)

    assert match?({:ok, _}, result),
           "HR-6: compose/1 must return {:ok, manifest} when all floor members " <>
             "(including :lint and :spec_membership) are present. Got: #{inspect(result)}"

    {:ok, manifest} = result

    assert :lint in manifest,
           "HR-6: :lint must be in the composed manifest. Got: #{inspect(manifest)}"

    assert :spec_membership in manifest,
           "HR-6: :spec_membership must be in the composed manifest. Got: #{inspect(manifest)}"
  end
end

defmodule Tau.Factory.ActionClassifierTest do
  @moduledoc """
  Gating tests for D-319 — No Unilateral Destruction (action classifier).

  Exercises `Tau.Factory.ActionClassifier.classify/1` at the boundary it
  governs (SPEC-FACTORY-GOV §4 B7, §6 D-319).

  ## What is tested

  D-319 states: "ActionClassifier.classify/1 is pure and total; every
  kind ∈ @destructive yields {:deny, :destructive}; the deny is structural —
  every effecting path (notably M's git push) calls classify/1 before executing,
  and a deny routes to K as E-DESTRUCTIVE with the action never auto-executing
  (INV-20 □(destructive(a) → escalate ∧ ¬auto_execute))."

  The SPEC enforces this via:
  - `action_classifier_property_test.exs` (classify totality + every denylist
    member denied, tagged `:property`) — not this file.
  - `action_classifier_test.exs` (this file): "a classified destructive action
    is denied + raises E-DESTRUCTIVE + does not execute — the structural-deny
    test" (SPEC-FACTORY-GOV §6 D-319).

  ### Tests

  1. **Module existence (D-319)**: `Tau.Factory.ActionClassifier` must exist
     and export `classify/1`.

  2. **Denylist — full coverage (D-319 / B7)**: every atom in the `@destructive`
     MapSet per SPEC-FACTORY-GOV §4 B7 —
     `[:force_push, :history_rewrite, :release, :external_publish, :data_migration]`
     — yields `{:deny, :destructive}`.

  3. **Allow path (D-319 / B7)**: a non-destructive kind yields `:allow`.

  4. **Totality (D-319 / C219)**: `classify/1` never raises on any input.

  5. **Structural-deny in MergeAuthority (D-319 / INV-20)**: the deny is
     structural — `Tau.Factory.ActionClassifier` is referenced from the module
     that owns the `cas_push` path (`Tau.Factory.MergeAuthority`), AND the
     classify call is made with a non-hardcoded-destructive argument so that the
     `:allow` branch is reachable. If MergeAuthority passes a literal denylist
     member (e.g. `:force_push`) directly to classify/1, the `:allow` branch is
     permanently dead, `cas_push` can never execute, and MergeAuthority can never
     merge — which falsifies INV-20 (no auto-execute means no merge at all, the
     opposite of the intent). The guard must sit in front of an *actual action
     context*, not hardcode a destructive kind.

  ## Failure expectation

  After the reviewer found f-2: MergeAuthority calls `classify(:force_push)`
  hardcoded — the `:allow` branch is permanently dead and `cas_push` can never
  execute. Test #5b asserts this pattern is NOT present in MergeAuthority source;
  it FAILS against the current production code (correct fail-before).

  ## Pinned API contract (implementer must conform exactly)

  ### `Tau.Factory.ActionClassifier.classify/1`

      @spec classify(atom() | struct() | term()) :: :allow | {:deny, :destructive}

  Denylist per SPEC-FACTORY-GOV §4 B7:

      @destructive MapSet.new([
        :force_push,
        :history_rewrite,
        :release,
        :external_publish,
        :data_migration
      ])

  Rules:
  - A `kind ∈ @destructive` yields `{:deny, :destructive}` unconditionally.
  - Any other input yields `:allow`.
  - The function is total — never raises on any input.
  - Must be called BEFORE any side-effecting execution (C207 / B7).
  - Must be called with the action kind from context, NOT a hardcoded denylist
    member — a hardcoded denylist member makes the :allow branch permanently
    dead, defeating INV-20's requirement that non-destructive actions proceed.

  ## AC linkage

  - D-319 — every test tagged `:d_319`
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.ActionClassifier

  @moduletag :d_319

  # The full denylist per SPEC-FACTORY-GOV §4 B7.
  @destructive_kinds [
    :force_push,
    :history_rewrite,
    :release,
    :external_publish,
    :data_migration
  ]

  # ---------------------------------------------------------------------------
  # 1. Module existence
  # ---------------------------------------------------------------------------

  describe "D-319 — Tau.Factory.ActionClassifier must exist and export classify/1" do
    @tag :d_319
    test "D-319: Tau.Factory.ActionClassifier module is defined" do
      assert Code.ensure_loaded?(ActionClassifier),
             "Tau.Factory.ActionClassifier module does not exist — D-319 requires it as " <>
               "the structural deny boundary for destructive actions (SPEC-FACTORY-GOV §4 B7 / C7)"
    end

    @tag :d_319
    test "D-319: Tau.Factory.ActionClassifier exports classify/1" do
      assert Code.ensure_loaded?(ActionClassifier),
             "Tau.Factory.ActionClassifier does not exist"

      assert function_exported?(ActionClassifier, :classify, 1),
             "Tau.Factory.ActionClassifier.classify/1 is not exported — " <>
               "D-319 requires this as the single deny boundary before any effecting path " <>
               "(SPEC-FACTORY-GOV §4 B7 / C7)"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Denylist — every @destructive member yields {:deny, :destructive}
  # ---------------------------------------------------------------------------

  describe "D-319 — every @destructive kind yields {:deny, :destructive}" do
    for kind <- [
          :force_push,
          :history_rewrite,
          :release,
          :external_publish,
          :data_migration
        ] do
      @tag :d_319
      @kind kind
      test "D-319: #{kind} is denied — classify/1 returns {:deny, :destructive}" do
        result = ActionClassifier.classify(@kind)

        assert {:deny, :destructive} == result,
               "D-319: ActionClassifier.classify/1 must return {:deny, :destructive} " <>
                 "for destructive kind #{inspect(@kind)}, got: #{inspect(result)} — " <>
                 "a non-denied denylist member falsifies INV-20 (SPEC-FACTORY-GOV §4 B7, §6 D-319)"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Allow path
  # ---------------------------------------------------------------------------

  describe "D-319 — non-destructive action kind yields :allow" do
    @tag :d_319
    test "D-319: classify/1 returns :allow for a non-destructive kind :read" do
      result = ActionClassifier.classify(:read)

      assert :allow == result,
             "D-319: ActionClassifier.classify/1 must return :allow for non-destructive kinds; " <>
               "got #{inspect(result)} for :read (SPEC-FACTORY-GOV §4 B7)"
    end

    @tag :d_319
    test "D-319: classify/1 returns :allow for :merge (a normal coordinated action)" do
      result = ActionClassifier.classify(:merge)

      assert :allow == result,
             "D-319: ActionClassifier.classify/1 must return :allow for :merge; " <>
               "got #{inspect(result)} — only @destructive members are denied (SPEC-FACTORY-GOV §4 B7)"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Totality — classify/1 never raises on any input (C219)
  # ---------------------------------------------------------------------------

  describe "D-319 / C219 — classify/1 is total (never raises on any input)" do
    @tag :d_319
    test "D-319 / C219: classify/1 does not raise on an unknown atom" do
      result =
        try do
          ActionClassifier.classify(:unknown_action_xyz_d319)
        rescue
          e -> {:raised, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      refute match?({:raised, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 raised on :unknown_action_xyz_d319 — " <>
               "totality violated (C219 requires a total function over all inputs)"

      refute match?({:caught, _, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 threw on :unknown_action_xyz_d319 — " <>
               "totality violated"

      assert result in [:allow, {:deny, :destructive}],
             "D-319 / C219: classify/1 must return :allow or {:deny, :destructive}; " <>
               "got: #{inspect(result)}"
    end

    @tag :d_319
    test "D-319 / C219: classify/1 does not raise on nil input" do
      result =
        try do
          ActionClassifier.classify(nil)
        rescue
          e -> {:raised, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      refute match?({:raised, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 raised on nil — " <>
               "totality violated; must handle any input without raising"

      refute match?({:caught, _, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 threw on nil — totality violated"
    end

    @tag :d_319
    test "D-319 / C219: classify/1 does not raise on an arbitrary tuple input" do
      result =
        try do
          ActionClassifier.classify({:some, :arbitrary, "tuple"})
        rescue
          e -> {:raised, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      refute match?({:raised, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 raised on a tuple input — " <>
               "totality violated; C219 requires total function over any input"

      refute match?({:caught, _, _}, result),
             "D-319 / C219: ActionClassifier.classify/1 threw on a tuple — totality violated"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Structural deny in MergeAuthority (D-319 / INV-20)
  #
  # SPEC-FACTORY-GOV §6 D-319: "the deny is structural — M calls classify/1
  # in front of every git push; a deny routes to K as E-DESTRUCTIVE with the
  # action never auto-executing."
  #
  # B7 (C207): "classify/1 MUST be called before any side-effecting execution
  # of the action (the git push, the release), not after."
  #
  # INV-20 (□(destructive(a) → escalate ∧ ¬auto_execute)) has two complementary
  # requirements:
  #   (a) a destructive action MUST be denied and escalated (never auto-execute)
  #   (b) a NON-destructive action (e.g. :merge from a gate-passing unit) MUST
  #       be allowed to proceed (the :allow branch must be reachable)
  #
  # If MergeAuthority calls ActionClassifier.classify/1 with a hardcoded
  # denylist member (e.g. classify(:force_push)), the :allow branch is
  # permanently unreachable — cas_push can never execute and MergeAuthority
  # can never merge. This violates INV-20 by making ¬auto_execute absolute
  # (no action ever executes), which is the opposite of the contract intent.
  #
  # The guard must wrap the *actual action context*, not a literal destructive
  # atom drawn from the denylist itself.
  #
  # Assertion strategy:
  #   5a. MergeAuthority references ActionClassifier (structural guard present).
  #   5b. MergeAuthority does NOT call classify with a hardcoded denylist member
  #       (the :allow branch is structurally reachable). FAILS against current
  #       production code that has classify(:force_push) hardcoded.
  #   5c. ActionClassifier.classify/1 itself correctly returns :allow for :merge,
  #       confirming the :allow path is real at the classifier level.
  #   5d. ActionClassifier.classify/1 denies :force_push (deny side is real).
  #   5e. All five @destructive kinds are denied (full denylist check).
  # ---------------------------------------------------------------------------

  describe "D-319 / INV-20 — structural deny: ActionClassifier guards the cas_push path in MergeAuthority" do
    @tag :d_319
    test "D-319 / INV-20 (5a): MergeAuthority source references ActionClassifier" do
      source_path =
        Path.expand("lib/tau/factory/merge_authority.ex", File.cwd!())

      assert File.exists?(source_path),
             "D-319 / INV-20: lib/tau/factory/merge_authority.ex does not exist — " <>
               "cannot verify structural deny guard"

      source = File.read!(source_path)

      assert String.contains?(source, "ActionClassifier"),
             "D-319 / INV-20: Tau.Factory.MergeAuthority does not reference " <>
               "ActionClassifier in its source — the structural deny guard for the " <>
               "cas_push path (SPEC-FACTORY-GOV §4 B7 / C207) is absent. " <>
               "The implementer must add a classify/1 call in the committing-state " <>
               "handler before cas_push executes."
    end

    @tag :d_319
    test "D-319 / INV-20 (5b): MergeAuthority does NOT hardcode a denylist member as the classify/1 argument" do
      # If MergeAuthority passes a hardcoded denylist member (e.g. :force_push,
      # :history_rewrite, :release, :external_publish, :data_migration) as the
      # argument to classify/1, the :allow branch is permanently dead and
      # cas_push can never execute. This makes it impossible for MergeAuthority
      # to merge anything — the opposite of its purpose.
      #
      # The test scans MergeAuthority source for each denylist atom appearing
      # directly inside a classify() call. A match indicates a hardcoded-denylist
      # bug; the fix is to derive the action kind from unit/train context.
      #
      # CURRENT STATE: MergeAuthority calls ActionClassifier.classify(:force_push)
      # — this test FAILS (correct fail-before for reviewer finding f-2, #578).
      source_path =
        Path.expand("lib/tau/factory/merge_authority.ex", File.cwd!())

      assert File.exists?(source_path),
             "D-319 / INV-20: lib/tau/factory/merge_authority.ex does not exist"

      source = File.read!(source_path)

      # Each of these patterns is a hardcoded-denylist call that makes :allow
      # permanently unreachable in MergeAuthority. None should appear in source.
      hardcoded_denylist_patterns = [
        "classify(:force_push)",
        "classify(:history_rewrite)",
        "classify(:release)",
        "classify(:external_publish)",
        "classify(:data_migration)"
      ]

      for pattern <- hardcoded_denylist_patterns do
        refute String.contains?(source, pattern),
               "D-319 / INV-20: Tau.Factory.MergeAuthority calls ActionClassifier." <>
                 "#{pattern} with a hardcoded denylist member — the :allow branch " <>
                 "is permanently unreachable, cas_push can never execute, and " <>
                 "MergeAuthority can never merge. INV-20 requires non-destructive " <>
                 "actions to auto-execute; a hardcoded deny makes that impossible. " <>
                 "Fix: derive the action kind from unit/train context, not from the " <>
                 "denylist itself. (SPEC-FACTORY-GOV §4 B7 / C207 / INV-20)"
      end
    end

    @tag :d_319
    test "D-319 / INV-20 (5c): ActionClassifier.classify/1 allows :merge (confirming :allow path is real)" do
      # The :merge action kind is representative of the non-destructive action
      # that MergeAuthority's cas_push path executes on behalf of a gate-passing
      # unit. classify(:merge) MUST return :allow.
      result = ActionClassifier.classify(:merge)

      assert :allow == result,
             "D-319 / INV-20: ActionClassifier.classify(:merge) returned #{inspect(result)} " <>
               "instead of :allow — the :allow branch at MergeAuthority's cas_push guard " <>
               "is unreachable for the non-destructive :merge action. INV-20 requires " <>
               "non-destructive actions to proceed. (SPEC-FACTORY-GOV §4 B7 / INV-20)"
    end

    @tag :d_319
    test "D-319 / INV-20 (5d): ActionClassifier.classify/1 denies :force_push (primary destructive action)" do
      # :force_push is the denylist kind associated with M's --force-with-lease
      # git push. The guard must deny it when it is the actual action context.
      result = ActionClassifier.classify(:force_push)

      assert {:deny, :destructive} == result,
             "D-319 / INV-20: ActionClassifier.classify(:force_push) must return " <>
               "{:deny, :destructive} — :force_push is in the @destructive denylist; " <>
               "got: #{inspect(result)} " <>
               "(SPEC-FACTORY-GOV §4 B7 / INV-20 □(destructive(a) → escalate ∧ ¬auto_execute))"
    end

    @tag :d_319
    test "D-319 / INV-20 (5e): classify/1 covers all five documented @destructive kinds" do
      for kind <- @destructive_kinds do
        result = ActionClassifier.classify(kind)

        assert {:deny, :destructive} == result,
               "D-319 / INV-20: ActionClassifier.classify/1 failed to deny #{inspect(kind)} — " <>
                 "all five @destructive members must be denied; got: #{inspect(result)} " <>
                 "(SPEC-FACTORY-GOV §4 B7, §6 D-319)"
      end
    end
  end
end

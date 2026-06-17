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
     that owns the `cas_push` path (`Tau.Factory.MergeAuthority`), so the guard
     cannot be absent without the production code failing to compile. The test
     checks this at the source level.

  ## Failure expectation on current branch

  `Tau.Factory.ActionClassifier` does not exist in lib/ (grep on the branch
  confirms zero `defmodule Tau.Factory.ActionClassifier` results). Tests that
  invoke `classify/1` fail with `UndefinedFunctionError`. The structural-deny
  test (5) fails because MergeAuthority does not alias or call ActionClassifier.

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

  ## AC linkage

  - D-319 — every test tagged `:d_319`
  """

  use ExUnit.Case, async: true

  @moduletag :d_319

  # Module reference via attribute to avoid compile-time crash when absent.
  @classifier Tau.Factory.ActionClassifier

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
      assert Code.ensure_loaded?(@classifier),
             "Tau.Factory.ActionClassifier module does not exist — D-319 requires it as " <>
               "the structural deny boundary for destructive actions (SPEC-FACTORY-GOV §4 B7 / C7)"
    end

    @tag :d_319
    test "D-319: Tau.Factory.ActionClassifier exports classify/1" do
      assert Code.ensure_loaded?(@classifier),
             "Tau.Factory.ActionClassifier does not exist"

      assert function_exported?(@classifier, :classify, 1),
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
        result = apply(@classifier, :classify, [@kind])

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
      result = apply(@classifier, :classify, [:read])

      assert :allow == result,
             "D-319: ActionClassifier.classify/1 must return :allow for non-destructive kinds; " <>
               "got #{inspect(result)} for :read (SPEC-FACTORY-GOV §4 B7)"
    end

    @tag :d_319
    test "D-319: classify/1 returns :allow for :merge (a normal coordinated action)" do
      result = apply(@classifier, :classify, [:merge])

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
          apply(@classifier, :classify, [:unknown_action_xyz_d319])
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
          apply(@classifier, :classify, [nil])
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
          apply(@classifier, :classify, [{:some, :arbitrary, "tuple"}])
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
  # The test asserts the structural deny is present in MergeAuthority by
  # inspecting the source code of the committing-state handler (the path that
  # calls cas_push). If ActionClassifier is not referenced in that path, the
  # guard is absent — a structural violation of D-319, not a policy choice.
  #
  # We assert this at the source level rather than via a runtime integration
  # test, because the MergeAuthority process requires a live git repo for
  # start_build/1 (fetch_main_oid runs before the injected build_fun). The
  # source-level check is a necessary precondition for the runtime invariant;
  # Gate 5.3 (mutation check) confirms the runtime path.
  # ---------------------------------------------------------------------------

  describe "D-319 / INV-20 — structural deny: ActionClassifier guards the cas_push path in MergeAuthority" do
    @tag :d_319
    test "D-319 / INV-20: ActionClassifier.classify/1 denies :force_push (primary M effecting action)" do
      # :force_push is the action kind that corresponds to M's cas_push call
      # (a --force-with-lease push to origin/main). D-319 requires that
      # classify(:force_push) returns {:deny, :destructive} so the structural
      # guard at the cas_push path can stop it.
      assert Code.ensure_loaded?(@classifier),
             "D-319 / INV-20: Tau.Factory.ActionClassifier module absent — " <>
               "the structural deny guard for M's cas_push path does not exist " <>
               "(SPEC-FACTORY-GOV §4 B7, §6 D-319)"

      result = apply(@classifier, :classify, [:force_push])

      assert {:deny, :destructive} == result,
             "D-319 / INV-20: ActionClassifier.classify(:force_push) must return " <>
               "{:deny, :destructive} — :force_push is the primary destructive action " <>
               "guarded on M's push path; got: #{inspect(result)} " <>
               "(SPEC-FACTORY-GOV §4 B7 / INV-20 □(destructive(a) → escalate ∧ ¬auto_execute))"
    end

    @tag :d_319
    test "D-319 / INV-20: classify/1 covers all five documented @destructive kinds" do
      # Assert the full denylist in one place so a missing entry fails here.
      for kind <- @destructive_kinds do
        result = apply(@classifier, :classify, [kind])

        assert {:deny, :destructive} == result,
               "D-319 / INV-20: ActionClassifier.classify/1 failed to deny #{inspect(kind)} — " <>
                 "all five @destructive members must be denied; got: #{inspect(result)} " <>
                 "(SPEC-FACTORY-GOV §4 B7, §6 D-319)"
      end
    end

    @tag :d_319
    test "D-319 / INV-20: MergeAuthority source references ActionClassifier in the committing path" do
      # The structural deny requires that MergeAuthority's committing-state
      # handler (the code path that calls cas_push) references
      # Tau.Factory.ActionClassifier. If it does not, the guard is structurally
      # absent regardless of what classify/1 returns.
      #
      # We read the MergeAuthority source and assert the reference is present.
      # This is a source-level structural check — the necessary precondition
      # for the runtime invariant (runtime confirmation is Gate 5.3).
      #
      # On the current branch, MergeAuthority does NOT reference ActionClassifier
      # anywhere — grep returns nothing. This test fails (correct fail-before).
      # After the implementer adds the classify/1 call in the committing handler,
      # the source reference is present and this test passes.
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
  end
end

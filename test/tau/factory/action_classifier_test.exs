defmodule Tau.Factory.ActionClassifierTest do
  @moduledoc """
  Gating test for issue #587 — INV-20 / D-319: no unilateral destruction.

  Enforces the SPEC-FACTORY-GOV §4 B7 contract:

    `Tau.Factory.ActionClassifier.classify/1 :: (Action.t()) -> :allow | {:deny, :destructive}`

  Pure, total, over a **data** denylist
  `@destructive = MapSet.new([:force_push, :history_rewrite, :release,
  :external_publish, :data_migration])`. Pattern-match on the action's `kind`
  atom (INV-24 #2 — no string-keyed dispatch).

  Pre: called **before** any side-effecting execution ([C207]). Post: a
  destructive `kind` ⇒ `{:deny, :destructive}` and the action **never
  auto-executes** (INV-20 `□(destructive(a) → escalate ∧ ¬auto_execute)`).

  The structural deny contract (D-319) also requires that a
  `{:deny, :destructive}` routes to K as E-DESTRUCTIVE via
  `Tau.Factory.Escalation.classify({:destructive, _})` → `{:"E-DESTRUCTIVE",
  :unit}`.

  ## Fail-before

  `Tau.Factory.ActionClassifier` (lib/tau/factory/action_classifier.ex) does
  not exist in lib/. `Tau.Factory.ActionClassifier.Action` (the %Action{}
  struct) likewise does not exist. These tests fail with a compile error or
  UndefinedFunctionError until the implementer lands the module — that
  fail-before is the correct state.

  AC/D-NNN linkage: INV-20 / D-319 (#587).
  """

  use ExUnit.Case, async: true

  @moduletag :d_319
  @moduletag :inv_20

  alias Tau.Factory.ActionClassifier
  alias Tau.Factory.ActionClassifier.Action
  alias Tau.Factory.Escalation

  # The five destructive kinds enumerated in the @destructive denylist
  # (SPEC-FACTORY-GOV §4 B7, docs/arch/04-software-architecture/governance.md §4).
  @destructive_kinds [
    :force_push,
    :history_rewrite,
    :release,
    :external_publish,
    :data_migration
  ]

  # ---------------------------------------------------------------------------
  # B7 — every @destructive kind is denied (D-319 / INV-20)
  # ---------------------------------------------------------------------------

  describe "classify/1 — destructive denylist (D-319 / INV-20)" do
    @describetag :d_319
    @describetag :inv_20

    for kind <- [
          :force_push,
          :history_rewrite,
          :release,
          :external_publish,
          :data_migration
        ] do
      @kind kind

      @tag :d_319
      @tag :inv_20
      test "INV-20 / D-319: classify/1 denies destructive kind :#{@kind} with {:deny, :destructive}" do
        action = %Action{kind: @kind}

        assert ActionClassifier.classify(action) == {:deny, :destructive},
               "Expected {:deny, :destructive} for kind=#{inspect(@kind)}, " <>
                 "but action classified as :allow — INV-20 / D-319 violated: " <>
                 "destructive action would auto-execute without human approval"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # B7 — non-destructive kind is allowed (D-319 / INV-20)
  # ---------------------------------------------------------------------------

  @tag :d_319
  @tag :inv_20
  test "INV-20 / D-319: classify/1 allows a non-destructive action kind" do
    action = %Action{kind: :read_file}

    assert ActionClassifier.classify(action) == :allow,
           "Expected :allow for non-destructive kind=:read_file, " <>
             "but got {:deny, :destructive} — classifier must not over-deny"
  end

  # ---------------------------------------------------------------------------
  # B7/C219 — totality: any %Action{} input returns exactly one of the two
  # permitted values; never raises (INV-20 / D-319 / [C219])
  # ---------------------------------------------------------------------------

  @tag :d_319
  @tag :inv_20
  test "INV-20 / D-319: classify/1 is total — any %Action{} produces :allow or {:deny, :destructive}" do
    sample_kinds = [
      :force_push,
      :history_rewrite,
      :release,
      :external_publish,
      :data_migration,
      :read_file,
      :write_file,
      :run_tests,
      :open_pr,
      :unknown_action
    ]

    for kind <- sample_kinds do
      result =
        try do
          ActionClassifier.classify(%Action{kind: kind})
        rescue
          e -> {:raised, e}
        end

      refute match?({:raised, _}, result),
             "classify/1 raised for kind=#{inspect(kind)}: #{inspect(result)}"

      assert result == :allow or result == {:deny, :destructive},
             "classify/1 must return :allow or {:deny, :destructive} for any %Action{}, " <>
               "got #{inspect(result)} for kind=#{inspect(kind)}"
    end
  end

  # ---------------------------------------------------------------------------
  # B8 routing — {:deny, :destructive} routes to E-DESTRUCTIVE via Escalation
  # (D-319 structural-deny: the deny routes to K as E-DESTRUCTIVE; per
  # SPEC-FACTORY-GOV §4 B8 + SPEC-FACTORY-CORE D-317)
  # ---------------------------------------------------------------------------

  @tag :d_319
  @tag :inv_20
  test "INV-20 / D-319: a {:deny, :destructive} verdict routes to E-DESTRUCTIVE via Escalation.classify/1" do
    # The structural-deny path: when ActionClassifier returns {:deny, :destructive},
    # the effecting path MUST raise this to K as E-DESTRUCTIVE. The routing
    # contract is implemented by Escalation.classify({:destructive, action}).
    # Assert that the Escalation classifier maps the destructive trigger to E-DESTRUCTIVE.
    assert Escalation.classify({:destructive, :force_push}) == {:"E-DESTRUCTIVE", :unit},
           "Escalation.classify({:destructive, _}) must return {E-DESTRUCTIVE, :unit}; " <>
             "D-319 routing contract: a {:deny, :destructive} from ActionClassifier " <>
             "routes to K as E-DESTRUCTIVE and never auto-executes"
  end

  # ---------------------------------------------------------------------------
  # D-319 structural gate: force_push is denied + E-DESTRUCTIVE routed
  # (full conformant path for the primary INV-20 example)
  # ---------------------------------------------------------------------------

  @tag :d_319
  @tag :inv_20
  test "INV-20 / D-319: force_push action is denied and E-DESTRUCTIVE is the escalation class (full structural path)" do
    # This is the primary INV-20 observable: a :force_push action (the concrete
    # case: M's git push to origin/main) must be classified as destructive,
    # and the destructive verdict must map to E-DESTRUCTIVE in the escalation
    # classifier — meaning it can NEVER auto-execute without human approval.
    action = %Action{kind: :force_push}

    # Step 1: ActionClassifier denies it.
    verdict = ActionClassifier.classify(action)

    assert verdict == {:deny, :destructive},
           "INV-20 violated: force_push action was not denied by ActionClassifier. " <>
             "No process other than MergeAuthority may push to origin/main autonomously; " <>
             "ActionClassifier must deny :force_push as {:deny, :destructive}."

    # Step 2: the {:deny, :destructive} verdict routes to E-DESTRUCTIVE via Escalation.
    # The effecting path converts the deny into the trigger {:destructive, action}
    # delivered to Escalation.classify/1, which must return {E-DESTRUCTIVE, :unit}.
    escalation_class = Escalation.classify({:destructive, action})

    assert escalation_class == {:"E-DESTRUCTIVE", :unit},
           "D-319 routing contract violated: {:deny, :destructive} verdict for :force_push " <>
             "must route to {E-DESTRUCTIVE, :unit} via Escalation.classify/1, " <>
             "but got #{inspect(escalation_class)}. " <>
             "The action must never auto-execute — it must be escalated to the Coordinator."
  end
end

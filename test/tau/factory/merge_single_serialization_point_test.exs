defmodule Tau.Factory.MergeSingleSerializationPointTest do
  @moduledoc """
  Gating test for issue #591 (INV-DIST-M-SINGLE — MergeAuthority is the single
  serialization point for origin/main writes).

  INV-DIST-M-SINGLE statement:
    "MergeAuthority (M) MUST be the single serialization point for origin/main
     writes; clustering M without consensus risks split-brain where two M halves
     each believe they hold the critical section and both do a CAS. Falsified by:
     any design permitting two concurrent M instances."

  SPEC-FACTORY-MERGE §3 [C200-B4]:
    "`origin/main` has exactly one writer: M's `cas_push` (C3). This is REQUIRED
     for INV-2, not a convenience."

  SPEC-FACTORY-MERGE §4 B7 contract:
    `classify_main_write/1 :: (actor) -> :ok | {:escalate, :"E-DESTRUCTIVE"}`
    `actor != :merge_authority` => `{:escalate, :"E-DESTRUCTIVE"}` (INV-20; cited
    SPEC-FACTORY-GOV/D-319). It is never auto-executed.

  SPEC-FACTORY-MERGE [C212-B7]:
    "A non-M `origin/main` write crossing the action boundary carries only enough
     to classify it: `classify_main_write(actor)` for `actor != :merge_authority`
     => `{:escalate, :"E-DESTRUCTIVE"}` (INV-20). It is never auto-executed."

  Architecture (distribution-readiness.md §1):
    "Two M instances under partition = two concurrent `origin/main` writers = the
     catastrophe D-S1's safety wall exists to forbid."

  ## Fail-before validity

  `Tau.Factory.MergeAuthority.classify_main_write/1` is referenced in SPEC §4 B7
  but does NOT exist in the production code. These tests fail with
  `UndefinedFunctionError` until the implementer adds:
    - `MergeAuthority.classify_main_write/1` (or equivalent in ActionClassifier)

  This is a legitimate fail-before per oracle-separation (factory-loop §4b).

  ## AC / D-NNN linkage

  @tag :inv_dist_m_single -- all tests in this file.
  Cross-ref: SPEC-FACTORY-MERGE §4 B7 / [C212-B7], SPEC-FACTORY-GOV/D-319,
  INV-20, C200-B4 (sole writer of origin/main).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_dist_m_single

  @merge_authority Tau.Factory.MergeAuthority

  # ---------------------------------------------------------------------------
  # B7 / C212: classify_main_write/1 — non-M actor escalation
  # ---------------------------------------------------------------------------
  #
  # SPEC-FACTORY-MERGE §4 B7 documents the function:
  #   classify_main_write/1 :: (actor) -> :ok | {:escalate, :"E-DESTRUCTIVE"}
  #
  # For actor != :merge_authority => {:escalate, :"E-DESTRUCTIVE"} (INV-20).
  # For actor == :merge_authority => :ok.
  #
  # This function is NOT yet implemented. Calling it below causes
  # UndefinedFunctionError, making these tests legitimately RED before the
  # implementer adds classify_main_write/1.

  describe "INV-DIST-M-SINGLE — B7: non-M origin/main writes are classified E-DESTRUCTIVE" do
    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE: classify_main_write/1 returns {:escalate, :E-DESTRUCTIVE} for any actor that is not :merge_authority" do
      # SPEC-FACTORY-MERGE [C212-B7]: a non-M actor attempting to write origin/main
      # MUST be classified as E-DESTRUCTIVE and never auto-executed.
      #
      # The actors that are NOT :merge_authority include: operator scripts,
      # workers, sub-agents, coding agents, bootstrap paths, or any other actor.
      # INV-20 requires: □(destructive(a) → escalate ∧ ¬auto_execute).
      #
      # FAILING ASSERTION: MergeAuthority.classify_main_write/1 does not exist.
      # UndefinedFunctionError is the expected fail-before.
      result = @merge_authority.classify_main_write(:operator_script)

      assert result == {:escalate, :"E-DESTRUCTIVE"},
             "INV-DIST-M-SINGLE / B7 / [C212-B7]: classify_main_write/1 MUST return " <>
               "{:escalate, :\"E-DESTRUCTIVE\"} for any actor that is not :merge_authority. " <>
               "Got: #{inspect(result)}. " <>
               "INV-20: □(destructive(a) → escalate ∧ ¬auto_execute). A non-M actor " <>
               "attempting to write origin/main is a destructive action that MUST be " <>
               "escalated to K as E-DESTRUCTIVE and never auto-executed. " <>
               "SPEC-FACTORY-MERGE §4 B7 / [C212-B7]."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE: classify_main_write/1 returns :ok for the :merge_authority actor" do
      # Positive case: :merge_authority IS the sole authorized writer.
      # classify_main_write(:merge_authority) MUST return :ok.
      # Any other return would prevent M from writing origin/main at all.
      #
      # FAILING ASSERTION: MergeAuthority.classify_main_write/1 does not exist.
      result = @merge_authority.classify_main_write(:merge_authority)

      assert result == :ok,
             "INV-DIST-M-SINGLE / B7 / [C212-B7]: classify_main_write/1 MUST return :ok " <>
               "when called with :merge_authority as the actor. M is the sole authorized " <>
               "writer of origin/main per [C200-B4]. Denying :merge_authority would " <>
               "prevent any merge from landing. Got: #{inspect(result)}."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE: classify_main_write/1 returns {:escalate, :E-DESTRUCTIVE} for :worker actor" do
      # Workers (W) are in the execution tier — they submit units to M but MUST NOT
      # push directly to origin/main. A worker attempting a direct push bypasses
      # the merge serialization point and breaks [C200-B4].
      #
      # FAILING ASSERTION: MergeAuthority.classify_main_write/1 does not exist.
      result = @merge_authority.classify_main_write(:worker)

      assert result == {:escalate, :"E-DESTRUCTIVE"},
             "INV-DIST-M-SINGLE / B7: classify_main_write(:worker) MUST return " <>
               "{:escalate, :\"E-DESTRUCTIVE\"}. A worker writing origin/main directly " <>
               "bypasses M (the serialization point), violating [C200-B4] and INV-2. " <>
               "Got: #{inspect(result)}."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE: classify_main_write/1 returns {:escalate, :E-DESTRUCTIVE} for :coding_agent actor" do
      # Coding agents are sandboxed sub-agents; they MUST NOT write origin/main.
      # The ActionClassifier (SPEC-FACTORY-GOV D-319) forbids this. A sub-agent
      # that can write origin/main bypasses the merge authority and imports
      # split-brain risk (the same catastrophe as two M instances).
      #
      # FAILING ASSERTION: MergeAuthority.classify_main_write/1 does not exist.
      result = @merge_authority.classify_main_write(:coding_agent)

      assert result == {:escalate, :"E-DESTRUCTIVE"},
             "INV-DIST-M-SINGLE / B7: classify_main_write(:coding_agent) MUST return " <>
               "{:escalate, :\"E-DESTRUCTIVE\"}. A coding agent writing origin/main " <>
               "directly bypasses M, violating [C200-B4] and the ActionClassifier " <>
               "deny (SPEC-FACTORY-GOV D-319). Got: #{inspect(result)}."
    end
  end
end

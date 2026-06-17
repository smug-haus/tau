defmodule Tau.Factory.MergeSoleWriterTest do
  @moduledoc """
  Gating test for issue #591 (INV-DIST-M-SINGLE) and AC-7 (PR-MERGE-4, B7/INV-20).

  SPEC-FACTORY-MERGE §6:
    "AC-7 (PR-MERGE-4, B7/INV-20): `merge_sole_writer_test.exs` passes — a
     simulated non-M `origin/main` write is classified `{:escalate, :"E-DESTRUCTIVE"}`
     and NOT auto-executed; M remains the only path that advances `origin/main`."

  SPEC-FACTORY-MERGE §4 B7:
    "non-M actor ↔ `origin/main`: any non-M push => `classify_main_write/1 ->
     {:escalate, :"E-DESTRUCTIVE"}`. Cited, SPEC-FACTORY-GOV/D-319."

  SPEC-FACTORY-MERGE [C212-B7]:
    "A non-M `origin/main` write crossing the action boundary carries only enough
     to classify it: `classify_main_write(actor)` for `actor != :merge_authority`
     => `{:escalate, :"E-DESTRUCTIVE"}` (INV-20). It is never auto-executed."

  SPEC-FACTORY-MERGE §4 B7 function signature:
    `classify_main_write/1 :: (actor) -> :ok | {:escalate, :"E-DESTRUCTIVE"}`

  Architecture (distribution-readiness.md §1 / SPEC-FACTORY-MERGE §3 [C200-B4]):
    "origin/main has exactly one writer: M's cas_push. This is REQUIRED for INV-2.
     If a second writer could advance origin/main, M's expected-old-oid would be a
     stale projection of the true ref and the --force-with-lease check would race a
     writer M cannot see — reintroducing the TOCTOU below the primitive."

  INV-20 (SPEC-FACTORY-GOV §4 D-319):
    "□(destructive(a) → escalate ∧ ¬auto_execute)"

  ## Fail-before validity

  `Tau.Factory.MergeAuthority.classify_main_write/1` does NOT exist in the
  production code. These tests fail with `UndefinedFunctionError` until the
  implementer adds the function. This is the documented fail-before: the test
  exercises the real user-facing entry point (`MergeAuthority.classify_main_write/1`)
  at the boundary B7 governs.

  The implementer MUST:
    1. Add `classify_main_write/1` to `Tau.Factory.MergeAuthority` (or expose it
       via `Tau.Factory.ActionClassifier` and delegate from MergeAuthority).
    2. Implement the contract: `actor == :merge_authority => :ok`;
       `actor != :merge_authority => {:escalate, :"E-DESTRUCTIVE"}`.
    3. Wire the check inside `Tau.Factory.MergeAuthority` so it is called before
       any `cas_push/3` invocation (structural deny per [C212-B7]).

  ## AC / D-NNN linkage

  @tag :inv_dist_m_single — all tests in this file.
  AC-7 / PR-MERGE-4 / B7 / INV-20.
  Cross-ref: SPEC-FACTORY-MERGE §4 [C212-B7], SPEC-FACTORY-GOV D-319,
  C200-B4 (sole writer of origin/main).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :inv_dist_m_single

  # The real entry point exercised at boundary B7.
  # Module reference (not a hard alias) so the file compiles even when the
  # function does not yet exist; the UndefinedFunctionError surfaces at test
  # runtime, which is the legitimate fail-before.
  @merge_authority Tau.Factory.MergeAuthority

  # ---------------------------------------------------------------------------
  # AC-7 / B7: simulated non-M origin/main writes are classified E-DESTRUCTIVE
  # and never auto-executed.
  # ---------------------------------------------------------------------------

  describe "INV-DIST-M-SINGLE / AC-7 / B7 — non-M origin/main writes => {:escalate, :E-DESTRUCTIVE}" do
    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE / AC-7: classify_main_write(:operator_script) returns {:escalate, :E-DESTRUCTIVE}" do
      # An operator script pushing directly to origin/main bypasses M.
      # The classify_main_write/1 check MUST fire before the push is attempted
      # and return E-DESTRUCTIVE, preventing auto-execution.
      #
      # Fail-before: MergeAuthority.classify_main_write/1 does not exist.
      # UndefinedFunctionError is the expected failure mode.
      result = @merge_authority.classify_main_write(:operator_script)

      assert result == {:escalate, :"E-DESTRUCTIVE"},
             "INV-DIST-M-SINGLE / AC-7 / [C212-B7]: classify_main_write(:operator_script) " <>
               "MUST return {:escalate, :\"E-DESTRUCTIVE\"}. " <>
               "An operator script writing origin/main directly bypasses M, " <>
               "violating [C200-B4] (sole writer) and INV-20 (no auto-execute of destructive). " <>
               "Got: #{inspect(result)}."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE / AC-7: classify_main_write(:worker) returns {:escalate, :E-DESTRUCTIVE}" do
      # Workers are in the execution tier; they submit units to M but MUST NOT
      # push to origin/main. A direct worker push bypasses the merge serialization
      # point (M), violating [C200-B4] and INV-2 (freshness via VCS primitive).
      #
      # Fail-before: MergeAuthority.classify_main_write/1 does not exist.
      result = @merge_authority.classify_main_write(:worker)

      assert result == {:escalate, :"E-DESTRUCTIVE"},
             "INV-DIST-M-SINGLE / AC-7 / [C212-B7]: classify_main_write(:worker) " <>
               "MUST return {:escalate, :\"E-DESTRUCTIVE\"}. " <>
               "Got: #{inspect(result)}."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE / AC-7: classify_main_write(:merge_authority) returns :ok" do
      # Positive case: :merge_authority IS the sole authorized writer.
      # classify_main_write(:merge_authority) MUST return :ok.
      # Denying the authorized writer would prevent any merge from landing at all
      # — a false positive that violates [C200-B4]'s "exactly one writer" clause.
      #
      # Fail-before: MergeAuthority.classify_main_write/1 does not exist.
      result = @merge_authority.classify_main_write(:merge_authority)

      assert result == :ok,
             "INV-DIST-M-SINGLE / AC-7 / [C212-B7]: classify_main_write(:merge_authority) " <>
               "MUST return :ok. :merge_authority is the sole authorized writer of " <>
               "origin/main per [C200-B4]. Denying it would prevent any merge from landing. " <>
               "Got: #{inspect(result)}."
    end

    @tag :inv_dist_m_single
    test "INV-DIST-M-SINGLE / AC-7: classify_main_write does not auto-execute a non-M write" do
      # INV-20: □(destructive(a) → escalate ∧ ¬auto_execute).
      # When a non-M actor's write is classified {:escalate, :E-DESTRUCTIVE},
      # the call to classify_main_write/1 MUST NOT have any side effects that
      # advance origin/main. This verifies the function is a pure classifier,
      # not an effecting function.
      #
      # The test sets up a git repo, calls classify_main_write with a non-M actor,
      # and verifies origin/main was NOT advanced by the classification.
      tmp_dir = Briefly.create!(type: :directory)
      origin_path = Path.join(tmp_dir, "origin.git")
      work_path = Path.join(tmp_dir, "work")

      {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
      git_work = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
      git_work.(["config", "user.email", "test@tau.test"])
      git_work.(["config", "user.name", "Tau Test"])
      File.write!(Path.join(work_path, "README"), "initial")
      git_work.(["add", "README"])
      {_, 0} = git_work.(["commit", "-m", "initial commit"])
      {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
      {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
      {_, 0} = git_work.(["remote", "add", "origin", origin_path])
      {_, 0} = git_work.(["push", "-u", "origin", "main"])

      {initial_oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)
      initial_oid = String.trim(initial_oid)

      # Call classify_main_write with a non-M actor.
      # This MUST return {:escalate, :E-DESTRUCTIVE} AND NOT advance origin/main.
      #
      # Fail-before: MergeAuthority.classify_main_write/1 does not exist.
      _result = @merge_authority.classify_main_write(:operator_script)

      # Verify origin/main was NOT advanced by the classify call.
      {final_oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)
      final_oid = String.trim(final_oid)

      assert initial_oid == final_oid,
             "INV-DIST-M-SINGLE / AC-7 / INV-20 (¬auto_execute): classify_main_write/1 " <>
               "MUST NOT advance origin/main when called with a non-M actor. " <>
               "The function is a pure classifier — it MUST NOT execute the destructive " <>
               "action it classifies. " <>
               "initial oid: #{initial_oid}, final oid: #{final_oid}. " <>
               "If these differ, classify_main_write/1 executed the write it was " <>
               "classifying — a fatal violation of INV-20's ¬auto_execute clause."
    end
  end
end

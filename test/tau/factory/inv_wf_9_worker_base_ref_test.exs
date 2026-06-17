defmodule Tau.Factory.InvWf9WorkerBaseRefTest do
  @moduledoc """
  Gating test for issue #563 — INV-WF-9.

  Invariant statement:
    A worker MUST be spawned only from a system-established ref (the Unit's
    pinned base, derived from fresh origin/main), never from the spawning
    agent's branch and never the parent repository root.  Falsified by: a
    worker worktree forked from a feature branch or from the parent repo's
    HEAD rather than from a pinned origin/main-derived ref.

  SPEC-FACTORY-FLEET §4 B2:
    `init/1` allocates a private worktree at `ws` forked from the
    system-established `base_ref` (never the spawner's branch, never the
    parent root).

  SPEC-FACTORY-FLEET §3 [C214-B2]:
    Worker `init/1` pre: a system-established `base_ref` (the Unit's pinned
    base, derived from fresh `origin/main`).

  Current deviation (audit finding, issue #563):
    `Tau.Factory.Supervisor.build_unit_work_item/1` sets `base_ref: branch`
    where `branch = "unit-\#{number}"` — a fabricated feature-branch name
    derived from the issue number only, with no git fetch and no
    origin/main derivation.  `oracle_base_ref` is set to
    `"origin/\#{branch}"` (the feature branch's remote-tracking ref), also
    feature-branch-derived.  Neither field references `origin/main`.

  This test exercises the real user-facing pipeline:

    1. `Tau.Factory.Supervisor.start_link/1` (enabled: true) — assembles the
       full control subtree and wires the `wrapped_drive_fun`.
    2. `Tau.Factory.IssueSelector.select/1` — the real `select_fun`, called
       with a stub `gh_fun` that returns one open issue.
    3. The supervisor's internal `to_unit_work_item` / `build_unit_work_item`
       conversion — the deviation lives here.
    4. The `drive_fun` seam — a test-injected function that captures the
       converted `work_item` map and asserts the invariant, then returns a
       no-op pid so the Unit FSM is not actually driven.

  The test asserts:
    - `work_item.base_ref` is NOT a feature-branch name (does not match
      `"unit-<N>"` or `branch`).
    - `work_item.base_ref` IS `"origin/main"` (or a SHA derived from
      `git rev-parse origin/main` in the repo) — the only conformant
      value under D-311 / INV-WF-9.
    - `work_item.oracle_base_ref`, when present, is also NOT the
      feature-branch's remote-tracking ref (`"origin/unit-<N>"`).

  The test FAILS against current production code because
  `build_unit_work_item/1` returns `base_ref: "unit-563"` (the feature
  branch), which IS a feature-branch-derived ref, NOT `"origin/main"`.

  ## AC / D-NNN linkage
    - INV-WF-9 — every test in this file.
    - D-311 — verified position (the invariant D-311 governs is violated
      when `base_ref` is not system-established; this test is the
      fail-before gate for the conformance fix).
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :inv_wf_9

  @supervisor Tau.Factory.Supervisor
  @issue_selector Tau.Factory.IssueSelector

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Minimal throwaway git repo: init, one commit, no remote.
  # The test does NOT need a real remote — the assertion is on the `base_ref`
  # field value produced by the pipeline, not on whether `git worktree add`
  # succeeds.
  defp setup_git_repo do
    repo_dir = Briefly.create!(type: :directory)
    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial"])

    repo_dir
  end

  # Stub gh_fun: returns a single open issue so the select_fun produces a
  # work_item and the drive_fun is called exactly once.
  defp one_issue_gh_fun do
    fn _milestone ->
      {:ok, [%{"number" => 563, "title" => "INV-WF-9 test issue", "body" => "", "labels" => []}]}
    end
  end

  # ---------------------------------------------------------------------------
  # INV-WF-9 — base_ref must be origin/main-derived, not a feature branch
  # ---------------------------------------------------------------------------

  describe "INV-WF-9 — worker base_ref must be derived from origin/main, not the feature branch" do
    @tag :inv_wf_9
    test "INV-WF-9: the work_item.base_ref passed to drive_fun is origin/main-derived, not the feature branch" do
      repo_dir = setup_git_repo()
      db_path = Briefly.create!(extname: ".db")
      sup_name = :"inv_wf_9_sup_#{System.unique_integer([:positive])}"
      caller = self()

      # The capture drive_fun: records the work_item and immediately returns a
      # dummy pid (the Unit FSM is not actually driven — the test is about the
      # work_item construction, not the drive outcome).
      capture_drive_fun = fn work_item, _deps ->
        send(caller, {:captured_work_item, work_item})
        # Return a dummy pid so the supervisor's wrapped_drive_fun does not crash.
        spawn(fn -> :ok end)
      end

      _sup_pid =
        start_supervised!(
          {
            @supervisor,
            enabled: true,
            db_path: db_path,
            name: sup_name,
            repo_dir: repo_dir,
            milestone: "inv-wf-9-test",
            gh_fun: one_issue_gh_fun(),
            select_fun: &@issue_selector.select/1,
            drive_fun: capture_drive_fun
          },
          id: sup_name
        )

      # Wait for the captured work_item.  The Coordinator calls select_fun
      # immediately on entering :running, then calls drive_fun with the
      # converted work_item.  Allow up to 3 s for the async path to settle.
      assert_receive {:captured_work_item, work_item},
                     3_000,
                     "INV-WF-9: drive_fun was never called — the Supervisor pipeline " <>
                       "did not produce and pass a work_item within 3 s.  Ensure the " <>
                       "Coordinator is :running and the one-issue gh_fun is wired correctly."

      base_ref = Map.fetch!(work_item, :base_ref)

      # --- Negative assertion: base_ref MUST NOT be the feature branch --------
      # The feature branch name is "unit-<N>" (N = the issue number).
      # Any ref that starts with "unit-" or equals the branch field is a
      # feature-branch-derived ref and violates INV-WF-9.
      branch = Map.get(work_item, :branch, "")

      refute base_ref == branch,
             """
             INV-WF-9 VIOLATED: work_item.base_ref equals work_item.branch.
             The base_ref passed to WorkerSupervisor.spawn/5 is the feature branch
             ("#{base_ref}"), NOT a system-established ref derived from origin/main.
             A worker forked from this ref is NOT at a verified origin/main position.

             Fix (Supervisor.build_unit_work_item/1): derive base_ref from
             `git fetch origin && git rev-parse origin/main` in repo_dir, or set it
             to "origin/main".  Never set base_ref = branch.
             """

      refute String.starts_with?(base_ref, "unit-"),
             """
             INV-WF-9 VIOLATED: work_item.base_ref starts with "unit-" (got "#{base_ref}").
             That is a fabricated feature-branch name, not an origin/main-derived ref.
             The invariant requires base_ref to be the Unit's pinned base, derived from
             fresh origin/main (SPEC-FACTORY-FLEET §4 B2, §3 [C214-B2]).
             """

      # --- Positive assertion: base_ref MUST be origin/main-derived -----------
      # Conformant values: "origin/main" (canonical remote-tracking ref) or a
      # 40-hex SHA resolved from `git rev-parse origin/main` in repo_dir.
      is_origin_main = base_ref == "origin/main"
      is_main_sha = String.match?(base_ref, ~r/^[0-9a-f]{40}$/i)

      assert is_origin_main or is_main_sha,
             """
             INV-WF-9 VIOLATED: work_item.base_ref is neither "origin/main" nor a
             40-hex SHA derived from origin/main.  Got: "#{base_ref}".

             The SPEC requires base_ref to be the Unit's pinned base, derived from
             fresh origin/main (SPEC-FACTORY-FLEET §4 B2, §3 [C214-B2]).  Conformant
             values are:
               - "origin/main"   (canonical remote-tracking ref)
               - a 40-hex SHA from `git rev-parse origin/main` in repo_dir

             Current violation: Supervisor.build_unit_work_item/1 sets
             base_ref = branch = "unit-<N>" — a fabricated feature-branch name with
             no git fetch and no origin/main derivation.
             """

      # --- oracle_base_ref: must also NOT be feature-branch-derived ------------
      # When present, oracle_base_ref is used for the test_author worker.
      # "origin/unit-<N>" is the feature branch's remote-tracking ref, not
      # origin/main.  It is also a feature-branch-derived ref (INV-WF-9).
      if Map.has_key?(work_item, :oracle_base_ref) do
        oracle_base_ref = Map.fetch!(work_item, :oracle_base_ref)

        refute String.starts_with?(oracle_base_ref, "origin/unit-"),
               """
               INV-WF-9 VIOLATED: work_item.oracle_base_ref starts with "origin/unit-"
               (got "#{oracle_base_ref}").  That is the feature branch's remote-tracking
               ref, not an origin/main-derived ref.  The oracle (test_author) worker's
               checkout is also subject to INV-WF-9: it must fork from origin/main, never
               from the feature branch's tracking ref.
               """
      end
    end
  end
end

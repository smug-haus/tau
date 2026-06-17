defmodule Tau.Factory.MergeDogfoodGitProtocolGuardTest do
  @moduledoc """
  Gating test for issue #605 — **INV-MAI-9 git:// scheme guard** (D-359, #605).

  Pins the **completeness of the non-local origin hard-refuse precondition** of
  `mix tau.factory.dogfood` against the anonymous git daemon protocol (`git://`),
  which SPEC-FACTORY-CORE §6 D-359's invariant ("all network remote schemes
  refused") requires be rejected but which the current implementation's
  `non_local_origin?/1` does NOT match.

  ## The invariant under test (INV-MAI-9)

  D-359 (SPEC-FACTORY-CORE §6) requires `mix tau.factory.dogfood` to
  **hard-refuse any network remote scheme** before booting. The existing guard
  checks `https://`, `http://`, `ssh://`, and `git@...:` (SCP-syntax) but omits
  the `git://` scheme (anonymous git daemon protocol). A sandbox repo whose origin
  is `git://github.com/foo/bar.git` bypasses the guard, boots the factory, and
  allows MergeAuthority's sole-writer CAS push to target the network remote.

  This test asserts that `git://` IS refused — i.e. the invariant "all network
  remote schemes refused" is fully satisfied, not just the subset currently
  enumerated.

  ## The distinguishing contract

  The refusal is structural, not incidental:
  - On a NON-local origin (`git://`, `https://`, etc.) the task MUST emit the
    hardcoded "REFUSED" marker and exit **1** (via `exit({:shutdown, 1})`). It
    MUST NOT emit "[dogfood] sandbox origin: <url> — local, proceeding".
  - On a local origin the task emits "local, proceeding" and MUST NOT emit
    "REFUSED".

  The test distinguishes refusal from timeout: it uses a short wall-clock bound
  (5 s) and asserts the output contains "REFUSED" AND does NOT contain
  "local, proceeding". A task that bypasses the guard proceeds past the
  precondition, prints "local, proceeding", and times out — the negative
  assertion catches this.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  Against the current production code, `non_local_origin?/1` does NOT match
  `git://` URLs. Therefore `check_local_origin!/1` will NOT call `exit/1`, the
  task will proceed past the precondition, print "local, proceeding", and timeout
  after 5 s. The assertions on the refusal message will FAIL — a legitimate
  fail-before. The test-author writes NO production code.

  ## AC / D-NNN linkage

  - INV-MAI-9 / D-359 — all tests in this file. See SPEC-FACTORY-CORE §6 D-359,
    §7 AC-13; the `non_local_origin?/1` guard in
    `lib/mix/tasks/tau.factory.dogfood.ex` lines 248-253.
  """

  use ExUnit.Case, async: false

  @moduletag :inv_mai_9
  @moduletag :d_359
  @moduletag :capture_log

  @coordinator Tau.Factory.Coordinator

  # Root of the parent Mix project — the task is invoked here so
  # `mix tau.factory.dogfood` resolves against the project's task path.
  @project_root File.cwd!()

  # Short wall-clock bound for the precondition check.
  # The refusal exits immediately (exit code 1). A bypass proceeds into the
  # factory boot and is killed here (exit code 124). 5 s is ample margin.
  @refuse_timeout_s 5

  # ---------------------------------------------------------------------------
  # Sandbox helpers
  # ---------------------------------------------------------------------------

  # A working repo with `origin` pointing at a network URL under the given scheme.
  # No network is actually contacted: the guard reads only `remote.origin.url`.
  defp repo_with_origin(origin_url) do
    repo_dir = Briefly.create!(type: :directory)
    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(repo_dir, "README"), "seed\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "seed"])
    {_, 0} = git.(["remote", "add", "origin", origin_url])

    repo_dir
  end

  # Run `mix tau.factory.dogfood` as a real subprocess against `repo`, bounded
  # by `timeout_s` wall seconds. Returns {output, exit_code}.
  defp run_dogfood(repo, issue, timeout_s) do
    System.cmd(
      "timeout",
      [
        "#{timeout_s}",
        "mix",
        "tau.factory.dogfood",
        "--repo",
        repo,
        "--issue",
        Integer.to_string(issue)
      ],
      cd: @project_root,
      stderr_to_stdout: true,
      into: ""
    )
  end

  # ---------------------------------------------------------------------------
  # INV-MAI-9 / D-359 — git:// (anonymous git daemon protocol) MUST be refused.
  # ---------------------------------------------------------------------------

  describe "INV-MAI-9 / D-359 — mix tau.factory.dogfood hard-refuses the git:// scheme (anonymous git daemon)" do
    @tag :inv_mai_9
    @tag :d_359
    test "INV-MAI-9 / D-359: a git:// origin emits the REFUSED marker and does NOT proceed as local" do
      url = "git://github.com/smug-haus/tau.git"
      repo = repo_with_origin(url)

      {output, _exit_code} = run_dogfood(repo, 1, @refuse_timeout_s)

      # Primary assertion: the task MUST emit the hardcoded "REFUSED" marker.
      # Against current code, `non_local_origin?/1` does NOT match `git://`, so
      # `check_local_origin!/1` does not fire — "REFUSED" is absent → FAILS.
      assert output =~ "REFUSED",
             "INV-MAI-9 / D-359: mix tau.factory.dogfood MUST emit 'REFUSED' for a " <>
               "git:// origin (#{url}). The anonymous git daemon protocol is a network " <>
               "remote scheme; `non_local_origin?/1` must cover it. " <>
               "Output:\n#{output}"

      # Negative assertion: the task MUST NOT proceed past the precondition.
      # Against current code the task prints "local, proceeding" because the
      # guard passes — this negative assertion would also fail.
      refute output =~ "local, proceeding",
             "INV-MAI-9 / D-359: the task MUST NOT emit 'local, proceeding' for a " <>
               "non-local git:// origin — the precondition guard must intercept before boot. " <>
               "Output:\n#{output}"

      # The guard is a PRECONDITION (V1): the factory subtree is never assembled.
      assert Process.whereis(@coordinator) == nil,
             "INV-MAI-9 / D-359: a git:// non-local origin MUST be refused BEFORE the " <>
               "factory boots — no Tau.Factory.Coordinator may exist in this test process."
    end
  end
end

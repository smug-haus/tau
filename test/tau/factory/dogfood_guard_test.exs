defmodule Tau.Factory.DogfoodGuardTest do
  @moduledoc """
  Gating test for PR #481 — **P5c-7 dogfood safety guard** (AC-13 / D-359, #475).

  Pins the **local-origin hard-refuse precondition** of the dogfood capstone
  `mix tau.factory.dogfood`. SPEC-FACTORY-CORE §3 [C122-B11] / §6 D-359 /
  §7 AC-13 and `docs/arch/04-software-architecture/control-plane.md` §7.4
  require the task to **hard-refuse a non-local `origin` BEFORE booting the
  factory subtree**: it resolves the sandbox repo's `remote.origin.url` and,
  for any `https://` / `git@` / `ssh://` URL (a network remote), exits
  non-zero and assembles **no** Coordinator-bearing subtree. Only a local
  bare-repo `origin` (a `file://` URL or a filesystem path to a bare repo on
  the same host) is accepted.

  The guard is a **precondition, not a runtime classification** (V1): a
  misconfiguration can never point the autonomous, force-pushing control loop
  at a real GitHub remote — `MergeAuthority` is the sole writer of
  `origin/main` and advances it with `git push --force-with-lease`, an
  irreversible, gate-unassessable destructive action against a network remote.

  ## The pinned CLI contract (drives the implementer brief)

  - Invocation: `mix tau.factory.dogfood --repo <sandbox> --issue <n>`.
  - `--repo <sandbox>` names a working git repo whose `origin` remote is the
    sandbox's push target. The task reads that repo's `remote.origin.url`.
  - **Non-local origin** (`https://…` / `git@…:…` / `ssh://…`): the task
    HARD-REFUSES — it exits **non-zero**, prints an explicit refusal naming the
    non-local origin, and **does not boot** the factory (no
    `Tau.Factory.Coordinator` is started).
  - **Local bare-repo origin** (a filesystem path / `file://` to a bare repo):
    the guard PASSES — the task does NOT emit the non-local refusal and
    proceeds past the precondition.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch `mix tau.factory.dogfood` does not exist
  (`lib/mix/tasks/tau.factory.dogfood.ex` and `lib/tau/factory/dogfood/` are
  absent). Invoking the task therefore fails — the Mix task is not found — so
  the refusal cannot be observed and these tests FAIL until the implementer
  builds the task + the D-359 guard. This is a legitimate fail-before; the
  test-author writes NO production code.

  ## AC / D-NNN linkage
    - AC-13 / D-359 — every test in this file. See SPEC-FACTORY-CORE §3
      [C122-B11], §6 D-359, §7 AC-13; control-plane.md §7.4.
  """

  use ExUnit.Case, async: false

  @moduletag :ac_13
  @moduletag :d_359
  @moduletag :capture_log

  @coordinator Tau.Factory.Coordinator

  # Root of the parent Mix project (this worktree) — the task is invoked there
  # so `mix tau.factory.dogfood` resolves against the project's task path.
  @project_root File.cwd!()

  # ---------------------------------------------------------------------------
  # Sandbox helpers — a real working repo whose `origin` remote we control.
  # ---------------------------------------------------------------------------

  # A working repo with `origin` pointing at a NON-local network remote URL.
  # No network is touched: only `remote.origin.url` is read by the guard, which
  # must refuse before any fetch/push.
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

  # A working repo whose `origin` is a LOCAL bare repo on the filesystem —
  # the D-359-acceptable sandbox shape.
  defp repo_with_local_bare_origin do
    tmp = Briefly.create!(type: :directory)
    origin_path = Path.join(tmp, "origin.git")
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)

    work_path = Path.join(tmp, "work")
    {_, 0} = System.cmd("git", ["clone", origin_path, work_path])
    git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(work_path, "README"), "seed\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "seed"])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    {origin_path, work_path}
  end

  # Run `mix tau.factory.dogfood` as a real subprocess against `repo`, bounded
  # by `timeout_s` wall seconds (so the local-accept case cannot block on a full
  # factory boot). Returns {output, exit_code}. A timeout (124) means the guard
  # passed and the task proceeded past the precondition.
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
  # AC-13 / D-359 — a NON-LOCAL origin is hard-refused before boot.
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-359 — mix tau.factory.dogfood hard-refuses a non-local origin before booting" do
    for {label, url} <- [
          {"https", "https://github.com/smug-haus/tau.git"},
          {"git@/scp-syntax", "git@github.com:smug-haus/tau.git"},
          {"ssh", "ssh://git@github.com/smug-haus/tau.git"}
        ] do
      @tag :ac_13
      @tag :d_359
      test "AC-13 / D-359: a #{label} origin causes a hard refusal (non-zero exit) and the factory is NOT booted" do
        repo = repo_with_origin(unquote(url))

        {output, exit_code} = run_dogfood(repo, 1, 30)

        assert exit_code != 0,
               "AC-13 / D-359: mix tau.factory.dogfood MUST hard-refuse a non-local origin " <>
                 "(#{unquote(url)}) with a non-zero exit. Got exit 0. Output:\n#{output}"

        assert output =~ ~r/(non-local|local bare|refus|origin)/i,
               "AC-13 / D-359: the refusal MUST be explicit and name the non-local origin / " <>
                 "local-origin requirement. Output did not carry a refusal signal:\n#{output}"

        # The guard is a PRECONDITION: no Coordinator-bearing subtree is
        # assembled. The task ran in a subprocess, but its parent test process
        # must also never start a Coordinator as a side effect of the refusal.
        assert Process.whereis(@coordinator) == nil,
               "AC-13 / D-359: a non-local origin MUST be refused BEFORE the factory boots — " <>
                 "no Tau.Factory.Coordinator may exist. The guard is a precondition, not a " <>
                 "runtime classification."
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC-13 / D-359 — a LOCAL bare-repo origin PASSES the guard.
  # ---------------------------------------------------------------------------

  describe "AC-13 / D-359 — a local bare-repo origin passes the precondition guard" do
    @tag :ac_13
    @tag :d_359
    test "AC-13 / D-359: a local bare-repo origin is NOT refused by the local-origin guard" do
      {_origin_path, work_path} = repo_with_local_bare_origin()

      # Bound the run: the guard runs BEFORE boot, so within a few seconds we
      # either see the (forbidden) non-local refusal or the task has proceeded
      # past the precondition (timeout / boot). We assert the refusal is ABSENT.
      {output, _exit_code} = run_dogfood(work_path, 1, 8)

      refute output =~ ~r/non-local/i,
             "AC-13 / D-359: a LOCAL bare-repo origin MUST pass the guard — the task MUST NOT " <>
               "emit the non-local-origin refusal. Output:\n#{output}"
    end
  end
end

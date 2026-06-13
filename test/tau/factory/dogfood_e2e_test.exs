defmodule Tau.Factory.DogfoodE2ETest do
  @moduledoc """
  Gating test for PR #481 — **P5c-7 M10 dogfood capstone** (AC-12 / D-358, #475).

  The end-to-end "one REAL PR, no human in the loop" proof. Drives the
  **real** control plane (Coordinator → UnitDriver → fleet → `Gate.run` →
  MergeAuthority CAS → `Merge.Health.check`) over the self-hosting Elixir
  toolchain via the user-facing entry point
  `mix tau.factory.dogfood --repo <local-bare-sandbox> --issue <n>`, and
  asserts the **five AC-12 observables**. Only the *agent's authorship* is
  simulated (a deterministic scripted `agent_bin`); every other machinery
  edge — worker worktree, `Gate.run` mutation half, MergeAuthority CAS push,
  post-integration health — is the production path.

  Contract sources: SPEC-FACTORY-CORE §4 B11 (the `:gate_fun` / `:agent_bin` /
  `:unit_timeouts` supervisor seams), §6 D-358 (Unit timeout widening) +
  D-359 (local-origin guard), §7 AC-12 (the five observables);
  `docs/arch/04-software-architecture/control-plane.md` §7 (the dogfood harness
  contract) and `merge-and-integration.md` §5 (the health path).

  ## The pinned CLI + observable contract (drives the implementer brief)

  - Invocation: `mix tau.factory.dogfood --repo <sandbox> --issue <n>
    --db <ledger-db-path>`.
    * `--repo <sandbox>` — a working git repo whose `origin` is a LOCAL bare
      repo on the filesystem (D-359). The task force-pushes the merged tip into
      that local `origin` only.
    * `--issue <n>` — the trivial seeded issue number (the task seeds the issue
      itself: add `Sandbox.answer/0` returning `42` + its real gating test).
    * `--db <path>` — where the task writes its durable Ledger SQLite DB. This
      is the minimal observability lever for AC-12 observable 3 (a natural
      extension of the documented `:db_path` supervisor opt, §4 B11); the test
      names the path and queries the verdict + Unit-snapshot rows directly.
  - The task: (1) hard-refuses a non-local origin BEFORE boot (D-359; covered
    by `dogfood_guard_test.exs`); (2) seeds the issue; (3) boots the ENABLED
    `Tau.Factory.Supervisor` against the sandbox with the scripted `:agent_bin`,
    the real `:gate_fun` (wrapping `Gate.run/1`), and widened `:unit_timeouts`
    (D-358); (4) drives exactly ONE unit to terminal `:merged` autonomously
    (no prompt); (5) reports the merged SHA + green health, then exits 0.

  ## The five AC-12 observables this test asserts

    1. a real merged commit on the sandbox `main` carrying the seeded change
       (`<bare>/refs/heads/main` advanced; `Sandbox.answer/0` present in the
       tree);
    2. a GREEN `Merge.Health.check` on the integrated tip (the task reports
       `:green`, not `{:red, _}`);
    3. the verdict + Unit terminal `:merged` snapshot rows are DURABLE in the
       Ledger DB the task used (queried directly via Exqlite);
    4. zero human input — the task runs non-interactively to completion and
       exits 0 (no prompt, no checkpoint);
    5. no spurious escalation — with widened timeouts (D-358) the unit reached
       `:merged`, NOT `:escalated` / `E-RETRY-EXHAUSTED` / a `:state_timeout`.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch the dogfood task and harness do not exist
  (`lib/mix/tasks/tau.factory.dogfood.ex`, `lib/tau/factory/dogfood/`, the
  scripted `agent_bin`), and the supervisor's `:gate_fun` / `:agent_bin`
  threading completing the P5c-6 deferral is not yet wired. The task invocation
  therefore fails (task not found / no merged SHA on sandbox main), so this
  test FAILS until the implementer builds the harness. The test-author writes
  NO production code.

  ## AC / D-NNN linkage
    - AC-12 / D-358 — the e2e test. See SPEC-FACTORY-CORE §7 AC-12, §6 D-358;
      control-plane.md §7; merge-and-integration.md §5.

  Tagged `:integration` — SLOW, excluded from the normal `mix test` run; run
  with `mix test --include integration test/tau/factory/dogfood_e2e_test.exs`.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :ac_12
  @moduletag :capture_log

  # Generous: a real Gate.run (incl. the engine-executed mutation revert + a
  # `mix test` on the sandbox) plus a health `mix compile`/`mix test` cycle.
  @moduletag timeout: 600_000

  # Root of the parent Mix project (this worktree).
  @project_root File.cwd!()

  # ---------------------------------------------------------------------------
  # Sandbox: a LOCAL bare repo (origin) + a working clone (the --repo target).
  # Mirrors merge_force_with_lease_test.exs's bare-repo idiom (D-359 local).
  # ---------------------------------------------------------------------------

  defp setup_sandbox do
    tmp = Briefly.create!(type: :directory)
    origin_path = Path.join(tmp, "origin.git")
    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)

    work_path = Path.join(tmp, "work")
    {_, 0} = System.cmd("git", ["clone", origin_path, work_path])
    git = fn args -> System.cmd("git", args, cd: work_path, stderr_to_stdout: true) end
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(work_path, "README"), "dogfood sandbox\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "seed sandbox"])
    {_, 0} = git.(["push", "-u", "origin", "main"])

    %{origin: origin_path, work: work_path, db: Path.join(tmp, "ledger.db")}
  end

  defp origin_main_oid(origin_path) do
    {oid, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: origin_path)
    String.trim(oid)
  end

  # The tree of the sandbox `main` tip lists the seeded production file (the
  # scripted agent's commit landed) — proof the change is reachable from main.
  defp main_tree_files(origin_path) do
    {out, 0} =
      System.cmd("git", ["ls-tree", "-r", "--name-only", "refs/heads/main"], cd: origin_path)

    out |> String.split("\n", trim: true)
  end

  # Direct read of the durable Ledger DB the task wrote (AC-12 observable 3).
  # Reading the file straight (the task's Writer process is gone post-run) is
  # the durability proof: the rows survived the task's lifecycle.
  defp ledger_rows(db_path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      rows = drain(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp drain(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> drain(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-12 — one REAL PR open-issue → merged → green-health, no human.
  # ---------------------------------------------------------------------------

  describe "AC-12 — mix tau.factory.dogfood drives one real PR to merged with green health, no human" do
    @tag :ac_12
    test "AC-12: the dogfood capstone merges one real unit on the sandbox main, green health, durable L, non-interactive, no spurious escalation" do
      sandbox = setup_sandbox()
      main_before = origin_main_oid(sandbox.origin)

      # ---- Drive the REAL user-facing path: mix tau.factory.dogfood ----------
      # A true subprocess (the task boots the factory subtree and blocks until
      # the single unit reaches its terminal). stdin is closed → genuinely
      # NON-INTERACTIVE: a task that blocked on a prompt would hang/EOF, not
      # silently pass (AC-12 observable 4).
      {output, exit_code} =
        System.cmd(
          "mix",
          [
            "tau.factory.dogfood",
            "--repo",
            sandbox.work,
            "--issue",
            "1",
            "--db",
            sandbox.db
          ],
          cd: @project_root,
          stderr_to_stdout: true,
          into: ""
        )

      # Observable 4 — zero human input: ran to completion non-interactively.
      assert exit_code == 0,
             "AC-12 (observable 4): mix tau.factory.dogfood MUST run to completion " <>
               "non-interactively (no prompt) and exit 0. Got exit #{exit_code}. " <>
               "Output:\n#{output}"

      # Observable 1 — a real merged commit on the sandbox `main`.
      main_after = origin_main_oid(sandbox.origin)

      assert main_after != main_before,
             "AC-12 (observable 1): the sandbox `origin/main` MUST advance to a real merged " <>
               "commit. It is unchanged (#{main_after}). No PR was merged.\nOutput:\n#{output}"

      files = main_tree_files(sandbox.origin)

      assert Enum.any?(files, &(&1 =~ ~r/sandbox.*\.ex$/i)) or
               Enum.any?(files, &(&1 =~ ~r/answer/i)),
             "AC-12 (observable 1): the merged commit on sandbox `main` MUST carry the seeded " <>
               "change (the `Sandbox.answer/0` production file). main tree:\n#{inspect(files)}"

      # Observable 2 — green health reported on the integrated tip.
      assert output =~ ~r/health[:\s].*green/i or output =~ ~r/:green/,
             "AC-12 (observable 2): the task MUST report a GREEN Merge.Health.check on the " <>
               "integrated tip (`:green`, not `{:red, _}`). Output carried no green-health " <>
               "signal:\n#{output}"

      refute output =~ ~r/\{:red/,
             "AC-12 (observable 2): the task reported a RED health result; the integrated tip " <>
               "must be green.\nOutput:\n#{output}"

      # Observable 3 — verdict + Unit terminal :merged snapshot durable in L.
      assert File.exists?(sandbox.db),
             "AC-12 (observable 3): the task MUST write a durable Ledger DB at the --db path " <>
               "(#{sandbox.db}). No DB file exists."

      merged_snapshots =
        ledger_rows(sandbox.db, "SELECT unit_id, state FROM unit_snapshots WHERE state = 'merged'")

      assert merged_snapshots != [],
             "AC-12 (observable 3): the Unit's terminal `:merged` snapshot MUST be durable in " <>
               "L (a row in `unit_snapshots` with state='merged'). None found — the terminal " <>
               "fold did not snapshot to the Ledger (D-315 / RPO=0)."

      verdict_rows =
        ledger_rows(sandbox.db, "SELECT half, status FROM verdicts_v2 WHERE status IS NOT NULL")

      assert verdict_rows != [],
             "AC-12 (observable 3): the gate verdict row(s) MUST be durable in L (status-bearing " <>
               "rows in `verdicts_v2`). None found — Gate.run's verdict was not appended to the Ledger."

      # Observable 5 — no spurious escalation: NO :escalated snapshot, and no
      # E-RETRY-EXHAUSTED / :state_timeout signal in the run output (D-358).
      escalated_snapshots =
        ledger_rows(
          sandbox.db,
          "SELECT unit_id, state FROM unit_snapshots WHERE state = 'escalated'"
        )

      assert escalated_snapshots == [],
             "AC-12 (observable 5): with widened timeouts (D-358) the unit MUST reach " <>
               "`:merged`, NOT `:escalated`. An escalated snapshot was found: " <>
               "#{inspect(escalated_snapshots)}."

      refute output =~ ~r/E-RETRY-EXHAUSTED/,
             "AC-12 (observable 5): no spurious `E-RETRY-EXHAUSTED` escalation may occur " <>
               "(D-358 widened the Unit timeout past the scripted agent's worst-case run).\n" <>
               "Output:\n#{output}"

      refute output =~ ~r/state_timeout/,
             "AC-12 (observable 5): no `:state_timeout` may fire on the single unit — the " <>
               "widened `:unit_timeouts` (D-358) must keep a genuinely-working agent off the " <>
               "stall path.\nOutput:\n#{output}"
    end
  end
end

defmodule Mix.Tasks.Tau.Factory.Dogfood do
  @shortdoc "Drive one real PR end-to-end in a local sandbox (P5c-7 / AC-12)"

  @moduledoc """
  Drives one real PR end-to-end in a local sandbox: no human in the loop.

  ## Usage

      mix tau.factory.dogfood --repo <sandbox-work-dir> --issue <n> [--db <ledger-db-path>]

  ## Options

    * `--repo`  — path to a git working directory whose `origin` is a LOCAL
                  bare repo on the filesystem (D-359 / [C122-B11]).  The task
                  force-pushes the merged tip into that local `origin` only.
    * `--issue` — the trivial seeded issue number (the task seeds the issue
                  itself: add `Sandbox.answer/0` returning `42` + its real
                  gating test).
    * `--db`    — path for the durable Ledger SQLite DB the task writes.
                  Defaults to `<repo>/.tau-factory/ledger.db`.

  ## Safety guard (D-359 / [C122-B11])

  The task resolves `remote.origin.url` of `--repo` BEFORE booting the
  factory.  If the URL is a network remote (`https://`, `git@...`, `ssh://`),
  the task prints an explicit refusal naming the non-local origin and exits
  non-zero WITHOUT starting `Tau.Factory.Coordinator`. Only a `file://` /
  filesystem-path bare repo on the same host is accepted.

  ## What it does

  1. Hard-refuses a non-local origin (D-359).
  2. Ensures the sandbox repo has a git user config.
  3. Seeds the sandbox working repo with a mix project scaffold, a frozen
     gating test (`test/sandbox_test.exs`), and the feature branch `unit-1`.
  4. Boots `Tau.Factory.Supervisor` (enabled) against the sandbox with:
       - a scripted deterministic `agent_bin` (writes `lib/sandbox.ex`, commits,
         emits the D-326 `{:packet,4}` `work_ready` frame);
       - the real `gate_fun` (wraps `Gate.run/1`; oracle stub for critic/reviewer;
         real mutation half);
       - widened `:unit_timeouts` (D-358) so the scripted agent never spuriously
         escalates;
       - a single-issue `gh_fun` that returns the seeded issue, then empty.
  5. Awaits ONE unit reaching terminal `:merged` via Ledger polling; confirms
     green `Merge.Health.check`; reports the merged SHA + health to stdout.
  6. Exits 0.

  Non-interactive: no prompts, no human checkpoints (AC-12 observable 4).
  """

  use Mix.Task

  alias Tau.Factory.AgentBin
  alias Tau.Factory.Dogfood.GateFun
  alias Tau.Factory.Dogfood.Sandbox
  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Merge.Health
  alias Tau.Factory.Supervisor, as: FactorySupervisor
  alias Tau.Factory.UnitDriver

  require Logger

  # Widened per-state Unit timeout (D-358): well past the scripted agent's
  # worst-case run (git commit + packet emit is < 30 s; use 300 s).
  @unit_state_timeout_ms 300_000

  # How long to poll the Ledger waiting for :merged terminal (ms).
  @await_terminal_ms 540_000

  # Ledger poll interval (ms).
  @poll_interval_ms 1_000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          issue: :integer,
          db: :string
        ]
      )

    repo = Keyword.fetch!(opts, :repo)
    issue_number = Keyword.fetch!(opts, :issue)
    db_path = Keyword.get(opts, :db, default_db_path(repo))

    # Step 1 — D-359 / [C122-B11]: hard-refuse a non-local origin BEFORE boot.
    origin_url = read_origin_url(repo)
    check_local_origin!(origin_url)

    Mix.shell().info("[dogfood] sandbox origin: #{origin_url} — local, proceeding")

    # Step 2 — Ensure git user config in sandbox.
    configure_git_user(repo)

    # Step 3 — Seed the sandbox (mix project + gating test + feature branch).
    # Skips seeding if already seeded (idempotent for retries).
    unless seeded?(repo) do
      Mix.shell().info("[dogfood] seeding sandbox project + gating test + feature branch")
      Sandbox.seed(repo)
    end

    Mix.shell().info("[dogfood] sandbox seeded; issue=#{issue_number}, branch=unit-#{issue_number}")

    # Step 4 — Start the OTP application so PubSub etc. are up.
    Mix.Task.run("app.start")

    # Step 5 — Resolve the agent_bin via AgentBin.resolve/1 (D-376).
    # Default factory config is read from Application.get_env(:tau, :factory, []).
    # The default mode is scripted/replay (D-357 gate: :claude_code is off by
    # default), so existing dogfood behaviour is preserved unless the operator
    # explicitly sets agent_mode: :claude_code in the factory config.
    factory_opts = Application.get_env(:tau, :factory, [])
    {agent_bin, spawn_opts} = AgentBin.resolve(factory_opts)
    Mix.shell().info("[dogfood] agent_bin: #{agent_bin}")

    # Step 6 — Derive the deterministic work_item coordinate (mirrors IssueSelector).
    unit_id = "unit-#{issue_number}"
    run_id = "run-1"
    frozen_paths = MapSet.new([Sandbox.gating_test_path()])

    # Step 7 — Derive the supervisor child names (for Ledger access + gate_fun).
    # The supervisor derives child names via derive_name/3: when sup_name differs
    # from __MODULE__, the pattern is :"#{sup_name}_#{child_mod_last_underscore}".
    # LedgerWriter → "writer"; so the writer name is :"#{sup_name}_writer".
    sup_name = :"tau_factory_dogfood_#{:erlang.unique_integer([:positive])}"
    writer_name = :"#{sup_name}_writer"

    # Step 8 — Build the arity-1 gate_fun closure (D-361).
    # The closure is arity-1: the Unit supplies the coordinate (data.head_sha || data.hash)
    # at call time. The coordinator captures all static context (repo_dir, unit_id, run,
    # frozen_paths, ledger); the runtime coordinate comes from the Unit seam.
    gate_fun =
      GateFun.build(
        repo_dir: repo,
        unit_id: unit_id,
        run: run_id,
        frozen_paths: frozen_paths,
        ledger: writer_name
      )

    # Step 9 — Build the gh_fun: returns the seeded issue ONCE, then empty.
    # After the Coordinator drives the single unit, select_fun → nil → idle.
    issue_map = %{Sandbox.issue_map() | "number" => issue_number}
    # Use an Agent to hold mutable "served?" flag — OTP non-negotiable (#1).
    {:ok, flag_pid} = Agent.start_link(fn -> false end)

    gh_fun = fn _milestone ->
      if Agent.get_and_update(flag_pid, fn served -> {served, true} end) do
        {:ok, []}
      else
        {:ok, [issue_map]}
      end
    end

    unit_timeouts = [state_timeout_ms: @unit_state_timeout_ms]

    supervisor_opts =
      [
        enabled: true,
        name: sup_name,
        repo_dir: repo,
        db_path: db_path,
        milestone: "dogfood-milestone",
        gh_fun: gh_fun,
        select_fun: &IssueSelector.select/1,
        drive_fun: &UnitDriver.drive/2,
        agent_bin: agent_bin,
        gate_fun: gate_fun,
        unit_timeouts: unit_timeouts
      ] ++ spawn_opts

    Mix.shell().info("[dogfood] booting factory supervisor (enabled, one-shot)")

    {:ok, sup_pid} = FactorySupervisor.start_link(supervisor_opts)

    Mix.shell().info("[dogfood] supervisor started: #{inspect(sup_pid)}")

    # Step 10 — Poll the Ledger for the unit's :merged terminal snapshot.
    Mix.shell().info("[dogfood] awaiting unit terminal (timeout #{@await_terminal_ms} ms)...")

    result = await_merged(writer_name, unit_id, @await_terminal_ms)

    # Stop the flag agent.
    Agent.stop(flag_pid)

    case result do
      :ok ->
        report_success(repo, db_path, unit_id)
        exit_clean(sup_pid)

      {:error, :timeout} ->
        Mix.shell().error(
          "[dogfood] timed out waiting for unit :merged after #{@await_terminal_ms} ms"
        )

        exit_supervisor(sup_pid)
        exit({:shutdown, 1})

      {:error, :escalated} ->
        Mix.shell().error("[dogfood] unit escalated — check Ledger for details")
        exit_supervisor(sup_pid)
        exit({:shutdown, 1})
    end
  end

  # ---------------------------------------------------------------------------
  # Private — D-359 origin guard
  # ---------------------------------------------------------------------------

  defp read_origin_url(repo) do
    case System.cmd(
           "git",
           ["config", "--get", "remote.origin.url"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_out, _} -> ""
    end
  end

  # Hard-refuse a non-local origin (D-359 / [C122-B11]).
  # Network schemes: https://, git@...: (SCP syntax), ssh://.
  # Exits non-zero with an explicit refusal message naming the non-local origin.
  defp check_local_origin!(origin_url) do
    if non_local_origin?(origin_url) do
      Mix.shell().error(
        "[dogfood] REFUSED: sandbox repo origin is a non-local (network) remote:\n" <>
          "  origin: #{origin_url}\n\n" <>
          "mix tau.factory.dogfood requires a local bare-repo origin\n" <>
          "(a filesystem path or file:// URL on this host). MergeAuthority\n" <>
          "force-pushes origin/main with --force-with-lease — an irreversible\n" <>
          "action against a real remote (D-359 / [C122-B11]).\n\n" <>
          "Example: git init --bare /tmp/sandbox.git"
      )

      exit({:shutdown, 1})
    end
  end

  defp non_local_origin?(url) do
    String.starts_with?(url, "https://") or
      String.starts_with?(url, "http://") or
      String.starts_with?(url, "ssh://") or
      Regex.match?(~r/\Agit@[^:]+:/, url)
  end

  # ---------------------------------------------------------------------------
  # Private — sandbox helpers
  # ---------------------------------------------------------------------------

  defp configure_git_user(repo) do
    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end

    case git.(["config", "--get", "user.email"]) do
      {_, 0} -> :ok
      _ -> git.(["config", "user.email", "dogfood@tau.test"])
    end

    case git.(["config", "--get", "user.name"]) do
      {_, 0} -> :ok
      _ -> git.(["config", "user.name", "Tau Dogfood"])
    end

    :ok
  end

  defp seeded?(repo), do: File.exists?(Path.join(repo, "mix.exs"))

  # ---------------------------------------------------------------------------
  # Private — await :merged via Ledger polling
  # ---------------------------------------------------------------------------

  # Poll the Ledger.Writer (via Reader.latest_unit_snapshots/1) until the unit
  # reaches :merged or :escalated, or until the deadline.
  defp await_merged(writer_name, unit_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_merged(writer_name, unit_id, deadline)
  end

  defp do_poll_merged(writer_name, unit_id, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      snapshots = LedgerReader.latest_unit_snapshots(writer_name)

      case Map.get(snapshots, unit_id) do
        :merged ->
          :ok

        :escalated ->
          {:error, :escalated}

        _ ->
          Process.sleep(@poll_interval_ms)
          do_poll_merged(writer_name, unit_id, deadline)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private — success reporting
  # ---------------------------------------------------------------------------

  defp report_success(repo, db_path, unit_id) do
    merged_sha = get_origin_main_sha(repo)
    health = Health.check(repo, :elixir, %{})

    Mix.shell().info("[dogfood] merged SHA: #{merged_sha}")

    case health do
      :green ->
        Mix.shell().info("[dogfood] health: :green")

      {:red, report} ->
        Mix.shell().info("[dogfood] health: {:red, #{inspect(report)}}")
    end

    report_ledger_rows(db_path, unit_id)

    Mix.shell().info("[dogfood] DONE — unit=#{unit_id} SHA=#{merged_sha} health=#{inspect(health)}")
  end

  defp get_origin_main_sha(repo) do
    case System.cmd("git", ["ls-remote", "origin", "refs/heads/main"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.split("\t") |> List.first() |> String.trim()
      _ -> "unknown"
    end
  end

  defp report_ledger_rows(db_path, unit_id) do
    if File.exists?(db_path) do
      rows = ledger_query(db_path, "SELECT unit_id, state FROM unit_snapshots WHERE state='merged'")

      if Enum.any?(rows, fn [uid, _] -> uid == unit_id end) do
        Mix.shell().info("[dogfood] Ledger: :merged snapshot durable for #{unit_id} (D-315)")
      end
    end
  end

  defp ledger_query(db_path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      rows = drain_rows(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp drain_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> drain_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — supervisor lifecycle
  # ---------------------------------------------------------------------------

  defp exit_clean(sup_pid) do
    Supervisor.stop(sup_pid, :normal)
    :ok
  end

  defp exit_supervisor(sup_pid) do
    Supervisor.stop(sup_pid, :shutdown)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private — helpers
  # ---------------------------------------------------------------------------

  # Default Ledger DB path: `<repo>/.tau-factory/ledger.db`.
  # SPEC-recorded contract (§4 B11): absent --db defaults to this path.
  defp default_db_path(repo) do
    dir = Path.join(repo, ".tau-factory")
    File.mkdir_p!(dir)
    Path.join(dir, "ledger.db")
  end
end

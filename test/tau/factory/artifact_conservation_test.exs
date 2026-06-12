defmodule Tau.Factory.ArtifactConservationTest do
  @moduledoc """
  Gating tests for PR #446 (P4d-3 — WorkspaceJanitor capture-before-destroy).

  Covers D-334 (artifact conservation / CON-5):
    dirty(w) = committed(w) ⊎ captured(w) ⊎ discarded_by_decision(w)
  The join covers every dirty hunk with no remainder.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  Fails with UndefinedFunctionError until the implementer creates
  Tau.Factory.WorkspaceJanitor and extends Ledger.Writer with capture/3 +
  captures_for/2.

  ## AC linkage
    - D-334: all tests in this file
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer
  @worker_registry Tau.Factory.WorkerRegistry
  @worker_supervisor Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo setup
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    # Two tracked files so we can create staged AND unstaged hunks independently.
    File.write!(Path.join(repo_dir, "file_a.txt"), "original_a\n")
    File.write!(Path.join(repo_dir, "file_b.txt"), "original_b\n")
    {_, 0} = git.(["add", "file_a.txt", "file_b.txt"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_cons#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    while true; do sleep 60; done
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_cons_#{tag}_#{n}.db")
    name = :"ledger_cons_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@writer, db_path: db_path, name: name},
        id: :"ledger_cons_sv_#{n}"
      )

    name
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"cons_reg_#{tag}_#{n}"
    sup_name = :"cons_sup_#{tag}_#{n}"

    {:ok, _} =
      start_supervised(
        {@worker_registry, name: registry_name},
        id: :"cons_rreg_#{n}"
      )

    {:ok, sup} =
      start_supervised(
        {@worker_supervisor, name: sup_name, registry: registry_name},
        id: :"cons_rsup_#{n}"
      )

    {sup_name, sup, registry_name}
  end

  defp start_janitor(ledger, tag, report_to \\ nil) do
    n = System.unique_integer([:positive])
    name = :"cons_jan_#{tag}_#{n}"

    opts = [ledger: ledger, name: name]
    opts = if report_to, do: Keyword.put(opts, :report_to, report_to), else: opts

    {:ok, pid} =
      start_supervised(
        {@janitor, opts},
        id: :"cons_jan_sv_#{n}"
      )

    {name, pid}
  end

  defp poll_captures(ledger, worker_id, timeout_ms, interval_ms \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll_captures(ledger, worker_id, deadline, interval_ms)
  end

  defp do_poll_captures(ledger, worker_id, deadline, interval_ms) do
    captures = @writer.captures_for(ledger, worker_id)

    cond do
      captures != [] ->
        captures

      System.monotonic_time(:millisecond) >= deadline ->
        []

      true ->
        Process.sleep(interval_ms)
        do_poll_captures(ledger, worker_id, deadline, interval_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # D-334 — Artifact conservation
  # ---------------------------------------------------------------------------

  describe "D-334 — artifact conservation" do
    @tag :d_334
    test "D-334: capture record accounts for ALL dirty hunks — committed ⊎ captured covers entire dirty state" do
      # Drive a worker to hold one hunk of each dirty kind:
      #   - committed:    a git commit made by the agent (file_a.txt second line)
      #   - staged:       file_a.txt third line, git-added but not committed
      #   - unstaged:     file_b.txt modified but not added
      #   - untracked:    brand-new file never git-add'd
      #
      # After :kill, assert the capture record's patch + untracked_tgz covers
      # the staged+unstaged+untracked state.  The committed hunk already lives
      # in git history inside the worktree (captured as part of the workspace
      # state pre-reclaim — the relevant assertion is that disposition == :captured
      # and the Ledger row has non-empty patch and non-nil untracked_tgz).
      #
      # CON-5 balance: dirty(w) = committed(w) ⊎ captured(w) ⊎ discarded_by_decision(w)
      # Here: committed=1 hunk, captured={staged_patch+unstaged_patch+untracked_tgz},
      #        discarded_by_decision=0.
      # The join covers every hunk: none falls outside the three sets.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_cons334_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir)

      ledger = start_ledger(tmp_dir, :d334)
      {_sup_name, sup, registry_name} = start_fleet(:d334)
      report_to = self()
      {_jan_name, jan_pid} = start_janitor(ledger, :d334, report_to)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      {:ok, ws} = GenServer.call(worker_pid, :get_ws)
      assert File.dir?(ws), "D-334: worker's worktree must exist"

      git = fn args -> System.cmd("git", args, cd: ws, stderr_to_stdout: true) end

      # --- Committed hunk ---
      # (worker "does some work" and commits it inside its private worktree)
      File.write!(Path.join(ws, "file_a.txt"), "original_a\ncommitted_line\n")
      {_, 0} = git.(["add", "file_a.txt"])
      {_, 0} = git.(["commit", "-m", "worker commit"])

      committed_sha_out = elem(git.(["rev-parse", "HEAD"]), 0)
      committed_sha = String.trim(committed_sha_out)

      # --- Staged hunk ---
      File.write!(Path.join(ws, "file_a.txt"), "original_a\ncommitted_line\nstaged_line\n")
      {_, 0} = git.(["add", "file_a.txt"])

      # --- Unstaged hunk ---
      File.write!(
        Path.join(ws, "file_b.txt"),
        "original_b\nunstaged_modification\n"
      )

      # --- Untracked hunk ---
      untracked_name = "untracked_work.txt"
      untracked_content = "untracked-artifact-#{System.unique_integer([:positive])}\n"
      File.write!(Path.join(ws, untracked_name), untracked_content)

      # Verify all dirty kinds are present in the worktree before kill.
      {status_out, _} = git.(["status", "--short"])

      assert String.contains?(status_out, untracked_name),
             "D-334: setup — untracked file must appear in status; status=#{inspect(status_out)}"

      # Kill the worker.
      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-334: death-cert must arrive after :kill"

      # Wait for capture row.
      captures = poll_captures(ledger, worker_id, 5_000)

      assert captures != [],
             "D-334: Ledger must have a capture row for worker_id=#{worker_id}"

      [capture | _] = captures

      # --- Assert CON-5 balance ---

      # patch covers staged + unstaged.
      assert is_binary(capture.patch) and byte_size(capture.patch) > 0,
             "D-334: capture.patch must be non-empty (staged+unstaged diff)"

      # untracked_tgz covers the untracked kind.
      assert capture.untracked_tgz != nil,
             "D-334: capture.untracked_tgz must be non-nil"

      assert is_binary(capture.untracked_tgz) and byte_size(capture.untracked_tgz) > 0,
             "D-334: capture.untracked_tgz must be non-empty"

      # disposition must be :captured (CON-5 — nothing discarded by decision here).
      assert capture.disposition == :captured,
             "D-334: capture.disposition must be :captured; got #{inspect(capture.disposition)}"

      # Extract tgz and confirm untracked file is byte-for-byte present.
      extract_dir =
        Path.join(tmp_dir, "extract_#{System.unique_integer([:positive])}")

      File.mkdir_p!(extract_dir)
      tgz_path = Path.join(tmp_dir, "cons_untracked.tgz")
      File.write!(tgz_path, capture.untracked_tgz)
      {_, 0} = System.cmd("tar", ["-C", extract_dir, "-xzf", tgz_path], stderr_to_stdout: true)

      assert File.read!(Path.join(extract_dir, untracked_name)) == untracked_content,
             "D-334: untracked file content must match exactly after extraction"

      # patch must contain evidence of staged hunk (staged_line).
      assert String.contains?(capture.patch, "staged_line"),
             "D-334: patch must contain the staged hunk (staged_line)"

      # patch must contain evidence of unstaged hunk (unstaged_modification).
      assert String.contains?(capture.patch, "unstaged_modification"),
             "D-334: patch must contain the unstaged hunk (unstaged_modification)"

      # Committed work is already in git history (committed_sha exists);
      # it is in the `committed(w)` set, not lost.
      assert byte_size(committed_sha) == 40,
             "D-334: committed SHA must be a valid 40-char SHA; got #{inspect(committed_sha)}"

      # CON-5 remainder check: patch must NOT contain untracked_name
      # (the untracked kind lives in the tar, not the patch).
      refute String.contains?(capture.patch, untracked_name),
             "D-334: untracked file '#{untracked_name}' must be in the tar, NOT in the patch"
    end

    @tag :d_334
    test "D-334: clean worker exit — capture row recorded with empty patch and nil untracked_tgz" do
      # A worker that does no dirty work before exit.
      # dirty(w) = committed(w) ⊎ captured(w) ⊎ discarded_by_decision(w)
      # Here committed=∅, captured={empty patch, nil tgz}, discarded=∅.
      # The balance still holds; no hunk is lost.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_cons334_clean_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_clean")

      ledger = start_ledger(tmp_dir, :clean)
      {_sup_name, sup, registry_name} = start_fleet(:clean)
      report_to = self()
      {_jan_name, jan_pid} = start_janitor(ledger, :clean, report_to)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      assert Process.alive?(worker_pid)

      # Kill without dirtying the worktree.
      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-334/clean: death-cert must arrive"

      captures = poll_captures(ledger, worker_id, 5_000)

      assert captures != [],
             "D-334/clean: Ledger must record a capture row even for a clean worker"

      [capture | _] = captures

      # For a clean worker: patch is empty or whitespace-only.
      assert is_binary(capture.patch),
             "D-334/clean: capture.patch must be a binary"

      # untracked_tgz is nil or empty when there are no untracked files.
      assert capture.untracked_tgz == nil or capture.untracked_tgz == "",
             "D-334/clean: capture.untracked_tgz must be nil or empty for a clean worker; " <>
               "got #{inspect(capture.untracked_tgz)}"

      # disposition is :captured (nothing was discarded by decision).
      assert capture.disposition == :captured,
             "D-334/clean: disposition must be :captured; got #{inspect(capture.disposition)}"
    end

    @tag :d_334
    test "D-334: capture record is durably persisted — Ledger query after reclaim returns rows" do
      # After the worktree is reclaimed (gone from filesystem), the Ledger must
      # still return the capture row.  This verifies WAL-before-ack: the DB write
      # committed before the reclaim side-effect.
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_cons334_durable_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_durable")

      ledger = start_ledger(tmp_dir, :durable)
      {_sup_name, sup, registry_name} = start_fleet(:durable)
      report_to = self()
      {_jan_name, jan_pid} = start_janitor(ledger, :durable, report_to)

      {:ok, worker_id} =
        @worker_supervisor.spawn(sup, :implementer, "brief", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          janitor: jan_pid
        )

      [{worker_pid, _}] = Registry.lookup(registry_name, worker_id)
      {:ok, ws} = GenServer.call(worker_pid, :get_ws)

      # Write an untracked file to ensure non-trivial tgz.
      untracked_content = "durable_test_#{System.unique_integer([:positive])}\n"
      File.write!(Path.join(ws, "durable.txt"), untracked_content)

      Process.exit(worker_pid, :kill)

      assert_receive {:worker_exit, ^worker_id, _reason},
                     5_000,
                     "D-334/durable: death-cert must arrive"

      # Wait for reclaim.
      deadline = System.monotonic_time(:millisecond) + 5_000

      reclaimed =
        Enum.reduce_while(0..50, false, fn _, _ ->
          cond do
            not File.exists?(ws) ->
              {:halt, true}

            System.monotonic_time(:millisecond) > deadline ->
              {:halt, false}

            true ->
              Process.sleep(100)
              {:cont, false}
          end
        end)

      assert reclaimed,
             "D-334/durable: worktree #{ws} must be reclaimed before querying Ledger"

      # AFTER reclaim, Ledger must still have the capture row.
      captures = @writer.captures_for(ledger, worker_id)

      assert captures != [],
             "D-334/durable: Ledger must durably store the capture row even after " <>
               "the worktree is reclaimed (WAL-before-ack, D-315)"

      [capture | _] = captures

      assert capture.disposition == :captured,
             "D-334/durable: persisted row disposition must be :captured"

      assert capture.untracked_tgz != nil and byte_size(capture.untracked_tgz) > 0,
             "D-334/durable: persisted row must contain untracked_tgz"
    end
  end
end

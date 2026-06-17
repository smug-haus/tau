defmodule Tau.Factory.MergeRequestNonblockingTest do
  @moduledoc """
  Gating test for issue #602 — INV-MAI-1: request_merge must return :queued
  immediately without blocking for T_int.

  ## Invariant (INV-MAI-1)

  The `request_merge/2` call from a Unit FSM must return `:queued` immediately
  (non-blocking). It is FORBIDDEN to run any I/O-bound operation — in particular
  the `git fetch origin` inside `fetch_main_oid/1` — inside the gen_statem
  callback before the `{:reply, from, :queued}` action is returned.

  Source: SPEC-FACTORY-MERGE §3 [C206-B1], §4 B1, §4 B2 ("M's mailbox stays
  free for T_int"), §5 ("the build never runs in a handle_call").  The
  COMMIT-from issue evidence: `idle/3` -> `start_build/1` -> `fetch_main_oid/1`
  which executes `System.cmd("git", ["fetch", "origin"], ...)` synchronously
  before the `{:reply, from, :queued}` action is emitted.  A stalled `git fetch`
  (network congestion, slow remote) will hold the caller's `:gen_statem.call`
  until the default 5 s call timeout fires, violating the non-blocking contract.

  ## Fail-before validity (oracle separation)

  Against current production code (`merge_authority.ex`):
  - `idle/3` calls `start_build(data)` synchronously.
  - `start_build/1` calls `fetch_main_oid(data.repo_dir)` before launching the Task.
  - `fetch_main_oid/1` runs `System.cmd("git", ["fetch", "origin"], ...)`.
  - The test injects a git remote whose `git fetch` stalls indefinitely (a TCP
    listener that accepts connections but never sends git protocol data).
  - As a result, `request_merge/2` blocks well beyond the 500 ms assertion bound
    and the `Task.yield/2` call returns `nil` — the assertion FAILS.

  Against conformant code (fetch_main_oid moved into the async Task):
  - `idle/3` enqueues the unit and emits `{:reply, from, :queued}` immediately.
  - The Task then calls `fetch_main_oid` inside the off-mailbox build; the hang
    is contained inside the Task.
  - `request_merge/2` returns `:queued` well within 500 ms — assertion PASSES.

  ## D-NNN / AC linkage: INV-MAI-1, D-302 (non-blocking request_merge).
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :"INV-MAI-1"
  @moduletag :"D-302"

  @merge_authority Tau.Factory.MergeAuthority
  @writer Tau.Factory.Ledger.Writer

  # Maximum time (ms) request_merge is allowed to take.  Conformant code returns
  # in < 10 ms on any local machine; 500 ms is a generous bound that a stalled
  # git fetch (open TCP connection with no data) will trivially blow past.
  @nonblocking_deadline_ms 500

  # ---------------------------------------------------------------------------
  # Test support: TCP server that accepts connections but never sends data.
  #
  # We point the git remote at git://127.0.0.1:<port>/repo.git.  git-fetch over
  # the git:// protocol connects to the port and then waits for the server to
  # send the git-upload-pack pkt-line advertisement.  Since our server never
  # sends anything, git blocks indefinitely — simulating a stalled remote.
  # ---------------------------------------------------------------------------

  defp start_hanging_git_server do
    test_pid = self()

    spawn_link(fn ->
      {:ok, listen_sock} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, backlog: 10])

      {:ok, port} = :inet.port(listen_sock)
      send(test_pid, {:server_port, port})

      # Accept connections; hold each one without sending any git protocol data.
      accept_loop(listen_sock)
    end)

    receive do
      {:server_port, port} -> port
    after
      2_000 -> raise "hanging git server did not start"
    end
  end

  defp accept_loop(listen_sock) do
    case :gen_tcp.accept(listen_sock, 30_000) do
      {:ok, _conn} ->
        # Connection accepted; hold it without sending any data.
        # Git will block waiting for the git-upload-pack advertisement.
        accept_loop(listen_sock)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(listen_sock)
    end
  end

  # ---------------------------------------------------------------------------
  # Git repo helpers
  # ---------------------------------------------------------------------------

  defp git_work(work_path, args) do
    System.cmd("git", args, cd: work_path, stderr_to_stdout: true)
  end

  # Set up a local git repo with a unit branch, then replace the remote URL
  # with git://127.0.0.1:<port>/repo.git so that `git fetch origin` stalls.
  defp setup_repo_with_hanging_remote(tmp_dir, unit, hanging_port) do
    work_path = Path.join(tmp_dir, "work")
    origin_path = Path.join(tmp_dir, "origin.git")

    {_, 0} = System.cmd("git", ["init", "-b", "main", work_path])
    git_work(work_path, ["config", "user.email", "test@tau.test"])
    git_work(work_path, ["config", "user.name", "Tau Test"])

    File.write!(Path.join(work_path, "README"), "initial")
    git_work(work_path, ["add", "README"])
    {_, 0} = git_work(work_path, ["commit", "-m", "initial"])

    {_, 0} = System.cmd("git", ["init", "--bare", origin_path])
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: origin_path)
    git_work(work_path, ["remote", "add", "origin", origin_path])
    {_, 0} = git_work(work_path, ["push", "-u", "origin", "main"])

    # Create and push the unit feature branch to the local origin (seeds remote
    # tracking refs before we swap the URL to the hanging server).
    {_, 0} = git_work(work_path, ["checkout", "-b", unit.branch])
    File.write!(Path.join(work_path, "feature_#{unit.id}"), "feature")
    git_work(work_path, ["add", "."])
    {_, 0} = git_work(work_path, ["commit", "-m", "feature #{unit.id}"])
    {_, 0} = git_work(work_path, ["push", "origin", unit.branch])
    {_, 0} = git_work(work_path, ["checkout", "main"])

    # Swap the remote URL to the hanging TCP server.  Any subsequent
    # `git fetch origin` will stall waiting for git-upload-pack data.
    hanging_url = "git://127.0.0.1:#{hanging_port}/repo.git"
    {_, 0} = git_work(work_path, ["remote", "set-url", "origin", hanging_url])

    work_path
  end

  defp start_writer_with_pass_verdicts(unit) do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_mai1_writer_#{System.unique_integer([:positive])}"

    writer =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    for half <- [:critic, :reviewer] do
      {:ok, _} =
        @writer.append_verdict(writer, %{
          hash: unit.hash,
          run: unit.run,
          half: half,
          status: :pass,
          idempotency_key: "ikey-mai1-#{half}-#{System.unique_integer([:positive])}"
        })
    end

    writer
  end

  # ---------------------------------------------------------------------------
  # INV-MAI-1: request_merge must return :queued immediately even when
  # git fetch origin would stall (hanging TCP connection scenario).
  # ---------------------------------------------------------------------------

  describe "INV-MAI-1 - request_merge is non-blocking even under a stalled git fetch" do
    @tag :"INV-MAI-1"
    @tag :"D-302"
    test "INV-MAI-1 / D-302: request_merge returns :queued within #{@nonblocking_deadline_ms}ms when git fetch origin stalls" do
      tmp_dir = Briefly.create!(type: :directory)

      unit = %{
        id: "u-inv-mai-1-#{System.unique_integer([:positive])}",
        hash: "hash-inv-mai-1-#{System.unique_integer([:positive])}",
        run: "run-inv-mai-1",
        branch: "feat/inv-mai-1"
      }

      # 1. Start a TCP server that accepts connections but never sends data,
      #    simulating a git remote whose `git fetch` stalls indefinitely.
      hanging_port = start_hanging_git_server()

      # 2. Set up a git repo where `git fetch origin` will stall.
      work_path = setup_repo_with_hanging_remote(tmp_dir, unit, hanging_port)

      writer = start_writer_with_pass_verdicts(unit)

      ma_name = :"test_ma_inv_mai1_#{System.unique_integer([:positive])}"
      tasks_name = :"test_ma_tasks_inv_mai1_#{System.unique_integer([:positive])}"

      # A build_fun that signals the test when invoked (inside the Task).
      # We only care that request_merge itself returns fast; the Task may stall
      # on git fetch — that is expected but contained inside the Task.
      test_pid = self()

      build_fun = fn _units, _base ->
        send(test_pid, :build_fun_invoked)
        {:built, [], "base", "tip"}
      end

      ma_pid =
        start_supervised!(
          {@merge_authority,
           name: ma_name,
           ledger: writer,
           repo_dir: work_path,
           required_halves: [:critic, :reviewer],
           tasks_name: tasks_name,
           build_fun: build_fun},
          id: ma_name
        )

      # 3. Fire request_merge in an async task with a tight deadline.
      #    Conformant code: returns :queued in < 10 ms (before git fetch runs).
      #    Non-conformant code: blocks for the git connect timeout (~seconds)
      #    before returning — will not return within @nonblocking_deadline_ms ms.
      caller =
        Task.async(fn ->
          t0 = System.monotonic_time(:millisecond)
          result = @merge_authority.request_merge(ma_pid, unit)
          t1 = System.monotonic_time(:millisecond)
          {result, t1 - t0}
        end)

      # 4. Allow @nonblocking_deadline_ms ms for request_merge to return.
      outcome = Task.yield(caller, @nonblocking_deadline_ms)

      # Clean up regardless of result.
      Task.shutdown(caller, :brutal_kill)

      assert outcome != nil,
             "INV-MAI-1 / D-302: request_merge did not return within " <>
               "#{@nonblocking_deadline_ms}ms — " <>
               "MergeAuthority.idle/3 is blocking on fetch_main_oid/git-fetch " <>
               "inside the gen_statem callback before emitting {:reply, from, :queued}. " <>
               "fetch_main_oid must run inside the async Task (off-mailbox), " <>
               "not in the idle/3 callback. " <>
               "SPEC-FACTORY-MERGE §3 [C206-B1] + §4 B1/B2."

      case outcome do
        {:ok, {result, elapsed_ms}} ->
          assert result == :queued,
                 "INV-MAI-1: request_merge must return :queued; got #{inspect(result)}"

          assert elapsed_ms < @nonblocking_deadline_ms,
                 "INV-MAI-1: request_merge took #{elapsed_ms}ms; must be < #{@nonblocking_deadline_ms}ms"

        nil ->
          # Already handled by the assert above; unreachable but explicit.
          :noop
      end
    end
  end
end

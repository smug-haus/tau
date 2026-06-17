defmodule Tau.Factory.SupervisorWatchdogWiringTest do
  @moduledoc """
  Gating test for D-379(b) producer half — supervisor.ex deps-map wiring
  (issue #629, D-379 PARTIAL verdict).

  ## Invariant under test

  **D-379(b):** `UnitDriver.drive/2` registers each spawned worker with the
  fleet `Watchdog` (`Watchdog.register(watchdog, worker_id, worker_pid,
  unit_pid, heartbeat_timeout: …)`), so that heartbeat absence fires
  `{:worker_stalled, worker_id}` to the owning Unit (SPEC-FACTORY-CORE §D-379
  producer half).

  The Watchdog has `heartbeat_timeout` and the Unit has `state_timeout_ms`,
  both derived from the same `:unit_timeouts` threshold so the two
  heartbeat-absence detectors cannot disagree.

  ## The bug (D-379 PARTIAL, issue #629)

  `supervisor.ex:218-245` assembles the `deps` map without a `:watchdog` key:

  ```elixir
  deps = %{
    unit_supervisor: ..., scheduler: ..., worker_supervisor: ..., ...
    # NO :watchdog key
  }
  ```

  The Watchdog IS started as a child (supervisor.ex:282) but its derived name
  is never placed into `deps`. When `UnitDriver.drive/2` is called via
  `wrapped_drive_fun`, it receives `unit_deps` with `watchdog: nil` (via
  `Map.get(deps, :watchdog)` → nil), and the `if watchdog do` guard at
  unit_driver.ex:249 is never entered — `Watchdog.register/5` is never called.

  ## How this test gates the fix

  The test starts `Tau.Factory.Supervisor` with `enabled: true` and a
  **custom `drive_fun` seam** that captures the `unit_deps` map passed to it
  by `wrapped_drive_fun` and forwards it to the test process for inspection.

  This is the correct test boundary: `wrapped_drive_fun` in supervisor.ex calls
  `drive_fun.(unit_work_item, unit_deps)` — the `unit_deps` map is exactly the
  deps the supervisor assembled (with `:watchdog` added after the fix). By
  inspecting `unit_deps` at this seam we verify the supervisor's deps-map
  construction, which is the precise location of the bug.

  ## Fail-before validity

  FAIL-BEFORE (pre-fix): `unit_deps` received by `drive_fun` does NOT contain
  `:watchdog` (the key is absent) → `assert Map.has_key?(unit_deps, :watchdog)`
  fails → test is red.

  PASS-AFTER (post-fix): supervisor adds `:watchdog => watchdog_name` to the
  `deps` map at supervisor.ex:218-245 → `unit_deps` received by `drive_fun`
  contains `:watchdog` → assertion passes → test is green.

  Additionally, the test asserts `unit_deps[:heartbeat_timeout_ms]` is absent
  (the supervisor uses `:unit_timeouts`-based derivation, not a hardcoded
  override) — the watchdog timeout MUST be derived from `:unit_timeouts` so
  both detectors share ONE threshold (D-379 dual-detector agreement).

  ## AC / D-NNN linkage

  - D-379 — the invariant id appears in the test name, @tag, and @moduletag.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_379

  @supervisor Tau.Factory.Supervisor

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  defp setup_git_repo do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "tau_sup_wd_wiring_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    repo_dir = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo_dir)

    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])

    repo_dir
  end

  # -------------------------------------------------------------------------
  # D-379 — supervisor deps-map wiring test
  # -------------------------------------------------------------------------

  describe "D-379(b) — Tau.Factory.Supervisor with enabled: true threads :watchdog into drive_fun's deps" do
    @tag :d_379
    test "D-379(b): supervisor's wrapped_drive_fun passes :watchdog in unit_deps to drive_fun (supervisor.ex deps-map wiring)" do
      repo_dir = setup_git_repo()

      db_path =
        Path.join(
          System.tmp_dir!(),
          "sup_wd_wiring_#{System.unique_integer([:positive])}.db"
        )

      on_exit(fn -> File.rm_rf!(db_path) end)
      sup_name = :"factory_sup_d379b_#{System.unique_integer([:positive])}"

      test_pid = self()

      # A select_fun that produces ONE work_item (a no-op issue), then nil.
      # This causes the Coordinator to call drive_fun once and then idle.
      # The work_item format is {issue_map, scope_map, hash, branch}.
      driven = :counters.new(1, [:atomics])

      select_fun = fn _scheduler ->
        if :counters.get(driven, 1) == 0 do
          :counters.add(driven, 1, 1)

          scope = %{
            deps: [],
            files: MapSet.new(),
            codepoints: MapSet.new(),
            specs: MapSet.new(),
            resources: MapSet.new()
          }

          {%{"number" => 629, "title" => "D-379 wiring test"}, scope, "hash-d379b", "feat/d379b"}
        else
          nil
        end
      end

      # A custom drive_fun that captures the unit_deps it receives and sends them
      # to the test process. The wrapped_drive_fun in supervisor.ex calls
      # `drive_fun.(unit_work_item, unit_deps)` — so this seam sees the EXACT
      # deps the supervisor assembled (post-`:watchdog`-addition, if fixed).
      # Returns a fake pid so the Coordinator can track the unit in-flight.
      fake_unit_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          after
            10_000 -> :ok
          end
        end)

      capture_drive_fun = fn _work_item, unit_deps ->
        send(test_pid, {:captured_unit_deps, unit_deps})
        fake_unit_pid
      end

      sup_pid =
        start_supervised!(
          {
            @supervisor,
            enabled: true,
            db_path: db_path,
            name: sup_name,
            repo_dir: repo_dir,
            milestone: "d379b-test",
            gh_fun: fn _milestone -> {:ok, []} end,
            select_fun: select_fun,
            drive_fun: capture_drive_fun
          },
          id: sup_name
        )

      assert is_pid(sup_pid),
             "D-379(b): Tau.Factory.Supervisor must start with enabled: true"

      # Wait for the Coordinator to call drive_fun with the work_item.
      # The Coordinator loops via {:next_event, :internal, :loop} — give it
      # enough time to call select_fun and then drive_fun once.
      assert_receive {:captured_unit_deps, unit_deps},
                     5_000,
                     "D-379(b): Tau.Factory.Supervisor's Coordinator must call drive_fun " <>
                       "with the assembled unit_deps within 5000 ms. The drive_fun was " <>
                       "never called — either the Coordinator did not reach :running, " <>
                       "select_fun was not called, or the wrapped_drive_fun raised."

      # CORE ASSERTION: unit_deps must contain :watchdog so UnitDriver.drive/2 can
      # register each spawned worker with the Watchdog.
      #
      # FAIL-BEFORE (issue #629 / D-379 PARTIAL): supervisor.ex:218-245 assembles
      # `deps` without a `:watchdog` key. `wrapped_drive_fun` merges deps with
      # `%{deps | report_to: self(), unit_timeouts: unit_timeouts}` — this merge
      # does NOT add :watchdog (the key must be present in the base `deps` map).
      # Therefore `unit_deps` arrives at `drive_fun` with no :watchdog key.
      # This assertion fails → the test is red → the implementer must add
      # `:watchdog => watchdog_name` to `deps` in `supervisor.ex:init_full_subtree/1`.
      assert Map.has_key?(unit_deps, :watchdog),
             "D-379(b): Tau.Factory.Supervisor's wrapped_drive_fun MUST include " <>
               ":watchdog in the unit_deps it passes to drive_fun. " <>
               "Got unit_deps keys: #{inspect(Map.keys(unit_deps) |> Enum.sort())}. " <>
               "FAIL-BEFORE (issue #629 / D-379 PARTIAL): supervisor.ex:218-245 builds " <>
               "the deps map without a :watchdog key. The Watchdog is started as a child " <>
               "(supervisor.ex:282) but its derived name is never inserted into the deps " <>
               "map, so UnitDriver.drive/2 sees `watchdog = Map.get(deps, :watchdog) == nil` " <>
               "and the `if watchdog do` registration block (unit_driver.ex:249) is never " <>
               "entered — no worker is ever registered with the Watchdog."

      watchdog_val = unit_deps[:watchdog]

      assert is_atom(watchdog_val) and watchdog_val != nil,
             "D-379(b): :watchdog in unit_deps must be a non-nil atom (the derived " <>
               "Watchdog registered name); got #{inspect(watchdog_val)}. " <>
               "The Watchdog name is derived via `derive_name(sup_name, __MODULE__, Watchdog)` " <>
               "in init_full_subtree/1."

      # Verify the Watchdog process is alive under the threaded name.
      assert Process.whereis(watchdog_val) != nil,
             "D-379(b): the :watchdog value threaded into deps (#{inspect(watchdog_val)}) " <>
               "must be a live registered process. Got nil — the Watchdog was not started " <>
               "or was started under a different name."

      # The supervisor must derive heartbeat_timeout from :unit_timeouts (shared
      # threshold invariant — D-379 dual-detector agreement). If :heartbeat_timeout_ms
      # is absent from unit_deps, UnitDriver derives it from unit_timeouts (correct).
      # If it IS present it must equal unit_timeouts[:state_timeout_ms] (same source).
      unit_timeouts = unit_deps[:unit_timeouts] || []
      state_timeout_ms = Keyword.get(unit_timeouts, :state_timeout_ms)

      if Map.has_key?(unit_deps, :heartbeat_timeout_ms) do
        assert unit_deps[:heartbeat_timeout_ms] == state_timeout_ms,
               "D-379(b) dual-detector agreement: :heartbeat_timeout_ms in unit_deps " <>
                 "(#{inspect(unit_deps[:heartbeat_timeout_ms])}) MUST equal " <>
                 "unit_timeouts[:state_timeout_ms] (#{inspect(state_timeout_ms)}) so both " <>
                 "detectors share ONE threshold (D-379 dual-detector agreement invariant)."
      end
    end
  end
end

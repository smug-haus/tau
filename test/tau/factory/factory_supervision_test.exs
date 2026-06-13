defmodule Tau.Factory.FactorySupervisionTest do
  @moduledoc """
  Gating test for PR #480 — **P5c-6 production supervision** (AC-P5c6, #474).

  Pins the **config-gated full-subtree assembly**: `Tau.Factory.Supervisor`
  starts the entire factory control subtree — Ledger → Budget.Owner →
  Scheduler → MergeAuthority → UnitRegistry/UnitSupervisor → KillSwitch →
  Coordinator (LAST) — wired with the REAL seams
  (`select_fun = Tau.Factory.IssueSelector.select/1`,
  `drive_fun = Tau.Factory.UnitDriver.drive/2`, `:ledger` = the started writer)
  **only when the factory is enabled**, and starts NOTHING (no Coordinator,
  no uncontrolled work) on a normal default boot.

  ## The config-gating seam this test pins (drives the implementer brief)

  The factory subtree is gated on `config :tau, :factory, enabled: false`
  (the default). The testable seam is `Tau.Factory.Supervisor.start_link/1`:
  the supervisor consults the gating decision and, **when enabled**, assembles
  the full Coordinator-bearing subtree threading the real seams from its opts;
  when NOT enabled (the default), it assembles no Coordinator subtree
  (today's ledger-only behaviour).

  An `enabled: true` opt to `start_link/1` requests the gated full-subtree
  assembly for a single isolated test instance (tmp-dir DB + throwaway git
  repo), so the assembly can be exercised without booting the whole app and
  without touching the application-started instance. The real `select_fun`
  is wired against a no-issues `:gh_fun` (NO network in tests) so the
  Coordinator IDLES — `select_fun → nil` — and drives no uncontrolled work.

  ## Fail-before validity (oracle separation, factory-loop §4b)

  On THIS branch `Tau.Factory.Supervisor` has NO `enabled`-gated full-subtree
  path: passing `enabled: true` (without hand-threading `coordinator_opts`)
  starts NO Coordinator (`maybe_add_coordinator(children, nil, …)`), so
  **Test A's** lookup of the Coordinator child fails / `:sys.get_state` cannot
  reach `:running` via the real assembly. The config-gated subtree assembly
  does not yet exist — Test A fails until the implementer wires it (#474).
  **Test B** asserts the default-OFF safety property and may pass trivially
  today (nothing starts a Coordinator on default boot); it is the regression
  guard for "no uncontrolled work on normal boot".

  ## AC / D-NNN linkage
    - AC-P5c6 — every test in this file (config-gated subtree assembly;
      default OFF). See #474 / SPEC-FACTORY-CORE §5 (Coordinator `running`);
      docs/arch/04-software-architecture/supervision-tree.md (tree composition,
      Coordinator started LAST, rest_for_one spine).
  """

  use ExUnit.Case, async: false

  @moduletag :ac_p5c6
  @moduletag :capture_log

  @supervisor Tau.Factory.Supervisor
  @coordinator Tau.Factory.Coordinator
  @issue_selector Tau.Factory.IssueSelector
  @unit_driver Tau.Factory.UnitDriver

  # ---------------------------------------------------------------------------
  # Throwaway git repo (mirrors merge_result_pubsub_test.exs / unit_driver_test.exs)
  # ---------------------------------------------------------------------------

  defp setup_git_repo do
    repo_dir = Briefly.create!(type: :directory)

    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])

    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])

    repo_dir
  end

  # Walk the supervisor's children for the Coordinator child (the derived name
  # is internal; identify it by the module reported in the child spec).
  defp coordinator_child(sup_pid) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {_id, pid, :worker, mods} when is_pid(pid) ->
        if @coordinator in List.wrap(mods), do: pid, else: nil

      _ ->
        nil
    end)
  end

  defp child_pids_of(sup_pid, target_mod) do
    sup_pid
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, mods} when is_pid(pid) ->
        if target_mod in List.wrap(mods), do: [pid], else: []

      _ ->
        []
    end)
  end

  # ---------------------------------------------------------------------------
  # AC-P5c6, Test A — ENABLED: the full subtree assembles; Coordinator reaches
  # :running and IDLES (select_fun → nil); no Unit spawned, no merge requested.
  # ---------------------------------------------------------------------------

  describe "AC-P5c6 — config-gated factory subtree starts the Coordinator at :running and idles" do
    @tag :ac_p5c6
    test "AC-P5c6: with the factory enabled, the subtree assembles and the Coordinator reaches :running and idles (no uncontrolled work)" do
      repo_dir = setup_git_repo()
      db_path = Briefly.create!(extname: ".db")
      sup_name = :"factory_sup_p5c6_#{System.unique_integer([:positive])}"

      # The real select_fun: IssueSelector against a no-issues gh_fun so the
      # Coordinator IDLES (select_fun → nil) without driving uncontrolled work.
      no_issues_gh_fun = fn _milestone -> {:ok, []} end

      sup_pid =
        start_supervised!(
          {
            @supervisor,
            enabled: true,
            db_path: db_path,
            name: sup_name,
            repo_dir: repo_dir,
            milestone: "p5c6-test-milestone",
            gh_fun: no_issues_gh_fun,
            select_fun: &@issue_selector.select/1,
            drive_fun: &@unit_driver.drive/2
          },
          id: sup_name
        )

      assert is_pid(sup_pid), "AC-P5c6: Tau.Factory.Supervisor must start"

      # The Coordinator is a child of the assembled subtree.
      coord_pid = coordinator_child(sup_pid)

      assert is_pid(coord_pid),
             "AC-P5c6: with the factory enabled, Tau.Factory.Supervisor MUST assemble the " <>
               "full subtree INCLUDING a Tau.Factory.Coordinator child (started LAST per " <>
               "supervision-tree.md). No Coordinator child was found — the config-gated " <>
               "full-subtree assembly is absent."

      # The Coordinator reaches and holds :running (gen_statem state_functions:
      # :sys.get_state returns {state_name, data}).
      {state_name, _data} = :sys.get_state(coord_pid)

      assert state_name == :running,
             "AC-P5c6: the Coordinator must reach :running via the real assembly; got " <>
               "#{inspect(state_name)}. SPEC-FACTORY-CORE §5: `running` is the loop entry " <>
               "(start = resume from L)."

      # IDLE PROPERTY: select_fun → nil (no open issues in the sandbox), so the
      # Coordinator drives NO uncontrolled work. After the loop settles there is
      # no in-flight unit.
      Process.sleep(200)

      {state_name_after, data_after} = :sys.get_state(coord_pid)

      assert state_name_after == :running,
             "AC-P5c6: the Coordinator must IDLE in :running when select_fun → nil; got " <>
               "#{inspect(state_name_after)}."

      assert Map.get(data_after, :in_flight) == nil,
             "AC-P5c6: an idle Coordinator (select_fun → nil) must hold no in-flight unit; " <>
               "in_flight = #{inspect(Map.get(data_after, :in_flight))}. A non-nil in_flight " <>
               "means it drove uncontrolled work on boot — the safety property is violated."

      # No Unit was spawned: every UnitSupervisor in the subtree has no children.
      unit_sup_pids = child_pids_of(sup_pid, Tau.Factory.UnitSupervisor)

      for unit_sup_pid <- unit_sup_pids do
        assert DynamicSupervisor.count_children(unit_sup_pid).active == 0,
               "AC-P5c6: an idle Coordinator must spawn NO Unit; the UnitSupervisor has " <>
                 "active children — uncontrolled work was driven on boot."
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC-P5c6, Test B — DEFAULT OFF: no Coordinator on a normal boot (the safety
  # property — no uncontrolled work on normal startup).
  # ---------------------------------------------------------------------------

  describe "AC-P5c6 — default config leaves the factory OFF (no Coordinator on normal boot)" do
    @tag :ac_p5c6
    test "AC-P5c6: with the default config (factory disabled), no Tau.Factory.Coordinator is started on normal boot" do
      # The application boots with `config :tau, :factory, enabled: false`
      # (the default). The application-started factory subtree therefore starts
      # NO Coordinator — the safety property: no uncontrolled work on normal
      # boot. The canonical Coordinator name is unregistered.
      assert Process.whereis(@coordinator) == nil,
             "AC-P5c6: on a default boot the factory MUST be OFF — no " <>
               "Tau.Factory.Coordinator process may exist. A registered Coordinator means " <>
               "the factory started uncontrolled on normal boot (the default-OFF safety " <>
               "property is violated)."
    end
  end
end

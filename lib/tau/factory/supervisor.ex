defmodule Tau.Factory.Supervisor do
  @moduledoc """
  Supervision subtree for the factory control components.

  ## Config-gated assembly (P5c-6, #474; D-357, [C120-B11])

  When `enabled: false` (the default, read from `config :tau, :factory,
  enabled: false`), the supervisor starts only the `Tau.Factory.Ledger.Writer`
  — no Coordinator-bearing subtree is assembled. `Process.whereis(Tau.Factory.Coordinator)`
  is `nil`; no uncontrolled work is driven on a normal boot (D-357).

  When `enabled: true`, the supervisor assembles the full control subtree in
  the `docs/arch/04-software-architecture/supervision-tree.md` §3 order, with
  the Coordinator started LAST (it depends on every sibling — D-344 resume
  reads the started Ledger; its seams reference the started fleet/merge/registry
  processes). The `:rest_for_one` strategy is used for the full spine: if
  `Ledger.Writer` crashes, everything downstream restarts.

  ## Option surface (`start_link/1`, B11)

  High-level seams only. The supervisor **derives** every per-child opt; the
  caller does NOT hand-thread per-child opts:

    - `:enabled`   — boolean; request the gated full-subtree assembly (defaults
                     to `Application.get_env(:tau, :factory, [])[:enabled]`).
    - `:db_path`   — path to the SQLite ledger DB (test: tmp-dir DB).
    - `:name`      — atom; this supervisor's registered name (test isolation;
                     per-supervisor child names are derived from it).
    - `:repo_dir`  — the real (or throwaway) git repo; threaded to
                     MergeAuthority and the worker fleet.
    - `:milestone` — the assigned milestone string (→ IssueSelector).
    - `:gh_fun`    — `(String.t() -> {:ok, [issue_map()]})`; stubbable issue
                     source (NO network in tests).
    - `:select_fun` — `&IssueSelector.select/1`; arity-1 opts-taking seam.
    - `:drive_fun`  — `&UnitDriver.drive/2`; arity-2 seam.

  See `docs/spec/SPEC-FACTORY-CORE.md` §4 B11, D-357; and
  `docs/arch/04-software-architecture/supervision-tree.md` §3.
  """

  use Supervisor

  alias Tau.Factory.BriefAssembler
  alias Tau.Factory.Budget.Owner, as: BudgetOwner
  alias Tau.Factory.Fleet.Watchdog
  alias Tau.Factory.KillSwitch
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.Merge.RepoDirRegistry
  alias Tau.Factory.MergeAuthority
  alias Tau.Factory.Scheduler
  alias Tau.Factory.UnitRegistry
  alias Tau.Factory.UnitSupervisor
  alias Tau.Factory.WorkerRegistry
  alias Tau.Factory.WorkerSupervisor
  alias Tau.Factory.WorkspaceJanitor

  @doc """
  Start the factory supervisor (called by `Tau.Application` or tests).

  Options:
    - `:enabled`   — boolean; request the full-subtree assembly. Defaults to
                     `Application.get_env(:tau, :factory, [])[:enabled]`.
    - `:db_path`   — path to the SQLite ledger DB file (required when not using
                     the application default).
    - `:name`      — registered name for this supervisor (defaults to
                     `__MODULE__`). Child names are derived from it.
    - `:repo_dir`  — git repo path (full subtree only; threaded to
                     MergeAuthority and WorkerSupervisor).
    - `:milestone` — the assigned milestone (full subtree only).
    - `:gh_fun`    — issue-source adapter (full subtree only; stubbable).
    - `:select_fun` — `&IssueSelector.select/1` (full subtree only).
    - `:drive_fun`  — `&UnitDriver.drive/2` (full subtree only).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    sup_name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  @impl true
  def init(opts) do
    # Resolve :enabled from opts, falling back to the application config gate.
    enabled =
      Keyword.get_lazy(opts, :enabled, fn ->
        Application.get_env(:tau, :factory, []) |> Keyword.get(:enabled, false)
      end)

    if enabled do
      init_full_subtree(opts)
    else
      init_ledger_only(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — ledger-only path (default / disabled factory)
  # ---------------------------------------------------------------------------

  # Assembles only the Ledger.Writer (and optional existing per-test children
  # that the legacy non-enabled tests wire via coordinator_opts / budget_opts
  # / etc.). This preserves backward compat with existing tests that do NOT
  # pass `enabled: true` but still hand-thread coordinator_opts etc.
  defp init_ledger_only(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())
    sup_name = Keyword.get(opts, :name, __MODULE__)
    repo_dir = Keyword.get(opts, :repo_dir)
    required_halves = Keyword.get(opts, :required_halves, [:mutation, :critic, :reviewer])
    merge_authority_opts = Keyword.get(opts, :merge_authority_opts, [])
    budget_opts = Keyword.get(opts, :budget_opts)
    scheduler_opts = Keyword.get(opts, :scheduler_opts)
    kill_switch_opts = Keyword.get(opts, :kill_switch_opts)
    coordinator_opts = Keyword.get(opts, :coordinator_opts)

    writer_name = derive_name(sup_name, __MODULE__, LedgerWriter)

    tasks_name = derive_name(sup_name, __MODULE__, Tau.Factory.MergeTasks)

    ma_name = derive_name(sup_name, __MODULE__, MergeAuthority)

    unit_registry_name = derive_name(sup_name, __MODULE__, UnitRegistry)

    unit_supervisor_name = derive_name(sup_name, __MODULE__, UnitSupervisor)

    ks_name = derive_name(sup_name, __MODULE__, KillSwitch)

    coord_name = derive_name(sup_name, __MODULE__, Tau.Factory.Coordinator)

    base_children = [
      {LedgerWriter, db_path: db_path, name: writer_name},
      {Task.Supervisor, name: tasks_name}
    ]

    unit_opts = Keyword.get(opts, :unit_opts)

    children =
      base_children
      |> maybe_add_budget_owner(budget_opts, writer_name)
      |> maybe_add_scheduler(scheduler_opts, budget_opts)
      |> maybe_add_merge_authority(
        repo_dir,
        ma_name,
        writer_name,
        tasks_name,
        required_halves,
        merge_authority_opts
      )
      |> maybe_add_unit_subsystem(unit_opts, unit_registry_name, unit_supervisor_name)
      |> maybe_add_kill_switch(kill_switch_opts, ks_name, sup_name)
      |> maybe_add_coordinator(coordinator_opts, coord_name, ks_name, sup_name)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private — full subtree assembly (enabled path, B11, D-357)
  # ---------------------------------------------------------------------------

  # Assembles the full control subtree in supervision-tree.md §3 order with
  # :rest_for_one strategy. The Coordinator is started LAST (D-344, B11).
  # select_fun (arity-1) and drive_fun (arity-2) are wrapped into the
  # Coordinator's arity-0/arity-1 forms; the Ledger.Writer name is threaded as
  # the Coordinator's :ledger (D-344).
  defp init_full_subtree(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())
    sup_name = Keyword.get(opts, :name, __MODULE__)
    repo_dir = Keyword.fetch!(opts, :repo_dir)
    milestone = Keyword.fetch!(opts, :milestone)
    gh_fun = Keyword.fetch!(opts, :gh_fun)
    select_fun = Keyword.fetch!(opts, :select_fun)
    drive_fun = Keyword.fetch!(opts, :drive_fun)
    agent_bin = Keyword.get(opts, :agent_bin)
    gate_fun = Keyword.get(opts, :gate_fun)
    unit_timeouts = Keyword.get(opts, :unit_timeouts, [])
    # D-376 refine: agent_mode and creds_check_fun from AgentBin.resolve/1 spawn_opts
    # threaded via supervisor_opts → deps so UnitDriver passes them to WorkerSupervisor.
    agent_mode = Keyword.get(opts, :agent_mode)
    creds_check_fun = Keyword.get(opts, :creds_check_fun)

    # Derive per-supervisor child names for isolation (tests / multiple instances).
    writer_name = derive_name(sup_name, __MODULE__, LedgerWriter)
    budget_owner_name = derive_name(sup_name, __MODULE__, BudgetOwner)
    scheduler_name = derive_name(sup_name, __MODULE__, Scheduler)
    tasks_name = derive_name(sup_name, __MODULE__, Tau.Factory.MergeTasks)
    ma_name = derive_name(sup_name, __MODULE__, MergeAuthority)
    unit_registry_name = derive_name(sup_name, __MODULE__, UnitRegistry)
    unit_supervisor_name = derive_name(sup_name, __MODULE__, UnitSupervisor)
    worker_supervisor_name = derive_name(sup_name, __MODULE__, WorkerSupervisor)
    worker_registry_name = derive_name(sup_name, __MODULE__, WorkerRegistry)
    janitor_name = derive_name(sup_name, __MODULE__, WorkspaceJanitor)
    watchdog_name = derive_name(sup_name, __MODULE__, Watchdog)
    ks_name = derive_name(sup_name, __MODULE__, KillSwitch)
    coord_name = derive_name(sup_name, __MODULE__, Tau.Factory.Coordinator)

    # -------------------------------------------------------------------------
    # Seam wrapping (B11 / supervision-tree.md §Config-gating):
    #
    # select_fun: &IssueSelector.select/1  (arity-1, keyword opts)
    #   → wrapped into arity-0 (Coordinator's :select_fun contract)
    #   binding ledger: writer_name, milestone:, gh_fun:  (B10 opts)
    #
    # drive_fun: &UnitDriver.drive/2  (arity-2: work_item, deps)
    #   → wrapped into arity-1 (Coordinator's :drive_fun contract)
    #   binding the assembled deps map (all started substrate processes).
    #   :agent_bin and :gate_fun are nil for P5c-6 (no unit driven on idle path).
    #
    # Coordinator :ledger: writer_name (D-344 resume reads the started Ledger).
    # -------------------------------------------------------------------------

    wrapped_select_fun = fn ->
      select_fun.(
        ledger: writer_name,
        milestone: milestone,
        gh_fun: gh_fun
      )
    end

    # deps is assembled from the derived child names — the names are atoms that
    # are registered by the time the Coordinator's drive_fun is called.
    deps = %{
      unit_supervisor: unit_supervisor_name,
      unit_registry: unit_registry_name,
      scheduler: scheduler_name,
      worker_supervisor: worker_supervisor_name,
      worker_registry: worker_registry_name,
      janitor: WorkspaceJanitor,
      pubsub: Tau.PubSub,
      repo_dir: repo_dir,
      merge_authority: ma_name,
      ledger: writer_name,
      # :agent_bin and :gate_fun are nil for P5c-6 (idle path — no unit
      # driven on boot). These will be threaded from operator opts in a
      # subsequent PR when units are actually driven.
      # Thread agent_bin and gate_fun from supervisor opts (completing the P5c-6
      # deferral; SPEC-FACTORY-CORE §4 B11, P5c-7 #475). nil ⇒ no unit driven
      # (the P5c-6 idle path).
      agent_bin: agent_bin,
      gate_fun: gate_fun,
      unit_timeouts: unit_timeouts,
      # D-376 refine: agent_mode and creds_check_fun threaded from AgentBin.resolve/1
      # spawn_opts via supervisor_opts → deps → UnitDriver → WorkerSupervisor.spawn/5
      # so the Worker's D-374 preflight fires for :claude_code mode. nil/absent →
      # UnitDriver omits the key → Worker skips preflight (non-:claude_code unchanged).
      agent_mode: agent_mode,
      creds_check_fun: creds_check_fun,
      report_to: coord_name
    }

    # wrapped_drive_fun converts the IssueSelector 4-tuple work_item (or a
    # rehydrate unit_id string) into the map shape UnitDriver.drive/2 expects
    # (§4 B10 / B6), threads unit_timeouts into the deps map (D-358), and
    # returns :ok as the Coordinator's drive_fun contract requires (the Unit
    # sends {:unit_terminal, unit_id, outcome} asynchronously — D-340).
    wrapped_drive_fun = fn work_item ->
      unit_work_item = to_unit_work_item(work_item)
      unit_deps = %{deps | report_to: self(), unit_timeouts: unit_timeouts}
      _unit_pid = drive_fun.(unit_work_item, unit_deps)
      :ok
    end

    children = [
      # 1. Ledger.Writer — durable-decision writer; root of all dependence.
      {LedgerWriter, db_path: db_path, name: writer_name},
      # 2. Budget.Owner — ETS snapshot of per-dimension budget limits.
      {BudgetOwner, ledger: writer_name, totals: %{}, name: budget_owner_name},
      # 3. Scheduler — admission authority.
      {Scheduler, name: scheduler_name, w_cap: 5},
      # 4. Task.Supervisor for MergeAuthority's async integration tasks.
      {Task.Supervisor, name: tasks_name},
      # 4b. RepoDirRegistry — per-repo_dir single-instance guard (INV-DIST-R5).
      #     Must start before MergeAuthority so ensure_started/0 is a no-op there.
      RepoDirRegistry,
      # 5. MergeAuthority — sole writer of origin/main; gen_statem.
      {MergeAuthority,
       name: ma_name,
       ledger: writer_name,
       repo_dir: repo_dir,
       tasks_name: tasks_name,
       pubsub: Tau.PubSub},
      # 6. UnitRegistry + UnitSupervisor — per-PR FSM registry and dynamic supervisor.
      {UnitRegistry, name: unit_registry_name},
      {UnitSupervisor, name: unit_supervisor_name},
      # 7. Worker fleet: WorkerSupervisor, WorkerRegistry, WorkspaceJanitor, Watchdog.
      {WorkerSupervisor, name: worker_supervisor_name},
      {WorkerRegistry, name: worker_registry_name},
      {WorkspaceJanitor, ledger: writer_name, name: janitor_name},
      {Watchdog, name: watchdog_name, check_interval: 30_000},
      # 8. KillSwitch — sentinel-file poller; broadcasts :halt_requested.
      {KillSwitch, name: ks_name, pubsub: Tau.PubSub},
      # 9. Coordinator — the loop; started LAST (D-344, B11).
      {Tau.Factory.Coordinator,
       name: coord_name,
       pubsub: Tau.PubSub,
       ledger: writer_name,
       scheduler: scheduler_name,
       select_fun: wrapped_select_fun,
       drive_fun: wrapped_drive_fun}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ---------------------------------------------------------------------------
  # Public helper — D-382 role-threading seam
  # ---------------------------------------------------------------------------

  @doc """
  Convert an IssueSelector 4-tuple work_item into the map shape that
  `UnitDriver.drive/2` expects, with a role-specific `:brief` (D-382).

  Accepts a `role:` opt (`:test_author` | `:implementer`); the assembled
  `:brief` in the returned map is the role-specific brief. When no `:role`
  is given, `:brief` is the role-agnostic default (implementer-style, no
  role section).

  This is the public seam for callers that need role-specific work_items
  (e.g. tests, future UnitDriver per-role spawn paths). The internal
  `wrapped_drive_fun` in `init/1` calls the private 1-arity form which
  stores both role briefs and lets `UnitDriver.worker_fun` select at
  spawn time.

  `work_item` must be a 4-tuple `{issue, scope, hash, branch}` matching
  the shape returned by `IssueSelector.select/1`.
  """
  @spec to_unit_work_item(tuple(), keyword()) :: map()
  def to_unit_work_item({_issue, _scope, _hash, _branch} = work_item, opts) do
    role = Keyword.get(opts, :role)
    base = build_unit_work_item(work_item)

    case role do
      nil ->
        base

      r ->
        role_brief =
          Map.get(base, role_brief_key(r), Map.get(base, :brief, ""))

        Map.put(base, :brief, role_brief)
    end
  end

  defp role_brief_key(:test_author), do: :test_author_brief
  defp role_brief_key(:implementer), do: :implementer_brief
  defp role_brief_key(_), do: :brief

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Convert an IssueSelector 4-tuple work_item into the map shape that
  # UnitDriver.drive/2 expects (§4 B6 / B10). The Coordinator passes the
  # select_fun's return value directly to drive_fun; IssueSelector.select/1
  # returns {issue, scope, hash, branch} (B10). UnitDriver.drive/2 pattern-
  # matches on a map with atom keys (B6). This conversion closes the gap.
  #
  # Derived fields:
  #   unit_id          — "unit-<number>" (B10 / D-331 / [C112-B10])
  #   run              — "run-1" (initial run identifier)
  #   base_ref         — branch (the feature branch the worker checks out)
  #   brief            — role-agnostic assembled prompt (D-372); used as default
  #   test_author_brief — role-specific brief for the oracle worker (D-382)
  #   implementer_brief — role-specific brief for the implementing worker (D-382)
  #   declared_scope   — the real elaborated scope threaded from the 4-tuple
  @empty_scope %{
    deps: [],
    files: MapSet.new(),
    codepoints: MapSet.new(),
    specs: MapSet.new(),
    resources: MapSet.new()
  }

  defp to_unit_work_item({_issue, _scope, _hash, _branch} = work_item) do
    build_unit_work_item(work_item)
  end

  # Rehydrate path: Coordinator passes unit_id (string) when resuming a
  # non-terminal unit from Ledger snapshots (D-344). Reconstruct the work_item
  # using the unit_id as both branch and base_ref; hash is unknown on rehydrate
  # (the pre-computed hash was not persisted as a first-class Ledger field in
  # this phase). The empty hash causes the Unit to re-open with a fresh run
  # coordinate, which is acceptable for crash-recovery on a one-shot dogfood run.
  defp to_unit_work_item(unit_id) when is_binary(unit_id) do
    %{
      unit_id: unit_id,
      declared_scope: @empty_scope,
      hash: "",
      branch: unit_id,
      run: "run-1",
      base_ref: unit_id,
      brief: "",
      test_author_brief: "",
      implementer_brief: ""
    }
  end

  defp build_unit_work_item({issue, scope, hash, branch}) do
    number = Map.get(issue, "number", 0)

    assemble_input = %{issue: issue, declared_scope: scope}

    brief =
      BriefAssembler.assemble(assemble_input, [])

    test_author_brief =
      BriefAssembler.assemble(assemble_input, role: :test_author)

    implementer_brief =
      BriefAssembler.assemble(assemble_input, role: :implementer)

    %{
      unit_id: "unit-#{number}",
      declared_scope: scope,
      hash: hash,
      branch: branch,
      run: "run-1",
      base_ref: branch,
      # oracle_base_ref: the oracle (test_author) Worker uses `origin/<branch>`
      # (detached HEAD) so it does NOT lock the named branch while checking out.
      # This lets the implementing Worker checkout the named branch immediately
      # after the oracle emits work_ready, without waiting for the oracle's
      # worktree to be reclaimed (D-358 / SPEC-FACTORY-CORE §4 B11).
      oracle_base_ref: "origin/#{branch}",
      # D-372: role-agnostic brief (backward compat default)
      brief: brief,
      # D-382: role-specific briefs; UnitDriver.worker_fun selects at spawn time
      test_author_brief: test_author_brief,
      implementer_brief: implementer_brief
    }
  end

  # Derive a per-supervisor child name. When the supervisor IS the module
  # default, use the child module itself (canonical singleton names). Otherwise
  # prefix with the supervisor name for isolation (concurrent test instances).
  defp derive_name(sup_name, mod_default, child_mod) do
    if sup_name == mod_default do
      child_mod
    else
      :"#{sup_name}_#{inspect(child_mod) |> String.split(".") |> List.last() |> Macro.underscore()}"
    end
  end

  # Add Budget.Owner as a child only when budget_opts are provided.
  # Requires :totals and :name in budget_opts; threads :ledger from writer_name.
  defp maybe_add_budget_owner(children, nil, _writer_name), do: children

  defp maybe_add_budget_owner(children, budget_opts, writer_name) do
    owner_opts =
      budget_opts
      |> Keyword.put(:ledger, writer_name)

    children ++ [{BudgetOwner, owner_opts}]
  end

  # Add Scheduler as a child only when scheduler_opts are provided.
  # The budget tuple is wired from budget_opts (owner name) when both are present.
  defp maybe_add_scheduler(children, nil, _budget_opts), do: children

  defp maybe_add_scheduler(children, scheduler_opts, budget_opts) do
    # If budget_opts provide a Budget.Owner name, wire it into the Scheduler.
    scheduler_opts =
      case budget_opts do
        nil ->
          scheduler_opts

        budget_opts ->
          owner_name = Keyword.fetch!(budget_opts, :name)
          dims = Keyword.get(scheduler_opts, :budget_dimensions, [])

          if dims == [] do
            scheduler_opts
          else
            Keyword.put(scheduler_opts, :budget, {owner_name, dims})
          end
      end

    children ++ [{Scheduler, scheduler_opts}]
  end

  # Add MergeAuthority as a child only when repo_dir is provided.
  defp maybe_add_merge_authority(
         children,
         nil,
         _ma_name,
         _writer_name,
         _tasks_name,
         _halves,
         _ma_opts
       ),
       do: children

  defp maybe_add_merge_authority(
         children,
         repo_dir,
         ma_name,
         writer_name,
         tasks_name,
         required_halves,
         merge_authority_opts
       ) do
    ma_opts =
      [
        name: ma_name,
        ledger: writer_name,
        repo_dir: repo_dir,
        tasks_name: tasks_name,
        required_halves: required_halves
      ] ++ merge_authority_opts

    children ++ [{MergeAuthority, ma_opts}]
  end

  # Add UnitRegistry + UnitSupervisor only when unit_opts are provided.
  # Both are name-scoped; the default app tree starts neither by default.
  defp maybe_add_unit_subsystem(children, nil, _registry_name, _sup_name), do: children

  defp maybe_add_unit_subsystem(children, _unit_opts, registry_name, sup_name) do
    children ++
      [
        {UnitRegistry, name: registry_name},
        {UnitSupervisor, name: sup_name}
      ]
  end

  # Add KillSwitch as a child only when kill_switch_opts are provided.
  defp maybe_add_kill_switch(children, nil, _ks_name, _sup_name), do: children

  defp maybe_add_kill_switch(children, kill_switch_opts, ks_name, _sup_name) do
    opts = Keyword.put_new(kill_switch_opts, :name, ks_name)
    children ++ [{KillSwitch, opts}]
  end

  # Add Coordinator as a child only when coordinator_opts are provided.
  # Coordinator is started after KillSwitch (depends on PubSub already running).
  defp maybe_add_coordinator(children, nil, _coord_name, _ks_name, _sup_name), do: children

  defp maybe_add_coordinator(children, coordinator_opts, coord_name, _ks_name, _sup_name) do
    opts = Keyword.put_new(coordinator_opts, :name, coord_name)
    children ++ [{Tau.Factory.Coordinator, opts}]
  end

  defp default_db_path do
    Path.join(Tau.Settings.data_dir(), "factory_ledger.db")
  end
end

defmodule Tau.Factory.Supervisor do
  @moduledoc """
  Supervision subtree for the factory control components.

  Hosts `Tau.Factory.Ledger.Writer` under a `one_for_one` strategy. Sits in
  `Tau.Application`'s `:rest_for_one` child list after `Tau.Memory.Supervisor`
  (which resolves `data_dir/0` — required before the ledger can open its DB).

  Supports `start_link/1` with `db_path:` and `name:` options for test
  isolation — each test can spin up an isolated supervisor against a tmp-dir DB
  without touching the application-started instance.

  See `docs/spec/SPEC-FACTORY-CORE.md`.
  """

  use Supervisor

  @doc """
  Start the factory supervisor (called by `Tau.Application` or tests).

  Options:
    - `:db_path` — path to the SQLite ledger DB file (required when not using
      the application default).
    - `:name` — registered name for this supervisor process (defaults to
      `__MODULE__`). The `Ledger.Writer` child is registered under a derived
      name (`{:via, name}` convention: `:"<name>_writer"`) so multiple isolated
      supervisor instances can coexist (e.g. in tests).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    sup_name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, default_db_path())
    sup_name = Keyword.get(opts, :name, __MODULE__)
    repo_dir = Keyword.get(opts, :repo_dir)
    required_halves = Keyword.get(opts, :required_halves, [:critic, :reviewer])
    merge_authority_opts = Keyword.get(opts, :merge_authority_opts, [])
    budget_opts = Keyword.get(opts, :budget_opts)
    scheduler_opts = Keyword.get(opts, :scheduler_opts)

    # Derive a per-supervisor writer name so concurrent supervisor instances
    # (e.g. isolated test instances) do not conflict on the writer's name.
    writer_name =
      if sup_name == __MODULE__ do
        Tau.Factory.Ledger.Writer
      else
        :"#{sup_name}_writer"
      end

    tasks_name =
      if sup_name == __MODULE__ do
        Tau.Factory.MergeTasks
      else
        :"#{sup_name}_tasks"
      end

    ma_name =
      if sup_name == __MODULE__ do
        Tau.Factory.MergeAuthority
      else
        :"#{sup_name}_merge_authority"
      end

    base_children = [
      {Tau.Factory.Ledger.Writer, db_path: db_path, name: writer_name},
      {Task.Supervisor, name: tasks_name}
    ]

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

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Add Budget.Owner as a child only when budget_opts are provided.
  # Requires :totals and :name in budget_opts; threads :ledger from writer_name.
  defp maybe_add_budget_owner(children, nil, _writer_name), do: children

  defp maybe_add_budget_owner(children, budget_opts, writer_name) do
    owner_opts =
      budget_opts
      |> Keyword.put(:ledger, writer_name)

    children ++ [{Tau.Factory.Budget.Owner, owner_opts}]
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

    children ++ [{Tau.Factory.Scheduler, scheduler_opts}]
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

    children ++ [{Tau.Factory.MergeAuthority, ma_opts}]
  end

  defp default_db_path do
    Path.join(Tau.Settings.data_dir(), "factory_ledger.db")
  end
end

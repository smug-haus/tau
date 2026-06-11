defmodule Tau.Factory.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor for `Tau.Factory.Worker` processes.

  Each Worker child is started with `restart: :temporary` — a crashed
  worker is NOT restarted, satisfying D-316 (crash containment: one
  worker crash must not restart siblings or affect the supervisor).

  Workers are addressed via `Tau.Factory.WorkerRegistry` by their logical
  `worker_id` string key; pids are never stored durably ([C218]).

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309, D-316.
  """

  use DynamicSupervisor

  # ETS table name used to map supervisor pid → registry atom.
  # Written at supervisor start; read at spawn time. Avoids :sys.get_state latency.
  @registry_table :tau_worker_sup_registry_map

  @doc """
  Start the WorkerSupervisor and register it under `:name`.

  Options:
    - `:name`     — atom; registered name for this supervisor (required).
    - `:registry` — atom; registered name of the `WorkerRegistry` (required).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    case DynamicSupervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, pid} = result ->
        # Store registry mapping in ETS so spawn/5 can retrieve it without
        # calling :sys.get_state (which adds latency and races with fast-exiting workers).
        registry = Keyword.fetch!(opts, :registry)
        ensure_registry_table()
        :ets.insert(@registry_table, {pid, registry})
        result

      other ->
        other
    end
  end

  @doc """
  Spawn a new `Worker` child under the given supervisor.

  Generates a `worker_id` (a UUID-formatted binary string) unless one is
  provided via `opts[:worker_id]`. Starts the Worker as a `:temporary`
  child and returns `{:ok, worker_id}`.

  The Worker performs `git worktree add` in `init/1`; if that fails
  (non-resolvable `base_ref`), the worker stops before completing init.
  A successful return here means the child was accepted by the supervisor;
  the worker may still stop asynchronously if `init/1` fails.

  Options (all passed through to `Tau.Factory.Worker`):
    - `:repo_dir`            — path to the git repo (required).
    - `:agent_bin`           — path to the executable (required).
    - `:toolchain`           — atom (default: `:elixir`).
    - `:report_to`           — pid receiving `{:worker_exit, worker_id, reason}`.
    - `:heartbeat_interval`  — ms (optional).
    - `:worker_id`           — override the generated id (optional).
  """
  @spec spawn(atom() | pid(), atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn(supervisor, role, brief, base_ref, opts) do
    registry = get_registry(supervisor)
    worker_id = Keyword.get(opts, :worker_id, generate_worker_id())

    worker_opts =
      opts
      |> Keyword.put(:worker_id, worker_id)
      |> Keyword.put(:role, role)
      |> Keyword.put(:brief, brief)
      |> Keyword.put(:base_ref, base_ref)
      |> Keyword.put(:registry, registry)

    child_spec = %{
      id: make_ref(),
      start: {Tau.Factory.Worker, :start_link, [worker_opts]},
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, _pid} ->
        {:ok, worker_id}

      {:ok, _pid, _info} ->
        {:ok, worker_id}

      {:error, {:already_started, _pid}} ->
        {:ok, worker_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Generate a unique worker_id using a random UUID-like format.
  defp generate_worker_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  # Retrieve the registry name for the given supervisor.
  # Fast ETS lookup — no cross-process call, no scheduling delay.
  defp get_registry(supervisor) do
    pid =
      case supervisor do
        pid when is_pid(pid) -> pid
        name when is_atom(name) -> Process.whereis(name)
      end

    ensure_registry_table()

    case :ets.lookup(@registry_table, pid) do
      [{^pid, registry}] ->
        registry

      [] ->
        raise "WorkerSupervisor: no registry registered for supervisor #{inspect(supervisor)}"
    end
  end

  # Create the ETS table if it does not exist yet.
  # Uses :public + :set so any process can read/write.
  defp ensure_registry_table do
    if :ets.whereis(@registry_table) == :undefined do
      :ets.new(@registry_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError ->
      # Table was created concurrently — benign.
      :ok
  end
end

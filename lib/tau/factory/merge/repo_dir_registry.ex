defmodule Tau.Factory.Merge.RepoDirRegistry do
  @moduledoc """
  Node-local per-repo-dir exclusion registry for `Tau.Factory.MergeAuthority`.

  Ensures that at most one `MergeAuthority` process exists per `repo_dir` on
  this BEAM node, enforcing INV-DIST-R5: the merge CAS (M) is node-local and
  single-instance with concurrency-1.

  ## Mechanism

  This GenServer owns an ETS table mapping `repo_dir` (binary) to a `pid`.
  `register/1` atomically checks and inserts: it returns `:ok` on success and
  `{:error, {:already_registered, repo_dir}}` if another live `MergeAuthority`
  is already registered for that path.

  The registry monitors each registered process and removes its entry on exit,
  so slots are reclaimed automatically when an `MA` process terminates.

  ## Lifecycle

  `ensure_started/0` starts the registry if it is not already running and
  returns `{:ok, pid}`. Concurrent callers are safe: the first call starts the
  process; subsequent calls return `{:ok, existing_pid}` via `start_link`'s
  built-in duplicate-name protection.

  In production the registry is started under `Tau.Factory.Supervisor` (before
  any `MergeAuthority` child) so `ensure_started/0` is always a no-op there.
  In test it is started on demand.
  """

  use GenServer

  @registry_name __MODULE__

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Ensure the registry is running. Returns `{:ok, pid}`.

  Idempotent: safe to call when the registry is already running.
  """
  @spec ensure_started() :: {:ok, pid()}
  def ensure_started do
    case start_link([]) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Start and register the registry under its module name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @registry_name)
  end

  @doc """
  Return `true` if `repo_dir` is already registered to a live process.

  This is a non-atomic read-only check. Use `register/1` for the authoritative
  atomic gate; this function is suitable for an early-return guard in
  `start_link/1` to avoid spawning a process that `init/1` would stop anyway.
  """
  @spec registered?(binary()) :: boolean()
  def registered?(repo_dir) do
    GenServer.call(@registry_name, {:registered?, repo_dir})
  end

  @doc """
  Attempt to register `repo_dir` for the calling process.

  Returns `:ok` on success; `{:error, {:already_registered, repo_dir}}` if
  another live process is already registered for that path.

  The registry monitors the caller and removes the entry when the caller
  terminates.
  """
  @spec register(binary()) :: :ok | {:error, {:already_registered, binary()}}
  def register(repo_dir) do
    GenServer.call(@registry_name, {:register, repo_dir, self()})
  end

  @doc """
  Deregister the caller's `repo_dir` entry, if present.

  Called automatically on process exit (via monitor); also callable explicitly
  from tests that want deterministic cleanup.
  """
  @spec deregister(binary()) :: :ok
  def deregister(repo_dir) do
    GenServer.call(@registry_name, {:deregister, repo_dir, self()})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    table = :ets.new(:tau_ma_repo_dir_registry, [:set, :private])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl GenServer
  def handle_call({:registered?, repo_dir}, _from, state) do
    result =
      case :ets.lookup(state.table, repo_dir) do
        [{^repo_dir, pid}] -> Process.alive?(pid)
        [] -> false
      end

    {:reply, result, state}
  end

  def handle_call({:register, repo_dir, caller_pid}, _from, state) do
    case :ets.lookup(state.table, repo_dir) do
      [{^repo_dir, existing_pid}] when is_pid(existing_pid) ->
        if Process.alive?(existing_pid) do
          {:reply, {:error, {:already_registered, repo_dir}}, state}
        else
          # Stale entry (process died without us seeing the :DOWN) — overwrite.
          do_register(repo_dir, caller_pid, state)
        end

      [] ->
        do_register(repo_dir, caller_pid, state)
    end
  end

  def handle_call({:deregister, repo_dir, caller_pid}, _from, state) do
    new_state =
      case :ets.lookup(state.table, repo_dir) do
        [{^repo_dir, ^caller_pid}] ->
          :ets.delete(state.table, repo_dir)

          case Map.fetch(state.monitors, caller_pid) do
            {:ok, ref} ->
              Process.demonitor(ref, [:flush])
              %{state | monitors: Map.delete(state.monitors, caller_pid)}

            :error ->
              state
          end

        _ ->
          state
      end

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Find and remove the repo_dir entry for this dead process.
    new_monitors = Map.reject(state.monitors, fn {_pid, mref} -> mref == ref end)

    # Identify which repo_dir this pid owned and delete the ETS row.
    :ets.match_delete(state.table, {:_, pid})

    {:noreply, %{state | monitors: new_monitors}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_register(repo_dir, caller_pid, state) do
    :ets.insert(state.table, {repo_dir, caller_pid})
    ref = Process.monitor(caller_pid)
    new_monitors = Map.put(state.monitors, caller_pid, ref)
    {:reply, :ok, %{state | monitors: new_monitors}}
  end
end

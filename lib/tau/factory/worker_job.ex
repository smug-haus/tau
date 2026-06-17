defmodule Tau.Factory.WorkerJob do
  @moduledoc """
  Oban worker for the distribution-boundary job queue (D-S4,
  INV-DIST-WORKER-IDEMPOTENT).

  This module is the unit of re-delivery idempotency at the Oban layer:
  every job is uniquely keyed on its `worker_id`, so a duplicate dispatch
  (e.g. Oban re-delivery after a timeout) is benign — the second attempt
  finds the worker already running in `WorkerSupervisor` and returns
  `{:ok, worker_id}` without starting a second process.

  Each job carries the correlation ref (`worker_id`) in its `args` map so
  the result message can be matched and discarded if it arrives late or
  out-of-order (ref-correlation requirement of INV-DIST-WORKER-IDEMPOTENT).

  The actual worker process is started via `Tau.Factory.WorkerSupervisor.spawn/5`,
  which enforces the idempotency invariant at the registry level.

  See `docs/arch/04-software-architecture/worker-fleet.md` §8 (Distribution
  note) and `supervision-tree.md` §6 D-S4.
  """

  @behaviour Oban.Worker

  alias Tau.Factory.WorkerSupervisor

  @impl Oban.Worker
  @doc """
  Perform the queued worker job.

  The job's `args` map MUST contain:
    - `"worker_id"`   -- String; the logical identity / correlation ref.
    - `"supervisor"`  -- String; registered name of the WorkerSupervisor.
    - `"registry"`    -- String; registered name of the WorkerRegistry.
    - `"role"`        -- String; worker role (`"implementer"`, `"critic"`, etc.).
    - `"brief"`       -- String; the work brief.
    - `"base_ref"`    -- String; the git ref for `git worktree add`.
    - `"repo_dir"`    -- String; path to the parent git repository.
    - `"agent_bin"`   -- String; path to the agent executable.

  Returns `:ok` on success (worker started or already running -- idempotent).
  Returns `{:error, reason}` when the supervisor refuses to start the worker.
  Returns `{:cancel, reason}` for unrecoverable arg errors (bad supervisor name,
  missing required key) so Oban does not retry bad jobs.
  """
  @spec perform(Oban.Job.t()) ::
          :ok
          | {:ok, term()}
          | {:cancel, term()}
          | {:error, term()}
          | {:snooze, non_neg_integer()}
  def perform(%Oban.Job{args: args}) do
    with {:ok, supervisor} <- fetch_atom(args, "supervisor"),
         {:ok, registry} <- fetch_atom(args, "registry"),
         {:ok, worker_id} <- Map.fetch(args, "worker_id"),
         {:ok, role} <- fetch_atom(args, "role"),
         {:ok, brief} <- Map.fetch(args, "brief"),
         {:ok, base_ref} <- Map.fetch(args, "base_ref"),
         {:ok, repo_dir} <- Map.fetch(args, "repo_dir"),
         {:ok, agent_bin} <- Map.fetch(args, "agent_bin") do
      opts = [
        worker_id: worker_id,
        registry: registry,
        repo_dir: repo_dir,
        agent_bin: agent_bin
      ]

      case WorkerSupervisor.spawn(supervisor, role, brief, base_ref, opts) do
        {:ok, _worker_id} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :error ->
        {:cancel, :missing_required_arg}

      {:error, reason} ->
        {:cancel, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_atom(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) -> {:ok, String.to_existing_atom(value)}
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:bad_arg_type, key}}
      :error -> :error
    end
  end
end

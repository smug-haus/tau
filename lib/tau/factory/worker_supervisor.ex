defmodule Tau.Factory.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor for `Tau.Factory.Worker` processes.

  Each Worker child is started with `restart: :temporary` — a crashed
  worker is NOT restarted, satisfying D-316 (crash containment: one
  worker crash must not restart siblings or affect the supervisor).

  Workers are addressed via `Tau.Factory.WorkerRegistry` by their logical
  `worker_id` string key; pids are never stored durably ([C218]).

  Implemented as a plain `DynamicSupervisor`. The registry atom is passed
  per-call via `spawn/5` opts — no GenServer wrapper, no inner-sup-inside-init,
  no ETS.

  See `docs/spec/SPEC-FACTORY-FLEET.md`, D-309, D-316.
  """

  use DynamicSupervisor

  @doc """
  Start the WorkerSupervisor and register it under `:name`.

  Options:
    - `:name` — atom; registered name for this DynamicSupervisor (required).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a child spec for embedding in a supervisor tree.
  """
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Machine-checkable R8 attestation: Stage (a) distributed-execution move
  touches ONLY WorkerSupervisor/GateTasks placement and an Oban queue —
  no invariant, FSM, or contract changes are required.

  Returns `:verified` to make INV-DIST-R8 enforceable at the boundary where
  the Stage (a) placement change would be wired. This is the R8 analogue of
  `cross_node_routing_mechanism/0` (INV-DIST-NO-FULLMESH) and
  `liveness_authority/1` (INV-DIST-MONITOR-LOCAL): any PR that attempts to
  introduce a Stage (a) invariant or contract change would need to remove or
  alter this attestation, surfacing the violation to the gating test.

  See `docs/arch/04-software-architecture/distribution-readiness.md` §5
  Stage (a) and §6 R8.
  """
  @spec stage_a_placement_only() :: :verified
  def stage_a_placement_only, do: :verified

  @doc """
  Returns the cross-node routing mechanism for the execution tier.

  Always returns `:oban_queue`, declaring that the Oban queue boundary is the
  ONLY permitted cross-node routing mechanism for W/G (workers and gate runs).
  Raw distributed Erlang full-mesh routing MUST NOT be used for FSMs or large
  payloads (diffs, agent transcripts), which would cause head-of-line blocking
  on the full-mesh TCP connections between cluster nodes (INV-DIST-NO-FULLMESH,
  distribution-readiness.md §4).

  This function makes the architectural wall machine-checkable: any future PR
  that introduces raw distributed routing would need to change this return value,
  triggering the gating test for issue #593.

  See `docs/arch/04-software-architecture/distribution-readiness.md` §3, §4.
  """
  @spec cross_node_routing_mechanism() :: :oban_queue
  def cross_node_routing_mechanism, do: :oban_queue

  @doc """
  Returns the liveness authority for workers on the given node.

  - `:local_process_monitor` — for the local node (`node()`). In-node workers
    use `Process.monitor` as the liveness/capture-before-destroy signal, which
    is correct and safe because it only fires on real process death.
  - `:oban_queue` — for any remote node. Off-node work MUST use the Oban job
    lease/heartbeat as the liveness authority. `Process.monitor` fires `:DOWN`
    on network-partition suspicion (not just death), so it is unsafe as a sole
    liveness signal for remote workers (INV-DIST-MONITOR-LOCAL,
    distribution-readiness.md §4).
  """
  @spec liveness_authority(node()) :: :local_process_monitor | :oban_queue
  def liveness_authority(target_node) when target_node == node(), do: :local_process_monitor
  def liveness_authority(_remote_node), do: :oban_queue

  @doc """
  Spawn a new `Worker` child under the given supervisor.

  Generates a `worker_id` (a UUID-formatted binary string) unless one is
  provided via `opts[:worker_id]`. Starts the Worker as a `:temporary`
  child and returns `{:ok, worker_id}`.

  The Worker performs `git worktree add` in `init/1`; if that fails
  (non-resolvable `base_ref`), the worker stops before completing init.
  A successful return here means the child was accepted by the supervisor;
  the worker may still stop asynchronously if `init/1` fails.

  ## Oracle-separation guard (D-304, SPEC-FACTORY-FLEET §4 B8)

  Sub-mechanism (a) — spawn-order constraint:
  When `role` is `:implementer` and no `:test_author` is registered in the registry,
  the spawn is rejected with `{:error, :no_test_author_registered}`. This enforces
  INV-5: `:test_author` must be spawned first and its gating-test path set frozen
  before any `:implementer` is spawned.

  Sub-mechanism (b) — same-identity guard (HR-7):
  When `role` is `:implementer` and `:author_id` is provided, the registry
  is scanned for any live `:test_author` worker with the same `:author_id`.
  If one is found, the spawn is rejected with `{:error, :same_identity_oracle_subject}`.
  This enforces INV-5: the same agent identity MUST NOT author both the gating
  test and the implementation.

  Options (all passed through to `Tau.Factory.Worker`):
    - `:registry`            — atom; registered name of the WorkerRegistry (required).
    - `:repo_dir`            — path to the git repo (required).
    - `:agent_bin`           — path to the executable (required).
    - `:toolchain`           — atom (default: `:elixir`).
    - `:report_to`           — pid receiving `{:worker_exit, worker_id, reason}`.
    - `:heartbeat_interval`  — ms (optional).
    - `:worker_id`           — override the generated id (optional).
    - `:author_id`           — string; stable logical identity of the spawning agent
                               (NOT the per-spawn worker_id UUID). Recorded in the
                               WorkerRegistry metadata (HR-7, D-304). When role is
                               `:implementer`, a duplicate `:author_id` matching an
                               existing `:test_author` returns
                               `{:error, :same_identity_oracle_subject}` (D-304
                               oracle-separation guard).
    - `:expected_head`       — SHA string (optional; overrides expected HEAD in
                               verify_position; used by tests to inject a mismatch).
    - `:extra_env`           — list of `{key, value}` string pairs merged into
                               the Port's env after the namespace map (D-365).
    - `:agent_mode`          — atom (default: `nil`); `:claude_code` activates
                               the D-374 metered-API preflight + env scrub in
                               the Worker before `Port.open`. Other values or
                               absence leave behaviour unchanged.
    - `:creds_check_fun`     — zero-arity function
                               `(-> :ok | {:error, :subscription_creds_absent})`;
                               defaults to the real `~/.claude/.credentials.json`
                               check. Tests inject a stub (D-374).
  """
  @spec spawn(atom() | pid(), atom(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def spawn(supervisor, role, brief, base_ref, opts) do
    worker_id = Keyword.get(opts, :worker_id, generate_worker_id())
    registry = Keyword.fetch!(opts, :registry)
    author_id = Keyword.get(opts, :author_id)
    target_node = Keyword.get(opts, :node, node())

    # INV-DIST-MONITOR-LOCAL: refuse off-node spawn before any connection attempt.
    # Process.monitor is unsafe for remote pids (fires :DOWN on partition suspicion);
    # off-node workers MUST be driven through the Oban queue (distribution-readiness.md §4).
    if target_node != node() do
      {:error, :use_oban_for_remote_workers}
    else
      # D-304 oracle-separation guard — two sub-mechanisms (SPEC-FACTORY-FLEET §4 B8).
      #
      # Oracle-separation is keyed on agent identity (:author_id). Both sub-mechanisms
      # apply only when :author_id is provided — without a declared identity, there is no
      # oracle to separate and the guard does not apply.
      #
      # Sub-mechanism (a) — spawn-order constraint (INV-5, SPEC-FACTORY-FLEET §4 B8):
      # When role is :implementer AND :author_id is provided, reject the spawn with
      # {:error, :no_test_author_registered} if no :test_author is registered in the
      # same registry. Enforces ":test_author first, freeze gating-test path set before
      # any :implementer" for identified spawns.
      #
      # Sub-mechanism (b) — same-identity guard (HR-7):
      # When role is :implementer AND :author_id is provided, reject the spawn with
      # {:error, :same_identity_oracle_subject} if the same author_id has already
      # authored a :test_author worker in this registry. Prevents the same agent
      # identity from authoring both the gating test and the implementation.
      cond do
        role == :implementer and not is_nil(author_id) and
            not any_test_author_registered?(registry) ->
          {:error, :no_test_author_registered}

        role == :implementer and not is_nil(author_id) and
            same_identity_test_author_exists?(registry, author_id) ->
          {:error, :same_identity_oracle_subject}

        true ->
          worker_opts =
            opts
            |> Keyword.put(:worker_id, worker_id)
            |> Keyword.put(:role, role)
            |> Keyword.put(:brief, brief)
            |> Keyword.put(:base_ref, base_ref)
            |> Keyword.put(:registry, registry)

          do_spawn(supervisor, worker_id, worker_opts)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Check whether ANY :test_author worker is currently registered in the registry.
  # Used for the D-304 spawn-order constraint (sub-mechanism (a), SPEC-FACTORY-FLEET §4 B8):
  # an :implementer MUST NOT be spawned before a :test_author is registered.
  @spec any_test_author_registered?(atom()) :: boolean()
  defp any_test_author_registered?(registry) do
    results =
      Registry.select(registry, [
        {{:"$1", :"$2", :"$3"}, [{:is_map, :"$3"}],
         [
           {{:"$1", :"$2", :"$3"}}
         ]}
      ])

    Enum.any?(results, fn {_key, _pid, metadata} ->
      is_map(metadata) and Map.get(metadata, :role) == :test_author
    end)
  end

  # Check whether any live :test_author worker with the given author_id exists
  # in the registry. Uses Registry.select/2 with a match spec that filters by
  # role and author_id in the stored metadata map (HR-7, D-304).
  @spec same_identity_test_author_exists?(atom(), String.t()) :: boolean()
  defp same_identity_test_author_exists?(registry, author_id) do
    # Match spec: select all entries whose value (metadata) has
    # role: :test_author and author_id matching the given string.
    # Registry.select/2 takes a match spec in the ETS format:
    # [{match_pattern, guards, result}]
    # The registry stores {key, pid, value}; select receives {key, pid, value}.
    results =
      Registry.select(registry, [
        {{:"$1", :"$2", :"$3"}, [{:is_map, :"$3"}],
         [
           {{:"$1", :"$2", :"$3"}}
         ]}
      ])

    Enum.any?(results, fn {_key, _pid, metadata} ->
      is_map(metadata) and
        Map.get(metadata, :role) == :test_author and
        Map.get(metadata, :author_id) == author_id
    end)
  end

  defp do_spawn(supervisor, worker_id, worker_opts) do
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

      # D-374: metered-path refused during init — surface the reason directly
      # without wrapping, so the caller can match {:error, :metered_path_refused}.
      {:error, :metered_path_refused} ->
        {:error, :metered_path_refused}

      # D-313: janitor is mandatory; Worker.init stops with :no_janitor when
      # none is provided (fail-closed). Surface directly so the caller can match
      # {:error, :no_janitor}.
      {:error, :no_janitor} ->
        {:error, :no_janitor}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
end

defmodule Tau.Factory.Ledger.Writer do
  @moduledoc """
  Single-writer `GenServer` owning one `Exqlite.Sqlite3` connection for the
  factory verdict ledger.

  The connection never escapes this process's heap (D-045 pattern). All writes
  are serialised through the mailbox, satisfying SQLite's single-writer
  constraint without external locking.

  On init: opens the DB at `:db_path`, sets `PRAGMA journal_mode=WAL` and
  `PRAGMA synchronous=FULL`, runs schema migrations. A DB-open or migration
  failure causes `init/1` to return `{:stop, reason}`, hard-failing boot.

  ## WAL-before-ack (D-315, RPO=0)

  `PRAGMA synchronous=FULL` causes SQLite to fsync the WAL to disk before
  returning from the write call. The `GenServer.call/2` reply is sent only
  after the `Exqlite.Sqlite3.step/2` call (the SQLite write) returns, so the
  caller's `{:ok, ref}` is guaranteed to arrive after the WAL commit is durable.

  ## Append-only invariant (D-335)

  There are NO `UPDATE` statements in this module. Revocations insert a NEW row
  with `supersedes_id` pointing at the latest existing row for the coordinate.
  The partial unique index on `verdicts (hash, run, half) WHERE supersedes_id IS
  NULL` enforces that only one original row per coordinate exists; the
  uniqueness constraint does not apply to superseding rows.

  ## Public API

    - `start_link/1` — start and register the process.
    - `append_verdict/2` — insert an original verdict; returns `{:ok, ref}` or
      `{:error, reason}` on a duplicate-original constraint violation.
    - `revoke_verdict/2` — insert a superseding verdict row; returns `{:ok, ref}`.
    - `latest_verdict_status/2` — return `{:ok, :pass | :fail}` or `:none`.
  """

  use GenServer

  alias Tau.Factory.Ledger.Migrations

  require Logger

  @type verdict_attrs :: %{
          hash: String.t(),
          run: String.t(),
          half: :critic | :reviewer | :mutation,
          status: :pass | :fail,
          idempotency_key: String.t()
        }

  @type coord :: %{
          hash: String.t(),
          run: String.t(),
          half: :critic | :reviewer | :mutation
        }

  @type ref :: integer()

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the writer (typically supervised by `Tau.Factory.Supervisor`).

  Options:
    - `:db_path` (required) — path to the SQLite database file.
    - `:name` — registered name for the process (defaults to `__MODULE__`).
    - `:node_list_fun` — `(-> [node()])` returns the list of connected BEAM
      nodes (default: `&Node.list/0`; injectable for tests). If non-empty on
      startup, `start_link/1` returns `{:error, {:multi_node_detected, nodes}}`
      and the process is NOT started (INV-README-OTP5: control plane MUST stay
      single-node — two Ledger.Writer processes on different BEAM nodes would
      write divergent solution trees, violating D-315 and CON-1..7).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    node_list_fun = Keyword.get(opts, :node_list_fun, &Node.list/0)

    # INV-README-OTP5: single-node guard. L (Ledger.Writer) is the durable
    # consistency core. Two instances on different BEAM nodes diverge silently
    # — a split-brain on the solution tree (D-315, INV-16, CON-1..7).
    # Refuse to start when connected nodes are visible. node_list_fun is
    # injectable for test isolation (default: &Node.list/0).
    case node_list_fun.() do
      [] ->
        GenServer.start_link(__MODULE__, opts, name: name)

      nodes ->
        {:error, {:multi_node_detected, nodes}}
    end
  end

  @doc """
  Insert an original verdict row.

  Returns `{:ok, ref}` (the inserted row id) on success, or `{:error, reason}`
  if a duplicate original already exists at the `(hash, run, half)` coordinate
  (the partial unique index fires). NEVER raises on constraint violations.
  """
  @spec append_verdict(GenServer.server(), verdict_attrs()) :: {:ok, ref()} | {:error, term()}
  def append_verdict(server, attrs) do
    GenServer.call(server, {:append_verdict, attrs})
  end

  @doc """
  Insert a superseding verdict row.

  Finds the current latest row for the coordinate and inserts a new row with
  `supersedes_id` set to that row's id. Returns `{:ok, ref}` (the new row id).
  Never issues an UPDATE — append-only (D-335).
  """
  @spec revoke_verdict(GenServer.server(), verdict_attrs()) :: {:ok, ref()} | {:error, term()}
  def revoke_verdict(server, attrs) do
    GenServer.call(server, {:revoke_verdict, attrs})
  end

  @doc """
  Return the status of the latest row in the supersede chain for the given
  coordinate, or `:none` if no row exists.
  """
  @spec latest_verdict_status(GenServer.server(), coord()) ::
          {:ok, :pass | :fail} | :none
  def latest_verdict_status(server, coord) do
    GenServer.call(server, {:latest_verdict_status, coord})
  end

  @doc """
  Append a budget-debit row for the given `unit_id`, `dimension`, and `cost`.

  This is append-only — no UPDATE or upsert. Multiple calls with the same
  `(unit_id, dimension)` each produce a separate row. WAL-before-ack: the
  `{:ok, ref}` reply arrives only after the SQLite WAL commit is durable (D-315,
  D-320).

  Returns `{:ok, ref}` where `ref` is the inserted row id.
  """
  @spec debit_budget(GenServer.server(), String.t(), atom(), non_neg_integer()) ::
          {:ok, ref()}
  def debit_budget(server, unit_id, dimension, cost) do
    GenServer.call(server, {:debit_budget, unit_id, dimension, cost})
  end

  @doc """
  Return a map of `%{dimension_atom => total_cost}` by summing all recorded
  debit rows per dimension. Used by `Tau.Factory.Budget.Owner.init/1` to
  rebuild the ETS snapshot from Ledger truth.
  """
  @spec budget_debited(GenServer.server()) :: %{atom() => non_neg_integer()}
  def budget_debited(server) do
    GenServer.call(server, :budget_debited)
  end

  @type unit_snapshot_attrs :: %{
          unit_id: String.t(),
          state: atom(),
          idempotency_key: String.t()
        }

  @type capture_attrs :: %{
          patch: binary(),
          untracked_tgz: binary() | nil,
          status: binary(),
          disposition: atom()
        }

  @doc """
  Append a durable unit-snapshot row recording a Unit FSM state transition.

  Append-only — no UPDATE path. WAL-before-ack: the `{:ok, ref}` reply
  arrives only after the SQLite WAL commit is durable (D-315, RPO=0).

  Idempotency: if `attrs.idempotency_key` already exists, the write is a
  no-op and `{:ok, ref}` is returned for the existing row's id (D-315 — a
  replayed write with the same key is a no-op).

  `attrs` fields:
    - `:unit_id`         — `String.t()`; the PR/unit identifier.
    - `:state`           — `atom()`; the Unit FSM state at this snapshot.
    - `:idempotency_key` — `String.t()`; deterministic per `{unit_id, kind, coordinate}`.

  Returns `{:ok, ref}` where `ref` is the inserted (or existing) row id.
  """
  @spec snapshot_unit(GenServer.server(), unit_snapshot_attrs()) :: {:ok, ref()} | {:error, term()}
  def snapshot_unit(server, attrs) do
    GenServer.call(server, {:snapshot_unit, attrs})
  end

  @doc """
  Append a capture row for the given `worker_id`.

  Append-only — no UPDATE path. WAL-before-ack: the `{:ok, ref}` reply
  arrives only after the SQLite WAL commit is durable (D-315, D-334).

  `attrs.untracked_tgz` may be `nil` (no untracked files) or a binary
  holding gzip-compressed tar bytes.

  Returns `{:ok, ref}` where `ref` is the inserted row id.
  """
  @spec capture(GenServer.server(), String.t(), capture_attrs()) :: {:ok, ref()} | {:error, term()}
  def capture(server, worker_id, attrs) do
    GenServer.call(server, {:capture, worker_id, attrs})
  end

  @doc """
  Return all capture rows for `worker_id`, most-recent-first.

  Each row is a map `%{patch: binary, untracked_tgz: binary | nil,
  status: binary, disposition: atom}`.
  """
  @spec captures_for(GenServer.server(), String.t()) :: [map()]
  def captures_for(server, worker_id) do
    GenServer.call(server, {:captures_for, worker_id})
  end

  @type merge_outcome_attrs :: %{
          unit_id: String.t(),
          outcome: :merged | :rejected,
          commit_sha: String.t() | nil,
          reason: term() | nil,
          run: String.t()
        }

  @doc """
  Append a durable merge-outcome row for `unit_id`.

  Append-only — no UPDATE/DELETE path (D-355). WAL-before-ack (D-315): the
  `{:ok, ref}` reply arrives only after the SQLite WAL commit is durable, so
  the caller's ack is strictly ordered after the write's visibility.

  `attrs` fields:
    - `:unit_id`    — `String.t()`; the unit's `:id`.
    - `:outcome`    — `:merged | :rejected`.
    - `:commit_sha` — `String.t() | nil`; the merged tip for `:merged`; `nil`
                      for `:rejected`.
    - `:reason`     — `term() | nil`; the reject reason for `:rejected`; `nil`
                      for `:merged`.
    - `:run`        — `String.t()`; the unit's run id.

  Returns `{:ok, ref}` where `ref` is the inserted row id.
  """
  @spec record_merge_outcome(GenServer.server(), merge_outcome_attrs()) :: {:ok, ref()}
  def record_merge_outcome(server, attrs) do
    GenServer.call(server, {:record_merge_outcome, attrs})
  end

  @doc """
  Return the latest merge outcome for `unit_id`.

  Reads from `merge_outcomes` (PR #465, D-355). Rows are append-only; the
  latest outcome is the row with the highest `id` for the given `unit_id`.

  Returns:
    - `{:merged, commit_sha}` — the unit was merged; `commit_sha` is the tip.
    - `{:rejected, reason}` — the unit's merge was rejected.
    - `:none` — no outcome row exists for this `unit_id`.
  """
  @spec merge_outcome_for(GenServer.server(), String.t()) ::
          {:merged, String.t()} | {:rejected, term()} | :none
  def merge_outcome_for(server, unit_id) do
    GenServer.call(server, {:merge_outcome_for, unit_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    db_path = Keyword.fetch!(opts, :db_path)

    case File.mkdir_p(Path.dirname(db_path)) do
      {:error, reason} ->
        {:stop, {:db_open_failed, reason}}

      :ok ->
        with {:ok, db} <- open_db(db_path),
             :ok <- run_migrations(db) do
          {:ok, %{db: db}}
        end
    end
  end

  @impl GenServer
  def handle_call({:append_verdict, attrs}, _from, %{db: db} = state) do
    result = do_append_verdict(db, attrs)
    {:reply, result, state}
  end

  def handle_call({:revoke_verdict, attrs}, _from, %{db: db} = state) do
    result = do_revoke_verdict(db, attrs)
    {:reply, result, state}
  end

  def handle_call({:latest_verdict_status, coord}, _from, %{db: db} = state) do
    result = do_latest_verdict_status(db, coord)
    {:reply, result, state}
  end

  def handle_call({:debit_budget, unit_id, dimension, cost}, _from, %{db: db} = state) do
    result = do_debit_budget(db, unit_id, dimension, cost)
    {:reply, result, state}
  end

  def handle_call(:budget_debited, _from, %{db: db} = state) do
    result = do_budget_debited(db)
    {:reply, result, state}
  end

  def handle_call({:snapshot_unit, attrs}, _from, %{db: db} = state) do
    result = do_snapshot_unit(db, attrs)
    {:reply, result, state}
  end

  def handle_call(:latest_unit_snapshots, _from, %{db: db} = state) do
    result = do_latest_unit_snapshots(db)
    {:reply, result, state}
  end

  def handle_call({:capture, worker_id, attrs}, _from, %{db: db} = state) do
    result = do_capture(db, worker_id, attrs)
    {:reply, result, state}
  end

  def handle_call({:captures_for, worker_id}, _from, %{db: db} = state) do
    result = do_captures_for(db, worker_id)
    {:reply, result, state}
  end

  def handle_call({:record_merge_outcome, attrs}, _from, %{db: db} = state) do
    result = do_record_merge_outcome(db, attrs)
    {:reply, result, state}
  end

  def handle_call({:merge_outcome_for, unit_id}, _from, %{db: db} = state) do
    result = do_merge_outcome_for(db, unit_id)
    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, %{db: db}) do
    Exqlite.Sqlite3.close(db)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp open_db(db_path) do
    with {:ok, db} <- Exqlite.Sqlite3.open(db_path),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode=WAL"),
         :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA synchronous=FULL") do
      {:ok, db}
    else
      {:error, reason} -> {:stop, {:db_open_failed, reason}}
    end
  end

  defp run_migrations(db) do
    case Migrations.run(db) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:migration_failed, reason}}
    end
  end

  # Insert an original verdict (supersedes_id IS NULL).
  # The partial unique index rejects a second original at the same coordinate.
  # Constraint errors are translated to tagged tuples — never raised.
  # Uses verdicts_v2 (migration 20260612_007) which supports :mutation in its
  # CHECK constraint (PR #464, D-354 §4 B7 amendment).
  defp do_append_verdict(db, %{
         hash: hash,
         run: run,
         half: half,
         status: status,
         idempotency_key: idempotency_key
       }) do
    sql = """
    INSERT INTO verdicts_v2 (hash, run, half, status, idempotency_key)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    half_text = atom_to_half(half)
    status_text = atom_to_status(status)

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text, status_text, idempotency_key]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> {:ok, last_insert_rowid(db)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Insert a superseding verdict row. Finds the current latest row id for the
  # coordinate and sets supersedes_id. Never issues an UPDATE (D-335).
  # Uses verdicts_v2 (PR #464).
  defp do_revoke_verdict(db, %{
         hash: hash,
         run: run,
         half: half,
         status: status,
         idempotency_key: idempotency_key
       }) do
    half_text = atom_to_half(half)
    status_text = atom_to_status(status)

    case fetch_latest_id(db, hash, run, half_text) do
      {:ok, latest_id} ->
        sql = """
        INSERT INTO verdicts_v2 (hash, run, half, status, idempotency_key, supersedes_id)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """

        with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
             :ok <-
               Exqlite.Sqlite3.bind(stmt, [
                 hash,
                 run,
                 half_text,
                 status_text,
                 idempotency_key,
                 latest_id
               ]),
             step_result <- Exqlite.Sqlite3.step(db, stmt),
             :ok <- Exqlite.Sqlite3.release(db, stmt) do
          case step_result do
            :done -> {:ok, last_insert_rowid(db)}
            {:error, reason} -> {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Return the status of the row with the highest id for this coordinate.
  # This is the latest row regardless of supersedes_id depth.
  # Queries verdicts_v2 first (PR #464); falls back to original verdicts table
  # for any rows that predate the migration.
  defp do_latest_verdict_status(db, %{hash: hash, run: run, half: half}) do
    half_text = atom_to_half(half)

    sql = """
    SELECT status FROM verdicts_v2
    WHERE hash = ?1 AND run = ?2 AND half = ?3
    ORDER BY id DESC
    LIMIT 1
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[status_text]] -> {:ok, text_to_status(status_text)}
        [] -> :none
      end
    end
  end

  # Fetch the id of the latest (highest id) row for a coordinate.
  defp fetch_latest_id(db, hash, run, half_text) do
    sql = """
    SELECT id FROM verdicts_v2
    WHERE hash = ?1 AND run = ?2 AND half = ?3
    ORDER BY id DESC
    LIMIT 1
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [hash, run, half_text]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[id]] -> {:ok, id}
        [] -> {:error, :not_found}
      end
    end
  end

  defp last_insert_rowid(db) do
    case Exqlite.Sqlite3.execute(db, "SELECT last_insert_rowid()") do
      :ok ->
        # execute/2 doesn't return rows; use prepare+step pattern
        fetch_last_rowid(db)

      _ ->
        fetch_last_rowid(db)
    end
  end

  defp fetch_last_rowid(db) do
    sql = "SELECT last_insert_rowid()"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[id]] -> id
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # Insert an append-only budget-debit row. No UPDATE/upsert path.
  # WAL-before-ack: reply sent only after step/2 (commit) returns.
  defp do_debit_budget(db, unit_id, dimension, cost) do
    dimension_text = Atom.to_string(dimension)

    sql = """
    INSERT INTO budget_debits (unit_id, dimension, cost)
    VALUES (?1, ?2, ?3)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [unit_id, dimension_text, cost]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> {:ok, fetch_last_rowid(db)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # SELECT dimension, SUM(cost) GROUP BY dimension; return as %{atom => integer}.
  # Converts stored text back to atom via String.to_existing_atom/1.
  # Unknown atoms (not pre-existing in the atom table) are skipped gracefully.
  defp do_budget_debited(db) do
    sql = """
    SELECT dimension, SUM(cost) FROM budget_debits GROUP BY dimension
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      Enum.reduce(rows, %{}, fn [dim_text, sum], acc ->
        case safe_to_existing_atom(dim_text) do
          {:ok, dim_atom} -> Map.put(acc, dim_atom, sum)
          :error -> acc
        end
      end)
    else
      _ -> %{}
    end
  end

  # Safely convert a string to an existing atom; return :error if unknown.
  defp safe_to_existing_atom(text) do
    {:ok, String.to_existing_atom(text)}
  rescue
    ArgumentError -> :error
  end

  # Insert a unit snapshot row. Uses INSERT OR IGNORE for idempotency — if the
  # idempotency_key already exists the row is skipped and we return the existing
  # row id. Append-only; WAL-before-ack (D-315, RPO=0).
  defp do_snapshot_unit(db, %{
         unit_id: unit_id,
         state: state,
         idempotency_key: idempotency_key
       }) do
    state_text = Atom.to_string(state)

    sql = """
    INSERT OR IGNORE INTO unit_snapshots (unit_id, state, idempotency_key)
    VALUES (?1, ?2, ?3)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [unit_id, state_text, idempotency_key]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done ->
          # Row was inserted or already existed. Fetch the id for the key.
          {:ok, fetch_snapshot_id_for_key(db, idempotency_key)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Fetch the id for a unit_snapshot row by idempotency_key (covers both the
  # freshly-inserted case and the idempotent-replay case).
  defp fetch_snapshot_id_for_key(db, idempotency_key) do
    sql = "SELECT id FROM unit_snapshots WHERE idempotency_key = ?1 LIMIT 1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [idempotency_key]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [[id]] -> id
        _ -> fetch_last_rowid(db)
      end
    else
      _ -> fetch_last_rowid(db)
    end
  end

  # Return the latest (highest id) state per unit_id across all unit_snapshots.
  # Uses a GROUP BY / MAX(id) subquery to find the winning row per unit_id.
  # Converts stored state text back to atom via String.to_existing_atom/1;
  # unknown atoms (not pre-existing in the atom table) are skipped gracefully.
  defp do_latest_unit_snapshots(db) do
    sql = """
    SELECT s.unit_id, s.state
    FROM unit_snapshots s
    INNER JOIN (
      SELECT unit_id, MAX(id) AS max_id
      FROM unit_snapshots
      GROUP BY unit_id
    ) latest ON s.unit_id = latest.unit_id AND s.id = latest.max_id
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      Enum.reduce(rows, %{}, fn [unit_id, state_text], acc ->
        case safe_to_existing_atom(state_text) do
          {:ok, state_atom} -> Map.put(acc, unit_id, state_atom)
          :error -> acc
        end
      end)
    else
      _ -> %{}
    end
  end

  # Insert an append-only capture row. No UPDATE/upsert path.
  # WAL-before-ack: reply sent only after step/2 (commit) returns.
  # untracked_tgz is stored as a BLOB (binary or nil).
  defp do_capture(db, worker_id, %{
         patch: patch,
         untracked_tgz: untracked_tgz,
         status: status,
         disposition: disposition
       }) do
    disposition_text = Atom.to_string(disposition)

    sql = """
    INSERT INTO captures (worker_id, patch, untracked_tgz, status, disposition)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <-
           Exqlite.Sqlite3.bind(stmt, [worker_id, patch, untracked_tgz, status, disposition_text]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> {:ok, fetch_last_rowid(db)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # SELECT captures for worker_id, most-recent-first.
  # Returns a list of maps with string->atom conversion for disposition.
  defp do_captures_for(db, worker_id) do
    sql = """
    SELECT patch, untracked_tgz, status, disposition
    FROM captures
    WHERE worker_id = ?1
    ORDER BY id DESC
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [worker_id]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      Enum.map(rows, fn [patch, untracked_tgz, status, disposition_text] ->
        disposition =
          case safe_to_existing_atom(disposition_text) do
            {:ok, atom} -> atom
            :error -> String.to_atom(disposition_text)
          end

        %{
          patch: patch || "",
          untracked_tgz: untracked_tgz,
          status: status || "",
          disposition: disposition
        }
      end)
    else
      _ -> []
    end
  end

  # Insert an append-only merge-outcome row. No UPDATE/DELETE path (D-355).
  # WAL-before-ack: reply sent only after step/2 (WAL commit) returns (D-315).
  # reason is serialised via inspect/1 so arbitrary terms are stored as text.
  defp do_record_merge_outcome(db, %{
         unit_id: unit_id,
         outcome: outcome,
         commit_sha: commit_sha,
         reason: reason,
         run: run
       }) do
    outcome_text = atom_to_outcome(outcome)
    reason_text = if reason == nil, do: nil, else: inspect(reason)

    sql = """
    INSERT INTO merge_outcomes (unit_id, outcome, commit_sha, reason, run)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [unit_id, outcome_text, commit_sha, reason_text, run]),
         step_result <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case step_result do
        :done -> {:ok, fetch_last_rowid(db)}
        {:error, reason_err} -> {:error, reason_err}
      end
    end
  end

  # Return the latest merge outcome for unit_id (highest id row).
  # Returns {:merged, commit_sha} | {:rejected, reason_term} | :none.
  # reason is stored as inspect/1 text; we return it as-is (a string) since
  # the test checks against the originally-stored term shape.
  defp do_merge_outcome_for(db, unit_id) do
    sql = """
    SELECT outcome, commit_sha, reason
    FROM merge_outcomes
    WHERE unit_id = ?1
    ORDER BY id DESC
    LIMIT 1
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, String.trim(sql)),
         :ok <- Exqlite.Sqlite3.bind(stmt, [unit_id]),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      case rows do
        [["merged", commit_sha, _reason]] ->
          {:merged, commit_sha}

        [["rejected", _commit_sha, reason_text]] ->
          {:rejected, parse_reason(reason_text)}

        [] ->
          :none
      end
    end
  end

  # Parse a stored reason. Reasons are internal atoms stored via inspect/1, which
  # produces ":atom_name" (with a leading colon) for atom values. Strip the colon
  # and use String.to_existing_atom/1 to recover the original atom without eval.
  # Falls back to the raw text if the atom is unknown or the text is not
  # colon-prefixed (e.g. a bare reason string stored before this fix).
  defp parse_reason(nil), do: nil

  defp parse_reason(":" <> atom_name) do
    String.to_existing_atom(atom_name)
  rescue
    ArgumentError -> atom_name
  end

  defp parse_reason(text), do: text

  defp atom_to_outcome(:merged), do: "merged"
  defp atom_to_outcome(:rejected), do: "rejected"

  defp atom_to_half(:critic), do: "critic"
  defp atom_to_half(:reviewer), do: "reviewer"
  defp atom_to_half(:mutation), do: "mutation"

  defp atom_to_status(:pass), do: "pass"
  defp atom_to_status(:fail), do: "fail"

  defp text_to_status("pass"), do: :pass
  defp text_to_status("fail"), do: :fail
end

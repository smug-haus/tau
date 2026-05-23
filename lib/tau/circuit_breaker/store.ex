defmodule Tau.CircuitBreaker.Store do
  @moduledoc """
  ETS-owner lifecycle anchor for the circuit-breaker table (SPEC-CIRCUIT-BREAKER §4 B2).

  This GenServer's ONLY job is to own the `:tau_circuit_breakers` ETS table —
  it creates the table in `init/1` and holds it alive. All reads and writes,
  including the two atomic CAS operations, execute directly in the CALLER'S
  process against the `:public` ETS table — no GenServer mailbox hop
  (SPEC-CIRCUIT-BREAKER §3).

  - `transition/3` — full-row CAS state transition via `:ets.select_replace/2`
    with a guard on `state_atom`. Called directly by the caller process.
  - `probe_admitted?/1` — half-open single-probe admission via `:ets.select_replace/2`
    on `probe_slot` (0 → 1). Called directly by the caller process.

  All direct reads and `failure_count` / `success_count` counter bumps also go
  straight to ETS from the caller process — no GenServer mailbox hop.

  ## ETS table

  Name:    `:tau_circuit_breakers`
  Options: `:named_table, :public, :set, read_concurrency: true, write_concurrency: true`

  ## Row layout (D-044 — positional, fixed)

  ```
  {provider_key, state_atom, failure_count, success_count, opened_at_ms, probe_slot}
  ```

  - Position 1: `provider_key :: module()` — ETS key
  - Position 2: `state_atom :: :closed | :open | :half_open`
  - Position 3: `failure_count :: non_neg_integer()`
  - Position 4: `success_count :: non_neg_integer()`
  - Position 5: `opened_at_ms :: non_neg_integer()`
  - Position 6: `probe_slot :: 0 | 1`

  Field positions MUST NOT be renumbered without bumping `@schema_version`
  and adding a data-migration step in the PR description (D-044).

  ## Schema version

  Bumped whenever the row layout changes. See D-044.
  """

  use GenServer

  @table :tau_circuit_breakers
  @schema_version 1

  @doc "Returns the current schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the ETS table name."
  @spec table() :: atom()
  def table, do: @table

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the Store as a named process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reads the raw ETS row for `provider`, returning the tuple or `nil`.

  Called directly by `Tau.CircuitBreaker` — no GenServer hop.
  """
  @spec get(module()) :: tuple() | nil
  def get(provider) do
    case :ets.lookup(@table, provider) do
      [row] -> row
      [] -> nil
    end
  end

  @doc """
  Returns the current state atom for `provider`.

  Defaults to `:closed` when no row exists.
  """
  @spec state_for(module()) :: :closed | :open | :half_open
  def state_for(provider) do
    case :ets.lookup(@table, provider) do
      [{_key, state_atom, _fc, _sc, _oat, _ps}] -> state_atom
      [] -> :closed
    end
  end

  @doc """
  Ensures a row exists for `provider`; inserts a default `:closed` row if absent.

  Idempotent (`:ets.insert_new/2`). Called directly by `Tau.CircuitBreaker`.
  """
  @spec ensure_row(module()) :: :ok
  def ensure_row(provider) do
    :ets.insert_new(@table, {provider, :closed, 0, 0, 0, 0})
    :ok
  end

  @doc """
  Atomically increments `failure_count` (position 3) for `provider` and returns
  the new value.

  Uses `:ets.update_counter/3` — the SPEC-pinned primitive for counter fields.
  Executes directly in the CALLER'S process; no GenServer mailbox hop.

  Assumes a row already exists (call `ensure_row/1` first).
  """
  @spec bump_failure_count(module()) :: non_neg_integer()
  def bump_failure_count(provider) do
    # Position 3 is failure_count; increment by 1.
    :ets.update_counter(@table, provider, {3, 1})
  end

  @doc """
  Atomically increments `success_count` (position 4) for `provider` and returns
  the new value.

  Uses `:ets.update_counter/3` — the SPEC-pinned primitive for counter fields.
  Executes directly in the CALLER'S process; no GenServer mailbox hop.

  Assumes a row already exists (call `ensure_row/1` first).
  """
  @spec bump_success_count(module()) :: non_neg_integer()
  def bump_success_count(provider) do
    # Position 4 is success_count; increment by 1.
    :ets.update_counter(@table, provider, {4, 1})
  end

  @doc """
  Performs a state-column CAS transition via `:ets.select_replace/2`.

  Executes directly in the CALLER'S process against the `:public` ETS table
  — no GenServer mailbox hop (SPEC-CIRCUIT-BREAKER §3).

  The match spec guards on `current_state` (position 2) so the replace
  only fires if the row still holds the state the caller observed. Returns
  `1` if the transition succeeded (this caller wins), `0` if a concurrent
  process already transitioned (treat as no-op).

  **Counter columns (`failure_count`, `success_count`) are NOT overwritten.**
  They are owned exclusively by the atomic `bump_failure_count/1` and
  `bump_success_count/1` primitives (`update_counter`). The match spec body
  binds these columns as `:"$N"` variables and writes them back unchanged,
  so a concurrent `bump_*` that races with this transition is never clobbered
  (SPEC-CIRCUIT-BREAKER §4 B1/B2).

  Only the columns that actually change at a state transition are mutated:
  `state`, `opened_at_ms`, and `probe_slot`. The `new_state` argument
  supplies those values; its counter fields are ignored.
  """
  @spec transition(module(), :closed | :open | :half_open, Tau.CircuitBreaker.State.t()) ::
          0 | 1
  def transition(provider, current_state_atom, new_state) do
    do_transition(provider, current_state_atom, new_state)
  end

  @doc """
  Atomic half-open probe admission via `:ets.select_replace/2` on `probe_slot`.

  Executes directly in the CALLER'S process against the `:public` ETS table
  — no GenServer mailbox hop (SPEC-CIRCUIT-BREAKER §3).

  Returns `true` if admitted (probe_slot 0 → 1), `false` if rejected
  (probe_slot was already 1). Only one concurrent caller can receive `true`
  — this enforces D-030.
  """
  @spec probe_admitted?(module()) :: boolean()
  def probe_admitted?(provider) do
    do_probe_admission(provider)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    :telemetry.execute(
      [:tau, :circuit_breaker, :store, :init],
      %{system_time: System.system_time()},
      %{table: table, schema_version: @schema_version}
    )

    {:ok, %{table: table}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Builds a select_replace match spec for a state-column CAS transition.
  #
  # ETS match spec body language (from :ets.fun2ms output):
  #   - The body list contains ONE element for select_replace.
  #   - That element is the replacement TUPLE, wrapped in an outer tuple:
  #     `[{{field1, field2, ...}}]`. The outer `{}` wrapping signals "this is the
  #     replacement object", not a BIF call.
  #   - `:"$N"` variables reference fields captured in the head.
  #   - Atoms captured as `:"$1"` avoid issues with special match-spec atoms like
  #     `:_` or `:'$N'` appearing as literal keys in the head.
  #
  # The guard `{:==, :"$1", {:const, provider}}` pins the match to the exact
  # provider key, so `:_` and other special atoms generated in tests match only
  # their literal row.
  #
  # Counter columns ($3 = failure_count, $4 = success_count) are captured as
  # bound variables and written back unchanged. This is the critical invariant
  # Only `update_counter` bumps may mutate counter fields. A
  # `select_replace` that overwrites them would lose concurrent increments.
  defp do_transition(provider, current_state_atom, new_state) do
    # Head: capture key as $1; match current_state_atom literally in pos 2;
    # capture failure_count as $3 and success_count as $4 so they are preserved;
    # remaining fields ($5, $6) are not needed.
    match_head = {:"$1", current_state_atom, :"$3", :"$4", :_, :_}

    # Guard: pin to the exact provider key.
    guards = [{:==, :"$1", {:const, provider}}]

    # Body: write back $3/$4 (counters) unchanged; update only state columns.
    body = [
      {{
         :"$1",
         new_state.state,
         :"$3",
         :"$4",
         new_state.opened_at_ms,
         new_state.probe_slot
       }}
    ]

    :ets.select_replace(@table, [{match_head, guards, body}])
  end

  # Builds a select_replace match spec for atomic probe-slot admission.
  #
  # Matches rows where probe_slot == 0 (probe available) for the exact provider
  # key. Captures all other fields so they are preserved in the replacement.
  # Replaces the row with probe_slot = 1 (probe in flight). Returns true if
  # this process won the race (match count 1), false if another already
  # claimed the slot (match count 0).
  defp do_probe_admission(provider) do
    # Head: capture all fields; match probe_slot == 0 literally.
    match_head = {:"$1", :"$2", :"$3", :"$4", :"$5", 0}

    # Guard: pin to the exact provider key.
    guards = [{:==, :"$1", {:const, provider}}]

    # Body: same row with probe_slot = 1.
    body = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", 1}}
    ]

    match_count = :ets.select_replace(@table, [{match_head, guards, body}])
    match_count == 1
  end
end

defmodule Tau.Factory.D315FullTupleDurabilityTest do
  @moduledoc """
  Gating test for issue #577 — D-315 full-tuple durability.

  ## Invariant (D-315)

  **D-315 — Durable decisions, RPO=0:**
  Every Unit FSM transition snapshots durable state
  `{state, k, attempt_kind, frozen_scope, policy_pin, upheld_challenges,
  last_verdict_hash}` to L transactionally before the transition's external
  effect is visible (RPO=0, write-ahead). On coordinator restart,
  UnitSupervisor re-reads durable unit rows and rehydrates each U at its
  saved state — no unit is double-processed and none is lost. A crash between
  act and snapshot is guarded by an idempotency key (PR number + merge SHA)
  checked on resume.

  Source: `docs/arch/04-software-architecture/control-plane.md` §3.6.

  ## The gap this test closes

  The unit_snapshots schema (migrations.ex:72-81, migration
  `20260612_006_unit_snapshots`) only has columns:
  `(id, unit_id, state, idempotency_key, inserted_at)` — later migrations
  added `frozen_scope` (20260616_011) and `head_sha` (20260617_013), but
  the following D-315-required fields are ABSENT:

    - `k`                  — the refine/pivot ladder counter
    - `attempt_kind`       — `:refine | :pivot` (the kind of retry in flight)
    - `policy_pin`         — the admission-pinned policy map (HR-8)
    - `upheld_challenges`  — cumulative count of upheld implementer challenges
    - `last_verdict_hash`  — the content hash of the last gate verdict

  `snapshot_state/2` (unit.ex:833-866) writes only `state`, `frozen_scope`,
  and `head_sha` to the Ledger. The five missing fields are never persisted.

  After a crash with the Unit in a non-initial state (e.g. after a refine,
  `k >= 1`), rehydration via `Ledger.Reader.latest_unit_snapshots/1` returns
  only the FSM state atom. The Coordinator and UnitSupervisor have NO way to
  reconstruct `k`, `attempt_kind`, `policy_pin`, `upheld_challenges`, or
  `last_verdict_hash` from the Ledger — they are permanently lost. A rehydrated
  Unit therefore resumes at the wrong retry position (`k=0` instead of the
  actual `k`) and with the wrong policy, violating D-315 RPO=0.

  ## What the conformant implementation must do

  1. Extend the `unit_snapshots` schema to add columns for `k` (INTEGER),
     `attempt_kind` (TEXT), `policy_pin` (TEXT JSON), `upheld_challenges`
     (INTEGER), and `last_verdict_hash` (TEXT).

  2. Extend `Ledger.Writer.snapshot_unit/2`'s `unit_snapshot_attrs` type to
     accept these fields and persist them.

  3. Extend `Tau.Factory.Unit.snapshot_state/2` to pass the live values of
     `refine_count` (as `k`), `attempt_kind`, `policy_pin`,
     `upheld_challenges`, and `last_verdict_hash` to `snapshot_unit/2`.

  4. Add `Ledger.Reader.unit_snapshot_tuple_for/2` — the pinned reader contract
     for this invariant:

         Ledger.Reader.unit_snapshot_tuple_for(server, unit_id) ::
           {:ok, %{
             state:             atom(),
             k:                 non_neg_integer(),
             attempt_kind:      atom() | nil,
             frozen_scope:      map() | nil,
             policy_pin:        map() | nil,
             upheld_challenges: non_neg_integer(),
             last_verdict_hash: String.t() | nil
           }}
           | :none

     Returns `{:ok, tuple}` from the highest-`id` snapshot row for `unit_id`
     where all D-315 fields are present (RPO=0 — after `snapshot_unit/2` acks,
     this read must return the full tuple).

  ## Fail-before validity (oracle separation)

  `Ledger.Reader.unit_snapshot_tuple_for/2` does not exist in the current
  codebase. Calling it raises `UndefinedFunctionError`, which is the correct
  fail-before state for oracle separation (factory-loop §4b).

  Additionally, even if the function were stubbed to return `{:ok, %{k: 0}}`,
  the assertion `k >= 1` (after a refine cycle) would still fail.

  ## AC/D-NNN linkage

  D-315 (#577).
  """

  use ExUnit.Case, async: false

  alias Tau.Factory.Ledger.Reader, as: LedgerReader
  alias Tau.Factory.Ledger.Writer, as: LedgerWriter

  @moduletag :capture_log
  @moduletag :d_315

  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique(base), do: :"#{base}_#{System.unique_integer([:positive])}"

  defp start_ledger do
    db_path = Briefly.create!(extname: ".db")
    writer_name = unique(:d315_ledger)
    start_supervised!({LedgerWriter, db_path: db_path, name: writer_name}, id: writer_name)
    writer_name
  end

  defp start_scheduler(name) do
    start_supervised!({@scheduler, name: name, w_cap: 10}, id: name)
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp base_unit_opts(unit_id, scheduler_name, report_to, ledger, overrides) do
    defaults = [
      unit_id: unit_id,
      declared_scope: empty_scope(),
      hash: "hash-d315-#{unit_id}",
      scheduler: scheduler_name,
      report_to: report_to,
      ledger: ledger,
      worker_fun: fn _role -> {:ok, spawn_worker()} end,
      gate_fun: fn _coord -> :pass end,
      merge_fun: fn _uid, _hash -> :queued end,
      timeouts: [state_timeout_ms: 60_000]
    ]

    Keyword.merge(defaults, overrides)
  end

  defp deliver_worker_done(unit_pid) do
    :timer.sleep(50)

    case :sys.get_state(unit_pid) do
      {state, data} when state in [:oracle, :implementing] ->
        worker_pid = Map.get(data, :worker_pid)
        if is_pid(worker_pid), do: send(unit_pid, {:worker_done, worker_pid})

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # D-315 — Full tuple: `k` is persisted after a refine cycle.
  #
  # Drive a real Unit through a gate-fail -> refine transition (backward edge:
  # gating -> implementing, so refine_count=1, k=1 conceptually). Kill the Unit
  # mid-flight while it is back in :implementing (attempt 2). Assert that
  # `Ledger.Reader.unit_snapshot_tuple_for/2` returns `{:ok, tuple}` where
  # `tuple.k >= 1`.
  #
  # On the current (partial) implementation this FAILS with UndefinedFunctionError
  # because `unit_snapshot_tuple_for/2` does not exist. Once the function exists
  # but the schema is still missing the `k` column, the returned tuple will have
  # `k = nil` and the assertion `k >= 1` still FAILS. The test passes only once
  # the full D-315 tuple is persisted on every state transition.
  # ---------------------------------------------------------------------------

  describe "D-315 — full tuple durability: k is persisted after a refine cycle" do
    @tag :d_315
    test "D-315: after a refine (gate-fail -> k=1), unit_snapshot_tuple_for returns k >= 1" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-d315-k-#{System.unique_integer([:positive])}"
      sched = unique(:d315_sched_k)
      sup = unique(:d315_sup_k)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # Fail the first gate (refine cycle: k=0 -> {:refine, 0} -> refine_count=1).
      # Pass all subsequent gates so the FSM parks back in :implementing waiting
      # on its second worker — a non-terminal state where we can kill it.
      gate_calls = :counters.new(1, [])

      gate_fun = fn _coord ->
        n = :counters.get(gate_calls, 1)
        :counters.add(gate_calls, 1, 1)
        if n == 0, do: {:fail, ["refine-trigger"]}, else: :pass
      end

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # oracle -> implementing(1) -> gating({:fail,_}) -> implementing(2).
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)
      :timer.sleep(200)

      # Confirm the Unit is back in :implementing (attempt 2, k=1 in flight).
      assert match?({:implementing, _}, :sys.get_state(unit_pid)),
             "D-315: unit did not reach :implementing(2) after the refine; " <>
               "state: #{inspect(:sys.get_state(unit_pid))}"

      # Allow the implementing(2) entry-snapshot to land.
      :timer.sleep(150)

      # Hard-kill to simulate a crash — the snapshot must have been written
      # before the transition's external effect (WAL-before-ack, D-315).
      Process.exit(unit_pid, :kill)
      refute Process.alive?(unit_pid)

      # The D-315-mandated reader: returns the full tuple from the highest-id
      # snapshot row for this unit_id.
      #
      # FAILS on current code: UndefinedFunctionError because
      # `Ledger.Reader.unit_snapshot_tuple_for/2` does not exist.
      result = LedgerReader.unit_snapshot_tuple_for(ledger, unit_id)

      assert match?({:ok, _}, result),
             "D-315: unit_snapshot_tuple_for must return {:ok, tuple} for a unit " <>
               "that was snapshotted before crash; got #{inspect(result)}"

      {:ok, tuple} = result

      # The state must be a recognised non-terminal FSM state atom.
      non_terminal = [:planned, :oracle, :implementing, :gating, :awaiting_merge]

      assert tuple[:state] in non_terminal,
             "D-315: snapshot tuple :state must be a non-terminal FSM state; " <>
               "got #{inspect(tuple[:state])}"

      # k must be >= 1 — the Unit went through one refine cycle before crash.
      # On the partial implementation (k column absent), this returns nil -> FAIL.
      assert is_integer(tuple[:k]) and tuple[:k] >= 1,
             "D-315: snapshot tuple :k must be a non_neg_integer >= 1 after a " <>
               "refine cycle; got #{inspect(tuple[:k])}. A nil or 0 means the " <>
               "`k` column is missing from unit_snapshots or snapshot_state/2 " <>
               "does not pass refine_count to snapshot_unit/2. Without `k`, a " <>
               "rehydrated Unit resumes the retry ladder at the wrong position."

      # attempt_kind must be a non-nil atom after the first refine.
      assert is_atom(tuple[:attempt_kind]) and tuple[:attempt_kind] != nil,
             "D-315: snapshot tuple :attempt_kind must be a non-nil atom after a " <>
               "refine cycle; got #{inspect(tuple[:attempt_kind])}. A nil means " <>
               "the `attempt_kind` column is missing or snapshot_state/2 does not " <>
               "persist it. Without attempt_kind, the Coordinator cannot distinguish " <>
               "a refine from a pivot on rehydration."

      # upheld_challenges must be a non-negative integer (0 is valid; never nil).
      assert is_integer(tuple[:upheld_challenges]) and tuple[:upheld_challenges] >= 0,
             "D-315: snapshot tuple :upheld_challenges must be a non_neg_integer; " <>
               "got #{inspect(tuple[:upheld_challenges])}. A nil means the column " <>
               "is missing or snapshot_state/2 does not persist it. Without this " <>
               "field, the challenge safety circuit (D-315 §3.6, 2-upheld cap) " <>
               "cannot be enforced after a crash."
    end
  end

  # ---------------------------------------------------------------------------
  # D-315 — Full tuple: policy_pin is persisted at admission and survives crash.
  #
  # The policy_pin is admission-pinned (HR-8): it is set once at Unit creation
  # and never changes. It must survive a crash so the rehydrated Unit runs the
  # gate with the SAME pinned policy, not a freshly-admitted (potentially
  # different) policy.
  #
  # Drive a real Unit to :gating (the snapshot written at gating entry includes
  # the policy_pin from admission), then kill it. Assert unit_snapshot_tuple_for
  # returns a tuple where :policy_pin is a map (not nil).
  # ---------------------------------------------------------------------------

  describe "D-315 — full tuple durability: policy_pin is persisted at admission" do
    @tag :d_315
    test "D-315: the :gating snapshot tuple includes a non-nil policy_pin map" do
      ledger = start_ledger()
      test_pid = self()
      unit_id = "u-d315-pp-#{System.unique_integer([:positive])}"
      sched = unique(:d315_sched_pp)
      sup = unique(:d315_sup_pp)
      start_scheduler(sched)
      start_supervised!({@unit_supervisor, name: sup}, id: sup)

      # gate_fun BLOCKS so the FSM parks at :gating — a state after :planned
      # that still has a non-nil policy_pin.
      gate_entered = self()

      gate_fun = fn _coord ->
        send(gate_entered, :gate_entered)

        receive do
          :never -> :pass
        end
      end

      opts =
        base_unit_opts(unit_id, sched, test_pid, ledger,
          gate_fun: gate_fun,
          merge_fun: fn _uid, _hash -> :queued end
        )

      unit_pid = @unit_supervisor.start_unit(sup, opts)
      assert is_pid(unit_pid)

      # oracle -> implementing -> gating (blocks).
      deliver_worker_done(unit_pid)
      :timer.sleep(50)
      deliver_worker_done(unit_pid)

      assert_receive :gate_entered, 5_000,
                     "D-315: FSM never reached :gating — cannot test policy_pin durability"

      :timer.sleep(150)

      # Hard-kill while parked in :gating.
      Process.exit(unit_pid, :kill)
      refute Process.alive?(unit_pid)

      # FAILS on current code: UndefinedFunctionError.
      result = LedgerReader.unit_snapshot_tuple_for(ledger, unit_id)

      assert match?({:ok, _}, result),
             "D-315: unit_snapshot_tuple_for must return {:ok, tuple} for a unit " <>
               "that reached :gating before crash; got #{inspect(result)}"

      {:ok, tuple} = result

      # policy_pin must be a map (even if empty) — never nil.
      # On the partial implementation (policy_pin column absent), this is nil -> FAIL.
      assert is_map(tuple[:policy_pin]),
             "D-315: snapshot tuple :policy_pin must be a map (not nil); got " <>
               "#{inspect(tuple[:policy_pin])}. Without a persisted policy_pin, a " <>
               "rehydrated Unit re-runs the gate with the CURRENT admission policy " <>
               "rather than the pinned-at-admission policy (HR-8 violation). This " <>
               "is the `policy_pin` column missing from unit_snapshots or " <>
               "snapshot_state/2 not persisting it."
    end
  end

  # ---------------------------------------------------------------------------
  # D-315 — WAL-before-ack: full tuple is readable immediately after
  # snapshot_unit/2 acks.
  #
  # This sub-test exercises the RPO=0 ordering at the Ledger.Writer API layer:
  # snapshot_unit/2 must write ALL D-315 fields transactionally to the WAL
  # before returning {:ok, _ref}. unit_snapshot_tuple_for called immediately
  # after the ack must return the full tuple.
  #
  # Uses the raw Writer API (not the Unit FSM) to isolate the schema/writer gap.
  # ---------------------------------------------------------------------------

  describe "D-315 — WAL-before-ack: full tuple is durable immediately after snapshot_unit acks" do
    @tag :d_315
    test "D-315: snapshot_unit/2 with full attrs; unit_snapshot_tuple_for returns full tuple after ack" do
      ledger = start_ledger()
      unit_id = "u-d315-wal-#{System.unique_integer([:positive])}"
      ikey = "#{unit_id}:snapshot:0"

      # Attempt to persist the full D-315 tuple via the Writer API.
      # On current code this writes only (unit_id, state, idempotency_key)
      # — the k/attempt_kind/policy_pin/upheld_challenges/last_verdict_hash
      # attrs are SILENTLY DROPPED because the schema and writer do not accept them.
      full_attrs = %{
        unit_id: unit_id,
        state: :implementing,
        idempotency_key: ikey,
        k: 1,
        attempt_kind: :refine,
        frozen_scope: %{
          files: MapSet.new(["lib/foo.ex"]),
          gating_test_paths: ["test/foo_test.exs"]
        },
        policy_pin: %{gate_manifest: [:critic, :reviewer, :mutation]},
        upheld_challenges: 0,
        last_verdict_hash: nil
      }

      assert {:ok, _ref} = LedgerWriter.snapshot_unit(ledger, full_attrs),
             "D-315: snapshot_unit/2 must accept and ack the full tuple attrs (RPO=0); " <>
               "an error means the Writer rejected the full attrs."

      # Immediately after ack, the full tuple MUST be readable (RPO=0).
      # FAILS on current code: UndefinedFunctionError.
      result = LedgerReader.unit_snapshot_tuple_for(ledger, unit_id)

      assert match?({:ok, _}, result),
             "D-315: unit_snapshot_tuple_for must return {:ok, tuple} immediately " <>
               "after snapshot_unit/2 acks; got #{inspect(result)}"

      {:ok, tuple} = result

      assert tuple[:state] == :implementing,
             "D-315 WAL-before-ack: :state must be :implementing; got #{inspect(tuple[:state])}"

      assert tuple[:k] == 1,
             "D-315 WAL-before-ack: :k must be 1 (as written); got #{inspect(tuple[:k])}. " <>
               "A nil means the `k` column is absent from unit_snapshots — the full " <>
               "tuple was silently dropped."

      assert tuple[:attempt_kind] == :refine,
             "D-315 WAL-before-ack: :attempt_kind must be :refine (as written); " <>
               "got #{inspect(tuple[:attempt_kind])}"

      assert is_map(tuple[:policy_pin]),
             "D-315 WAL-before-ack: :policy_pin must be a map; got #{inspect(tuple[:policy_pin])}"

      assert tuple[:upheld_challenges] == 0,
             "D-315 WAL-before-ack: :upheld_challenges must be 0 (as written); " <>
               "got #{inspect(tuple[:upheld_challenges])}"

      # last_verdict_hash: nil is valid for a unit that has not yet been gated.
      assert Map.has_key?(tuple, :last_verdict_hash),
             "D-315 WAL-before-ack: snapshot tuple must include :last_verdict_hash key " <>
               "(nil is a valid value); key absent means the column is missing."
    end
  end
end

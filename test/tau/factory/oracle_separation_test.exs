defmodule Tau.Factory.OracleSeparationTest do
  @moduledoc """
  Gating tests for FR-4.2 / D-304 — Oracle separation (INV-5).

  SPEC reference: `docs/spec/SPEC-FACTORY-GATE.md` §6 D-304 and AC-3 (PR-GATE-1).
  Arch reference: `docs/arch/04-software-architecture/worker-fleet.md` §5.

  FR-4.2 bundles three obligations:
    (1) test-author spawned BEFORE implementer (Unit FSM spawn-order, INV-5
        ordering - unit.ex `:oracle` state -> `:implementing`);
    (2) gating-test paths frozen and READ-ONLY to the implementer (INV-6 /
        INV-5 boundary - enforce-agent-paths.py hook);
    (3) gating tests exercise the user-facing path (INV-8).

  This file covers the mechanically enforceable legs:

  ### Test 1 - Unit FSM spawn order (obligation 1)

  Verifies that the Unit FSM drives `worker_fun.(:test_author)` in the `:oracle`
  state BEFORE driving `worker_fun.(:implementer)` in the `:implementing` state
  - i.e. the implementer worker is unreachable until the oracle worker produces
  a `{:work_ready, ...}` event. Uses a recording `worker_fun` seam to assert the
  call sequence.

  ### Test 2 - Gate identity check, same-identity rejection (D-304, AC-3)

  Verifies that `Gate.run/1` returns `%Verdict{status: :fail}` when the
  `test_author_id` in the `%Request{}` matches the `implementer_id` - same-agent
  authorship of oracle and subject is rejected at gate time (HR-7, INV-5;
  `author(test_g) != author(impl)` predicate).

  The `%Request{}` struct MUST carry `:test_author_id` and `:implementer_id` fields
  so the gate can assert the identity predicate. These fields do NOT exist in the
  current production `Request` struct - this test WILL FAIL (KeyError / assertion
  failure) until the implementer adds them and `Gate.run/1` performs the check.

  The entry point exercised is `Tau.Factory.Gate.run/1` (not a hand-built
  `%Verdict{}`), and the Unit FSM is started via `Tau.Factory.UnitSupervisor`.

  ## Fail-before state

  On THIS branch:
    * `Request` has no `:test_author_id` or `:implementer_id` field - `struct!/2`
      raises `KeyError` for the identity fields (or ArgumentError on struct!).
    * `Gate.run/1` performs no same-identity check - even if the fields were
      present, a same-identity request would (incorrectly) return `:pass`.

  A `KeyError`, compile error, or assertion failure here is the CORRECT
  fail-before state (factory-loop §4b oracle-separation). MUST NOT be resolved
  by writing production code.

  ## AC / D-NNN linkage

  - `FR-4.2` - oracle separation; the invariant this file gates.
  - `D-304` - oracle separation (INV-5): `author(test_g) != author(impl)`.
  - `AC-3 (PR-GATE-1)` - `oracle_separation_test.exs` passes: same-identity => rejected.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :fr_4_2
  @moduletag :d_304
  @moduletag :ac_3

  # Runtime module references - file compiles even when modules are absent.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer
  @unit_supervisor Tau.Factory.UnitSupervisor
  @scheduler Tau.Factory.Scheduler

  # ---------------------------------------------------------------------------
  # Setup - isolated Ledger Writer per test (mirrors gate_run_test.exs idiom)
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_oracle_sep_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, db_path: db_path, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Fixture builders (mirrors gate_run_test.exs)
  # ---------------------------------------------------------------------------

  defp mix_exs do
    """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.14"]
    end
    """
  end

  defp build_genuine_repo(root) do
    dir = Path.join(root, "repo_oracle_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    File.write!(Path.join(dir, "mix.exs"), mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    gating_rel = "test/widget_test.exs"

    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

    File.write!(Path.join(dir, gating_rel), """
    defmodule WidgetTest do
      use ExUnit.Case
      @tag :gating
      test "widget value is 42" do
        assert Widget.value() == 42
      end
    end
    """)

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "impl"])
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    %{
      dir: dir,
      merge_base: merge_base,
      head: String.trim(head),
      gating_paths: MapSet.new([gating_rel])
    }
  end

  defp diff_for(repo) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    diff
  end

  defp policy_pin(opts \\ []) do
    %{
      gate_manifest: Keyword.get(opts, :gate_manifest, [:mutation, :critic, :reviewer]),
      gate_concurrency: 4,
      gate_timeout: 60_000,
      oracle: Keyword.get(opts, :oracle, %{critic: :pass, reviewer: :pass})
    }
  end

  # ---------------------------------------------------------------------------
  # Unit FSM helpers (mirrors unit_termination_test.exs idiom)
  # ---------------------------------------------------------------------------

  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  defp start_scheduler(name) do
    start_supervised!(
      {@scheduler, name: name, w_cap: 10},
      id: name
    )
  end

  defp spawn_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Test 1 - Unit FSM spawn order: :test_author BEFORE :implementer (FR-4.2 / D-304)
  # ---------------------------------------------------------------------------

  describe "FR-4.2 / D-304: Unit FSM enforces :test_author spawned before :implementer" do
    @tag :fr_4_2
    @tag :d_304
    test "FR-4.2: worker_fun(:test_author) is called before worker_fun(:implementer); :implementing is unreachable until oracle work_ready" do
      test_pid = self()
      unit_id = "u-oracle-order-#{System.unique_integer([:positive])}"
      scheduler_name = :"sched_oracle_order_#{System.unique_integer([:positive])}"
      sup_name = :"sup_oracle_order_#{System.unique_integer([:positive])}"

      start_scheduler(scheduler_name)
      start_supervised!({@unit_supervisor, name: sup_name}, id: sup_name)

      # Recording worker_fun: sends {:role_called, role} to the test mailbox
      # so we can assert the sequence without relying on wall-clock races.
      recording_worker_fun = fn role ->
        send(test_pid, {:role_called, role})
        {:ok, spawn_worker()}
      end

      opts = [
        unit_id: unit_id,
        declared_scope: empty_scope(),
        hash: "hash-fr4-#{unit_id}",
        scheduler: scheduler_name,
        report_to: test_pid,
        worker_fun: recording_worker_fun,
        gate_fun: fn _coord -> :pass end,
        merge_fun: fn _uid, _hash -> :queued end,
        timeouts: [state_timeout_ms: 5_000]
      ]

      unit_pid = @unit_supervisor.start_unit(sup_name, opts)
      assert is_pid(unit_pid)

      # The Unit MUST call worker_fun(:test_author) first (oracle state entry,
      # unit.ex lines 245-268).
      assert_receive {:role_called, :test_author}, 2_000,
                     "FR-4.2: Unit FSM MUST call worker_fun(:test_author) first — " <>
                       "the :oracle state is the first worker-spawning state " <>
                       "(unit.ex lines 245-268). No :test_author call received within 2s."

      # :implementing state is UNREACHABLE until the oracle work_ready event fires.
      # Before we send work_ready, :implementer MUST NOT be called.
      refute_receive {:role_called, :implementer}, 200,
                     "FR-4.2: worker_fun(:implementer) MUST NOT be called before the " <>
                       "oracle worker emits {:work_ready, ...}. The :implementing state is " <>
                       "structurally unreachable until oracle transitions on work_ready " <>
                       "(unit.ex lines 273-286, 294-298)."

      # Obtain the current oracle state so we can send the right completion event.
      :timer.sleep(50)
      {oracle_state, oracle_data} = :sys.get_state(unit_pid)

      assert oracle_state == :oracle,
             "FR-4.2: Unit FSM MUST be in :oracle state after spawning :test_author. " <>
               "Got: #{inspect(oracle_state)}"

      worker_id = Map.get(oracle_data, :worker_id)
      worker_pid = Map.get(oracle_data, :worker_pid)
      assert is_pid(worker_pid), "FR-4.2: :worker_pid must be populated in oracle state data"

      # Deliver work_ready to advance oracle -> implementing.
      if is_binary(worker_id) do
        # 3-tuple seam (D-326): work_ready keyed by worker_id
        send(unit_pid, {:work_ready, worker_id, "branch-oracle", "sha-oracle"})
      else
        # 2-tuple seam (legacy): worker_done
        send(unit_pid, {:worker_done, worker_pid})
      end

      # NOW :implementer must be called (implementing state entry, unit.ex lines 385-408).
      assert_receive {:role_called, :implementer}, 2_000,
                     "FR-4.2: Unit FSM MUST call worker_fun(:implementer) after oracle " <>
                       "work_ready. The :implementing state entry spawns the implementer " <>
                       "worker (unit.ex lines 385-408). No :implementer call within 2s " <>
                       "after work_ready."
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 - Gate identity check: same-identity => rejected (D-304 / AC-3)
  # ---------------------------------------------------------------------------

  describe "FR-4.2 / D-304 / AC-3: Gate.run/1 rejects same-identity oracle authorship" do
    @tag :fr_4_2
    @tag :d_304
    @tag :ac_3
    test "D-304 / AC-3: run/1 returns %Verdict{status: :fail} when test_author_id == implementer_id",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      # Build a Request where the gating-test author is the SAME agent as the
      # implementer. D-304 / HR-7 requires author(test_g) != author(impl); when
      # they are equal, Gate.run/1 MUST return a :fail verdict.
      #
      # The Request struct MUST carry :test_author_id and :implementer_id.
      # On THIS branch those fields do NOT exist; struct!/2 raises KeyError /
      # ArgumentError. That failure IS the correct fail-before state.
      req =
        struct!(@request_mod, %{
          unit: "pr-fr42-oracle-sep",
          diff: diff_for(repo),
          frozen_paths: repo.gating_paths,
          policy_pin: policy_pin(),
          workspace: repo.dir,
          merge_base: repo.merge_base,
          hash: repo.head,
          run: "run-fr42",
          ledger: writer,
          # Identity fields required by D-304 / HR-7.
          # SAME value for both => same-identity oracle violation => gate MUST fail.
          test_author_id: "agent-abc123",
          implementer_id: "agent-abc123"
        })

      verdict = @gate.run(req)

      assert verdict.status == :fail,
             "D-304 / AC-3: Gate.run/1 MUST return %Verdict{status: :fail} when " <>
               "test_author_id == implementer_id (same-identity oracle authorship). " <>
               "The identity predicate author(test_g) != author(impl) MUST be asserted " <>
               "at gate time (D-304 / HR-7). Got: #{inspect(verdict)}"

      # The oracle-separation rejection must be surfaced as a named half in the
      # verdict so the critic can see the specific failure mode.
      oracle_sep_half =
        Enum.find([:oracle_separation, :d_304, :identity], fn half ->
          Map.get(verdict.halves, half) == :fail
        end)

      assert oracle_sep_half != nil,
             "D-304 / AC-3: Gate.run/1 verdict MUST carry an oracle-separation half " <>
               "result (e.g. :oracle_separation, :d_304, or :identity) set to :fail " <>
               "when same-identity authorship is detected. Got halves: #{inspect(verdict.halves)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 - Gate identity check: distinct-identity => NOT rejected (D-304 / AC-3)
  # ---------------------------------------------------------------------------

  describe "FR-4.2 / D-304 / AC-3: Gate.run/1 does not reject distinct-identity authorship" do
    @tag :fr_4_2
    @tag :d_304
    @tag :ac_3
    test "D-304 / AC-3: run/1 does not add an oracle-separation :fail when test_author_id != implementer_id",
         %{writer: writer, fixture_root: root} do
      repo = build_genuine_repo(root)

      # Distinct identities: no oracle-separation violation should be raised.
      req =
        struct!(@request_mod, %{
          unit: "pr-fr42-oracle-sep-distinct",
          diff: diff_for(repo),
          frozen_paths: repo.gating_paths,
          policy_pin: policy_pin(),
          workspace: repo.dir,
          merge_base: repo.merge_base,
          hash: repo.head,
          run: "run-fr42-distinct",
          ledger: writer,
          # DISTINCT identities => no oracle-separation violation.
          test_author_id: "agent-test-author-111",
          implementer_id: "agent-implementer-222"
        })

      verdict = @gate.run(req)

      # Distinct identities + genuine diff => gate MUST pass (oracle halves are
      # stubbed :pass via policy_pin).
      assert verdict.status == :pass,
             "D-304 / AC-3: Gate.run/1 MUST NOT add an oracle-separation :fail when " <>
               "test_author_id != implementer_id. Distinct authorship is the expected " <>
               "case and MUST NOT penalise a genuine PR. Got: #{inspect(verdict)}"
    end
  end
end

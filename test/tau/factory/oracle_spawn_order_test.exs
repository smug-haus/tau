defmodule Tau.Factory.OracleSpawnOrderTest do
  @moduledoc """
  Gating test for issue #570 — D-304 mechanism conformance (cited, SPEC-FACTORY-FLEET
  §4 B8 / SPEC-FACTORY-GATE D-304):

  WorkerSupervisor.spawn/5 MUST enforce the oracle-separation mechanism (INV-5):
    (a) Spawn-order: reject `:implementer` when no `:test_author` is registered.
    (b) Identity: record author_id (HR-7) and reject same-identity oracle+subject.

  ## The invariant (AC-11, SPEC-FACTORY-FLEET / D-304 mechanism)

  D-304 (SPEC-FACTORY-GATE) defines two sub-mechanisms the fleet enforces:

    (a) The `:test_author` worker is spawned and its gating-test path set is frozen
        before any `:implementer` is spawned (spawn-order ordering constraint).
    (b) The author identity of every worker is recorded (HR-7), and a gating test
        whose authoring identity is the implementer is rejected — i.e.
        `author(test_author_worker) != author(implementer_worker)`.

  SPEC-FACTORY-FLEET §4 B8 states: "The fleet enforces the mechanism of INV-5:
  spawn `:test_author` first, freeze its gating-test path set before any
  `:implementer`, and record the author identity of every worker in the Ledger
  (HR-7)."

  SPEC-FACTORY-FLEET AC-11 names this test file (`oracle_spawn_order_test.exs`)
  as the conformance test: "the `:test_author` worker is spawned and its path set
  frozen before any `:implementer`, and each worker's author identity is recorded;
  same-identity oracle/subject is rejected at the cited gate."

  ## The defect (issue #570 evidence — repaired gating test)

  The original gating test only exercised sub-mechanism (b) (same-identity
  rejection), which the implementation already satisfies. It did NOT test the
  spawn-order constraint of sub-mechanism (a): that any `:implementer` spawn
  attempted when NO `:test_author` is registered in the same registry MUST be
  rejected with `{:error, :no_test_author_registered}`.

  Current `WorkerSupervisor.spawn/5` has no such guard — it accepts the
  `:implementer` spawn unconditionally when no `:test_author` is present,
  returning `{:ok, worker_id}` instead of `{:error, :no_test_author_registered}`.
  This makes the spawn-order portion of D-304 mechanism (a) completely absent.

  ## Required fix

  `WorkerSupervisor.spawn/5` MUST:
    1. When `role` is `:implementer`, check the registry for any registered
       `:test_author` worker (regardless of `:author_id`).
    2. If none exists, return `{:error, :no_test_author_registered}` — the
       spawn-order constraint (sub-mechanism (a)).
    3. Additionally retain the same-identity guard (sub-mechanism (b)).

  ## AC linkage
    - D-304 (mechanism, cited; SPEC-FACTORY-FLEET §4 B8 / SPEC-FACTORY-GATE D-304)
    - AC-11 (SPEC-FACTORY-FLEET)
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :d_304

  alias Tau.Factory.Ledger.Writer, as: LedgerWriter
  alias Tau.Factory.WorkspaceJanitor
  alias Tau.Factory.WorkerRegistry
  alias Tau.Factory.WorkerSupervisor

  # ---------------------------------------------------------------------------
  # Hermetic git repo helper
  # ---------------------------------------------------------------------------

  defp setup_git_repo(tmp_dir) do
    repo_dir = Path.join(tmp_dir, "repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_dir)

    git = fn args ->
      System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true)
    end

    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])
    {sha, 0} = git.(["rev-parse", "HEAD"])

    %{repo_dir: repo_dir, base_ref: String.trim(sha)}
  end

  defp slow_agent_bin(tmp_dir, suffix \\ "") do
    bin_path = Path.join(tmp_dir, "slow_agent_oso#{suffix}")

    File.write!(bin_path, """
    #!/bin/sh
    exec cat
    """)

    File.chmod!(bin_path, 0o755)
    bin_path
  end

  defp start_ledger(tmp_dir, tag) do
    n = System.unique_integer([:positive])
    db_path = Path.join(tmp_dir, "ledger_oso_#{tag}_#{n}.db")
    name = :"ledger_oso_#{tag}_#{n}"

    {:ok, _} = start_supervised({LedgerWriter, db_path: db_path, name: name}, id: :"lwriter_#{n}")
    name
  end

  defp start_janitor(ledger, tag, report_to) do
    n = System.unique_integer([:positive])
    name = :"oso_jan_#{tag}_#{n}"

    {:ok, pid} =
      start_supervised(
        {WorkspaceJanitor, [ledger: ledger, name: name, report_to: report_to]},
        id: :"oso_jan_sv_#{n}"
      )

    pid
  end

  defp start_fleet(tag) do
    n = System.unique_integer([:positive])
    registry_name = :"oso_reg_#{tag}_#{n}"
    sup_name = :"oso_sup_#{tag}_#{n}"

    {:ok, _} = start_supervised({WorkerRegistry, name: registry_name}, id: :"oso_reg_sv_#{n}")

    {:ok, sup} =
      start_supervised({WorkerSupervisor, name: sup_name, registry: registry_name},
        id: :"oso_sup_sv_#{n}"
      )

    {sup, registry_name}
  end

  # ---------------------------------------------------------------------------
  # D-304 mechanism — spawn-order (sub-mechanism (a)) and author identity (b)
  # ---------------------------------------------------------------------------

  describe "D-304 mechanism — oracle spawn order + HR-7 author identity" do
    @tag :d_304
    test "D-304 AC-11: spawning :implementer when NO :test_author is registered MUST return {:error, :no_test_author_registered}" do
      # SPEC-FACTORY-FLEET §4 B8: "spawn :test_author first, freeze its gating-test
      # path set before any :implementer." This is an unconditional ordering
      # constraint — any :implementer spawn attempted while no :test_author is
      # registered in the same registry MUST be rejected, regardless of :author_id.
      #
      # This is sub-mechanism (a) of D-304. Current WorkerSupervisor.spawn/5 has
      # no such check. It only checks same-identity when :author_id is provided
      # (sub-mechanism (b)). A fresh registry with no :test_author accepts an
      # :implementer spawn unconditionally, defeating the ordering invariant (INV-5).
      #
      # Failing mode before fix: WorkerSupervisor.spawn/5 returns {:ok, worker_id}
      # instead of {:error, :no_test_author_registered}.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_oso304_ord_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d304_ord")

      ledger = start_ledger(tmp_dir, :order)
      janitor = start_janitor(ledger, :order, self())
      {sup, registry_name} = start_fleet(:order)

      # Registry is empty — no :test_author has been registered.
      # Spawn :implementer directly; the spawn-order guard MUST reject this.
      result =
        WorkerSupervisor.spawn(sup, :implementer, "implement the issue", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: "some-agent-id"
        )

      assert result == {:error, :no_test_author_registered},
             "D-304 AC-11 (spawn-order, sub-mechanism (a)): WorkerSupervisor.spawn/5 " <>
               "MUST return {:error, :no_test_author_registered} when an :implementer " <>
               "is spawned before any :test_author is registered in the same registry. " <>
               "SPEC-FACTORY-FLEET §4 B8: ':test_author first, freeze path set before " <>
               "any :implementer'. " <>
               "Got: #{inspect(result)}"
    end

    @tag :d_304
    test "D-304 AC-11: spawning :implementer with same :author_id as a :test_author MUST return {:error, :same_identity_oracle_subject}" do
      # This test exercises the user-facing boundary WorkerSupervisor.spawn/5.
      #
      # D-304 sub-mechanism (b): the fleet MUST record the author identity of
      # every worker (HR-7) and MUST reject an implementer spawn whose author_id
      # matches an already-registered test_author worker.
      #
      # The shared author_id simulates the same agent identity authoring both the
      # gating test AND the implementation — the oracle-separation failure mode.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_oso304_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d304_ta")

      ledger = start_ledger(tmp_dir, :same_id)
      janitor = start_janitor(ledger, :same_id, self())
      {sup, registry_name} = start_fleet(:same_id)

      # Stable logical identity of the spawning agent (NOT the per-spawn worker_id UUID).
      shared_author_id = "agent-identity-abc123"

      # Step 1: spawn the :test_author with the shared author identity.
      # D-304 mechanism (a): test_author is spawned first.
      ta_result =
        WorkerSupervisor.spawn(sup, :test_author, "write the gating test", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: shared_author_id
        )

      assert {:ok, _ta_worker_id} = ta_result,
             "D-304: spawning :test_author with :author_id must succeed. Got: #{inspect(ta_result)}"

      # Step 2: attempt to spawn an :implementer with the SAME author identity.
      # D-304 mechanism (b): same-identity oracle/subject MUST be rejected.
      # The WorkerSupervisor must detect that shared_author_id already authored
      # a :test_author worker and return {:error, :same_identity_oracle_subject}.
      impl_result =
        WorkerSupervisor.spawn(sup, :implementer, "implement the issue", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: shared_author_id
        )

      assert impl_result == {:error, :same_identity_oracle_subject},
             "D-304 (AC-11 / HR-7): WorkerSupervisor.spawn with :implementer and the " <>
               "same :author_id as an already-registered :test_author MUST return " <>
               "{:error, :same_identity_oracle_subject}. This is sub-mechanism (b) of " <>
               "D-304 oracle separation — the same agent identity MUST NOT author both " <>
               "the gating test and the implementation. " <>
               "Got: #{inspect(impl_result)}"
    end

    @tag :d_304
    test "D-304 AC-11: :implementer with a DIFFERENT :author_id from the :test_author is accepted" do
      # Negative case: distinct identities do NOT trigger the same-identity guard.
      # This confirms the guard is identity-scoped, not role-scoped.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_oso304b_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin_ta = slow_agent_bin(tmp_dir, "_d304b_ta")
      agent_bin_impl = slow_agent_bin(tmp_dir, "_d304b_impl")

      ledger = start_ledger(tmp_dir, :diff_id)
      janitor = start_janitor(ledger, :diff_id, self())
      {sup, registry_name} = start_fleet(:diff_id)

      test_author_id = "agent-test-author-xyz"
      implementer_id = "agent-implementer-456"

      # Spawn :test_author with one identity.
      ta_result =
        WorkerSupervisor.spawn(sup, :test_author, "write the gating test", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin_ta,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: test_author_id
        )

      assert {:ok, _} = ta_result,
             "D-304: :test_author spawn with distinct :author_id must succeed. Got: #{inspect(ta_result)}"

      # Spawn :implementer with a DIFFERENT identity — must succeed.
      impl_result =
        WorkerSupervisor.spawn(sup, :implementer, "implement the issue", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin_impl,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: implementer_id
        )

      assert {:ok, _impl_worker_id} = impl_result,
             "D-304 (AC-11): :implementer with a distinct :author_id from :test_author MUST " <>
               "be accepted — the oracle-separation guard must NOT block distinct identities. " <>
               "Got: #{inspect(impl_result)}"
    end

    @tag :d_304
    test "D-304 AC-11: :author_id is recorded in the WorkerRegistry per-worker (HR-7)" do
      # Verifies sub-mechanism (b)'s prerequisite: that the fleet actually records
      # author identity in the Registry so the Gate can query it at gate time.
      # The Registry must store the author_id as metadata alongside the role.

      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_oso304c_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      %{repo_dir: repo_dir, base_ref: base_ref} = setup_git_repo(tmp_dir)
      agent_bin = slow_agent_bin(tmp_dir, "_d304c_ta")

      ledger = start_ledger(tmp_dir, :record)
      janitor = start_janitor(ledger, :record, self())
      {sup, registry_name} = start_fleet(:record)

      author_id = "agent-identity-rec-test"

      {:ok, worker_id} =
        WorkerSupervisor.spawn(sup, :test_author, "write the gating test", base_ref,
          repo_dir: repo_dir,
          agent_bin: agent_bin,
          registry: registry_name,
          report_to: self(),
          janitor: janitor,
          author_id: author_id
        )

      # Give the worker time to start and register.
      # (Worker.init/1 registers via {:via, Registry, {registry, worker_id}})
      Process.sleep(100)

      # The Registry metadata for this worker_id MUST include the author_id
      # so the Gate can evaluate author(test_g) ≠ author(impl) at gate time.
      registry_entries = Registry.lookup(registry_name, worker_id)

      # At minimum the worker must be registered (it may still be running or
      # may have stopped; the author_id recording check is the key assertion).
      refute registry_entries == [],
             "D-304 (AC-11 HR-7): worker #{inspect(worker_id)} must be registered in " <>
               "#{inspect(registry_name)} after spawn. Registry is empty — either the " <>
               "worker did not start or did not register."

      [{_pid, metadata}] = registry_entries

      # The metadata must carry the author_id so the Gate can query it.
      # HR-7: "the author identity of every worker is recorded."
      # The standard Elixir Registry stores a single value per key; the worker
      # must register with metadata that includes :author_id.
      assert is_map(metadata) && Map.has_key?(metadata, :author_id),
             "D-304 (AC-11 HR-7): WorkerRegistry metadata for worker #{inspect(worker_id)} " <>
               "MUST include :author_id key so the Gate can compare author(test_g) ≠ " <>
               "author(impl) at gate time. " <>
               "Metadata: #{inspect(metadata)}"

      assert metadata[:author_id] == author_id,
             "D-304 (AC-11 HR-7): WorkerRegistry metadata :author_id MUST match the " <>
               ":author_id passed to WorkerSupervisor.spawn/5. " <>
               "Expected: #{inspect(author_id)}, got: #{inspect(metadata[:author_id])}"
    end
  end
end

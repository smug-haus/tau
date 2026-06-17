defmodule Tau.Factory.LedgerSingleNodeGuardTest do
  @moduledoc """
  Gating test for issue #606 (INV-README-OTP5 — control plane MUST be single-node).

  INV-README-OTP5 statement:
    "The control plane MUST be single-node; M and L are the consistency core
     that must never be naively clustered; only worker execution scales out via
     an explicit queue boundary. Falsified by: M or L being
     distributed/clustered without an explicit consensus mechanism, or worker
     execution scaling without an explicit queue boundary."

  Source: audit finding #606 (PARTIAL verdict).

  ## What is already satisfied

  - M (MergeAuthority): `start_link/1` accepts `node_list_fun:` and returns
    `{:error, {:multi_node_detected, nodes}}` when nodes are visible. This half
    is tested by `merge_single_node_guard_test.exs` (INV-ST-11).

  - Worker-scaling queue boundary: `Tau.Factory.Scheduler.admit/3` gates on
    `map_size(F) < w_cap` before spawning any worker. Tested by
    `scheduler_test.exs` (D-312).

  ## The gap — L (Ledger.Writer) has no boot guard

  `Tau.Factory.Ledger.Writer.start_link/1` currently accepts only:
    - `:db_path` (required)
    - `:name` (optional)

  It does NOT accept a `node_list_fun:` option and has no code that calls
  `Node.list/0` during init. Two BEAM nodes could each start their own
  Ledger.Writer, writing to the same or separate SQLite files; under
  partition both writers diverge silently — a split-brain on the consistency
  core (D-315, INV-16, CON-1..7).

  ## Conformant implementation

  `Tau.Factory.Ledger.Writer.start_link/1` MUST:
    1. Accept a `node_list_fun: (-> [node()])` option (default: `&Node.list/0`)
       so the check is injectable for test isolation.
    2. Call `node_list_fun.()` during startup (before the GenServer init
       completes).
    3. Return `{:error, {:multi_node_detected, nodes}}` (or equivalent error
       tuple) when `node_list_fun.()` is non-empty.
    4. Return `{:ok, pid}` (normal startup) when `node_list_fun.()` returns [].

  ## Boundary exercised

  `Tau.Factory.Ledger.Writer.start_link/1` — the real user-facing entry point.
  No hand-built struct; no injected seam that bypasses `init/1`.

  ## Failure mode before implementation

  `Ledger.Writer.start_link/1` does not accept `node_list_fun:` and has no
  multi-node check. It calls `GenServer.start_link/3` unconditionally, so
  the process starts successfully and returns `{:ok, pid}` when it MUST
  return `{:error, _}`. The `refute match?({:ok, _}, result)` assertion
  therefore fails.

  AC / D-NNN linkage: @tag :inv_readme_otp5
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_db_path do
    tmp_dir = Briefly.create!(type: :directory)
    Path.join(tmp_dir, "ledger_test.db")
  end

  # ---------------------------------------------------------------------------
  # INV-README-OTP5: Ledger.Writer MUST refuse to start when BEAM nodes visible
  # ---------------------------------------------------------------------------

  describe "INV-README-OTP5 — Ledger.Writer (L) MUST refuse startup when connected BEAM nodes are visible" do
    @tag :inv_readme_otp5
    test "INV-README-OTP5: start_link with node_list_fun returning non-empty list MUST return {:error, _}" do
      db_path = tmp_db_path()
      writer_name = :"test_ledger_otp5_#{System.unique_integer([:positive])}"

      simulated_peers = [:"peer_a@remote.example", :"peer_b@remote.example"]

      opts = [
        db_path: db_path,
        name: writer_name,
        # Inject simulated distributed-mode: two peer nodes are visible.
        # A conformant Ledger.Writer MUST refuse to start under this condition.
        node_list_fun: fn -> simulated_peers end
      ]

      # INV-README-OTP5: Ledger.Writer is the durable consistency core (L).
      # Two instances on different BEAM nodes sharing the same source of truth
      # produce two divergent solution trees — a conservation-law (CON-1..7)
      # violation and a direct falsification of INV-16 (Durable factory state).
      # The conformant behaviour is to refuse startup and return {:error, _}.
      #
      # CURRENT GAP: Ledger.Writer.start_link/1 does not accept node_list_fun;
      # it calls GenServer.start_link/3 unconditionally and returns {:ok, pid}.
      # The assertion below FAILS on the current implementation.
      result = @writer.start_link(opts)

      # Clean up any process that happened to start despite the guard being absent.
      case result do
        {:ok, pid} ->
          on_exit(fn ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
          end)

        _ ->
          :ok
      end

      # FAILING ASSERTION (INV-README-OTP5):
      # L MUST NOT start when node_list_fun.() returns a non-empty peer list.
      refute match?({:ok, _}, result),
             "INV-README-OTP5: Ledger.Writer.start_link/1 MUST return {:error, _} when " <>
               "node_list_fun.() returns non-empty connected nodes #{inspect(simulated_peers)}. " <>
               "Two Ledger.Writer processes on different BEAM nodes write divergent solution trees, " <>
               "violating INV-16 (Durable factory state), INV-README-OTP5 (single-node control plane), " <>
               "and CON-1..7. Conformant implementation: accept node_list_fun: (-> [node()]) option " <>
               "(default &Node.list/0), call it in start_link/1 or init/1, and return " <>
               "{:error, {:multi_node_detected, nodes}} when non-empty. " <>
               "Got: #{inspect(result)}."
    end

    @tag :inv_readme_otp5
    test "INV-README-OTP5: start_link with node_list_fun returning [] MUST succeed (single-node BEAM)" do
      # Positive case: the guard MUST NOT block startup on a genuine single-node
      # deployment. node_list_fun.() returns [] — no peers visible.
      db_path = tmp_db_path()
      writer_name = :"test_ledger_otp5_pos_#{System.unique_integer([:positive])}"

      opts = [
        db_path: db_path,
        name: writer_name,
        node_list_fun: fn -> [] end
      ]

      result = @writer.start_link(opts)

      case result do
        {:ok, pid} ->
          on_exit(fn ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
          end)

        _ ->
          :ok
      end

      assert match?({:ok, _}, result),
             "INV-README-OTP5: Ledger.Writer.start_link/1 MUST succeed when node_list_fun.() " <>
               "returns [] (no connected nodes — genuine single-node BEAM). Got: #{inspect(result)}."
    end
  end
end

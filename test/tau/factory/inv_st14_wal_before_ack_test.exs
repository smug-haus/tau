defmodule Tau.Factory.InvSt14WalBeforeAckTest do
  @moduledoc """
  Gating test for issue #562 — INV-ST-14 (Clause B) / WorkspaceJanitor.register/6
  dynamic-name fallback.

  ## Invariant

  WorkspaceJanitor.register/6 MUST accept a `janitor` argument that is a dynamic
  atom not currently registered in the process registry and route the call to
  `__MODULE__` (the singleton janitor). Without the #562 fix, passing an
  unregistered atom causes `GenServer.call/2` to exit with `{:noproc, ...}`,
  breaking any caller that derives the janitor name dynamically (e.g. a
  test-scope name or a per-PR atom) while the production janitor is registered as
  `Tau.Factory.WorkspaceJanitor`.

  ## Fail-before guarantee

  On origin/main, `register/6` calls `GenServer.call(janitor, ...)` directly. If
  `janitor` is an unregistered atom, the GenServer call exits with `:noproc` and
  the `assert result == {:ok, :ok}` assertion FAILS, confirming mutation sense.

  ## AC / D-NNN linkage

    - INV-ST-14 (Clause B) — WorkspaceJanitor.register/6 dynamic-name fallback
    - #562 — dynamic-name fallback: unregistered atom routes to __MODULE__
  """

  use ExUnit.Case, async: false

  @moduletag :inv_st_14
  @moduletag :capture_log

  @janitor Tau.Factory.WorkspaceJanitor
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # INV-ST-14 (Clause B) — register/6 dynamic-name fallback
  # ---------------------------------------------------------------------------
  #
  # The fix in #562: when the caller passes a dynamic atom that is NOT registered
  # (GenServer.whereis/1 returns nil), register/6 falls back to __MODULE__ and
  # the call succeeds. Before the fix, the call fails with :noproc.
  # ---------------------------------------------------------------------------

  describe "INV-ST-14 (Clause B) — WorkspaceJanitor.register/6 dynamic-name fallback" do
    @tag :inv_st_14
    test "#562: register/6 with unregistered dynamic atom routes to __MODULE__ (not :noproc)" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("tau_inv14_fallback_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      db_path = Path.join(tmp_dir, "ledger_#{System.unique_integer([:positive])}.db")
      ledger_sv_id = :"inv14_ledger_sv_#{System.unique_integer([:positive])}"
      ledger_name = :"inv14_ledger_#{System.unique_integer([:positive])}"

      # Start an isolated Ledger.Writer (required by WorkspaceJanitor.init/1).
      start_supervised!(
        {@writer, db_path: db_path, name: ledger_name},
        id: ledger_sv_id
      )

      # Start the WorkspaceJanitor. It always registers as __MODULE__.
      janitor_sv_id = :"inv14_jan_sv_#{System.unique_integer([:positive])}"
      janitor_name = :"inv14_jan_#{System.unique_integer([:positive])}"

      start_supervised!(
        {@janitor, ledger: ledger_name, name: janitor_name},
        id: janitor_sv_id
      )

      # Confirm the janitor is registered as __MODULE__, NOT as janitor_name.
      # This is the precondition: the dynamic atom is truly unregistered.
      assert Process.whereis(janitor_name) == nil,
             "Precondition: janitor_name should not be registered (janitor registers as __MODULE__)."

      assert Process.whereis(@janitor) != nil,
             "Precondition: WorkspaceJanitor must be registered as __MODULE__."

      # Use self() as a dummy worker pid — the janitor will monitor it.
      worker_pid = self()
      worker_id = "inv14-fallback-worker-#{System.unique_integer([:positive])}"
      ws = tmp_dir
      ns_dirs = []
      report_to = nil

      # THE LOAD-BEARING CALL: pass the UNREGISTERED dynamic atom as `janitor`.
      # On origin/main: GenServer.call(janitor_name, ...) raises {:noproc, ...}
      #   => result == {:error, {:noproc, ...}} => assertion below FAILS (gates regression).
      # After #562: register/6 detects whereis(janitor_name) == nil, falls back
      #   to __MODULE__, call succeeds, returns :ok => assertion PASSES.
      result =
        try do
          {:ok, @janitor.register(janitor_name, worker_id, worker_pid, ws, ns_dirs, report_to)}
        catch
          :exit, reason -> {:error, reason}
        end

      assert result == {:ok, :ok},
             ~s[INV-ST-14 Clause B / #562 VIOLATED: WorkspaceJanitor.register/6 with an ] <>
               ~s[unregistered dynamic atom must fall back to __MODULE__ and return :ok. ] <>
               ~s[Got: #{inspect(result)}. ] <>
               ~s[On origin/main this call exits with :noproc because no fallback exists. ] <>
               ~s[The #562 fix routes GenServer.whereis(janitor) == nil to __MODULE__.]
    end
  end
end

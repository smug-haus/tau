defmodule Tau.Factory.D321MainSyncRetryTest do
  @moduledoc """
  Gating test for D-321 — full conformant behaviour of the main-sync retry path.

  Issue #580 (D-321) audit finding: the `halting → halted` transition MUST confirm
  `main == origin/main` before notifying `:on_halted`. Two clauses of D-321 are
  verified by `kill_switch_conformance_test.exs`:
    (a) `main_synced_fun` is called before transitioning to `:halted`, and
    (b) the coordinator does NOT transition when `main_synced_fun` returns false.

  This test covers the THIRD clause of full D-321 conformance, which the existing
  tests do not exercise:

    (c) **Retry path**: when `main_synced_fun` initially returns `false` but later
        returns `true`, the Coordinator MUST eventually reach `:halted`. The spec
        docstring states: "If it returns `false`, the Coordinator stays in `:halting`
        and retries the sync check on the next drain attempt."

  Currently `halting(:internal, :drain, ...)` with a false `main_synced_fun` does
  only `{:keep_state, data}` — no scheduled retry event is emitted, so the coordinator
  stays stuck in `:halting` forever. The retry path has no executable enforcement.

  Current failure mode: `assert_receive :coordinator_halted` times out — the
  coordinator never re-checks main-sync after the first false result.

  See `docs/spec/SPEC-FACTORY-CORE.md` §4, D-321.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  @coordinator Tau.Factory.Coordinator
  @kill_switch Tau.Factory.KillSwitch

  defp unique_name(base) do
    suffix = System.unique_integer([:positive])
    :"#{base}_#{suffix}"
  end

  # ---------------------------------------------------------------------------
  # D-321 — main-sync RETRY path (#580)
  #
  # Full conformant behaviour (SPEC-FACTORY-CORE §4 D-321):
  #   "halting → halted fires only with main synced and ¬mid_merge."
  #   "If it returns false, the Coordinator stays in :halting and retries the
  #    sync check on the next drain attempt."
  #
  # The Coordinator MUST NOT hang in :halting indefinitely when main_synced_fun
  # transitions false → true. It must re-probe main_synced_fun periodically and
  # complete the halting → halted transition once sync is confirmed.
  #
  # Current failure mode: coordinator gets stuck in :halting (no retry event is
  # scheduled) → assert_receive times out (assertion failure).
  # ---------------------------------------------------------------------------

  @tag :d_321
  test "D-321 (main-sync retry): Coordinator eventually halts after main_synced_fun transitions false → true" do
    coord_name = unique_name(:coord_d321_retry)
    on_halted = self()

    # Start with main NOT synced; flip to synced after a short delay.
    {:ok, synced_flag} = Agent.start_link(fn -> false end)

    main_synced_fun = fn ->
      Agent.get(synced_flag, & &1)
    end

    start_supervised!(
      {
        @coordinator,
        name: coord_name,
        pubsub: Tau.PubSub,
        select_fun: fn -> nil end,
        drive_fun: fn _w -> :ok end,
        scheduler: nil,
        on_halted: on_halted,
        main_synced_fun: main_synced_fun
      },
      id: coord_name
    )

    # Start a KillSwitch and trigger halt.
    ks_name = unique_name(:ks_d321_retry)

    start_supervised!(
      {@kill_switch, name: ks_name, pubsub: Tau.PubSub},
      id: ks_name
    )

    :ok = @kill_switch.request_halt(ks_name)

    # Verify the coordinator enters :halting but does not yet reach :halted
    # (main_synced_fun returns false).
    Process.sleep(100)

    refute_received :coordinator_halted,
                    "D-321 (main-sync retry): coordinator halted before main was synced"

    # Now simulate main becoming synced.
    Agent.update(synced_flag, fn _ -> true end)

    # The Coordinator MUST detect the change and complete halting → halted.
    # Full D-321 conformant behaviour: retry the drain check when main syncs.
    # With no retry mechanism, the coordinator will hang in :halting forever.
    assert_receive :coordinator_halted,
                   2000,
                   "D-321 (main-sync retry): Coordinator did not transition to :halted after " <>
                     "main_synced_fun became true — the retry path is not implemented. " <>
                     "halting(:internal, :drain, ...) emits {:keep_state, data} with no " <>
                     "scheduled retry event; the coordinator is stuck in :halting forever once " <>
                     "main_synced_fun first returns false."
  end
end

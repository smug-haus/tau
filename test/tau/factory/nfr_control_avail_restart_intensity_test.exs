defmodule Tau.Factory.NfrControlAvailRestartIntensityTest do
  @moduledoc """
  Gating test for issue #672 — **NFR-CONTROL-AVAIL** (control-plane availability).

  ## Invariant

  `NFR-CONTROL-AVAIL` (docs/arch/02-requirements/nfrs.md): v1 control-plane
  availability — a single node-process crash is recovered by supervision +
  durable-state reload within RTO (≤ 60 s). Falsified if a node-process crash is
  not recovered within RTO.

  ## What this pins

  The `PARTIAL` verdict on NFR-CONTROL-AVAIL (issue #672) is caused by both
  `Tau.Supervisor` (application.ex:103) and `Tau.Factory.Supervisor`
  (factory/supervisor.ex:295) running at OTP-default restart intensity: 3
  restarts in 5 seconds. Exceeding 3 crashes in any 5-second window terminates
  the entire supervision tree, leaving recovery to an external process restarter —
  the RTO is unbounded and NFR-CONTROL-AVAIL is falsified.

  The conformant behaviour requires BOTH supervisors to declare explicit
  `max_restarts` / `max_seconds` values exceeding the OTP defaults (3/5 s)
  so that a transient crash-loop within the RTO window does NOT terminate the
  tree. Specifically:

  - `intensity` (max_restarts) MUST be > 3 (the OTP default), OR the
    supervising policy must be demonstrably sufficient for the 60 s RTO.
  - `period` (max_seconds) MUST be set to accommodate the RTO-relevant
    window; `period >= 60` is the direct expression of the 60 s RTO bound.

  This test asserts the stricter conformant claim: both supervisors must carry
  `period >= 60` so the intensity window aligns with the RTO.

  ## Boundary exercised

  - `Tau.Factory.Supervisor` — started via real `start_link/1` (the factory
    control-plane entry point). Its restart flags are inspected via
    `:sys.get_state/1`.
  - `Tau.Supervisor` — already running when ExUnit starts (the application boots
    the full supervision tree). Inspected via `Process.whereis(Tau.Supervisor)` +
    `:sys.get_state/1`.

  ## Fail-before validity

  Both supervisors currently carry OTP-default intensity=3, period=5. The
  assertions `period >= 60` and `intensity > 3` both fail against the current
  code, confirming oracle separation (Gate 5.3).

  ## AC / D-NNN linkage

  - NFR-CONTROL-AVAIL — both tests in this file.
  """

  use ExUnit.Case, async: false

  @moduletag :nfr_control_avail
  @moduletag :capture_log

  # OTP default supervisor restart intensity (max_restarts = 3, max_seconds = 5).
  # A supervisor running at these defaults will terminate its entire tree if any
  # child crashes more than 3 times in 5 seconds — the OTP restart explosion
  # pattern. Under NFR-CONTROL-AVAIL this leaves RTO unbounded.
  @otp_default_intensity 3

  # The RTO bound from NFR-CONTROL-AVAIL (60 s). The supervisor's `period`
  # (max_seconds) MUST align with this window so that transient crash-loops
  # within the RTO window do not terminate the tree.
  @rto_seconds 60

  # ---------------------------------------------------------------------------
  # Helper: extract supervisor flags from :sys.get_state/1.
  #
  # OTP 27 supervisor state record (supervisor.erl):
  #   {:state, name, strategy, children, dynamics, intensity, period, restarts, auto_shutdown}
  # Positions (0-based tuple element index):
  #   0 = :state (atom tag)
  #   1 = name
  #   2 = strategy
  #   3 = children
  #   4 = dynamics
  #   5 = intensity   (= max_restarts in Supervisor.init/2)
  #   6 = period      (= max_seconds  in Supervisor.init/2)
  #   7 = restarts
  #   8 = auto_shutdown
  # ---------------------------------------------------------------------------

  defp supervisor_flags(pid) do
    state = :sys.get_state(pid)

    # The OTP :supervisor state is a record tuple. Guard that we are looking at
    # the correct shape before indexing — if OTP changes the layout the guard
    # fails loudly rather than silently reading the wrong field.
    assert is_tuple(state), "NFR-CONTROL-AVAIL: :sys.get_state returned non-tuple #{inspect(state)}"

    assert elem(state, 0) == :state,
           "NFR-CONTROL-AVAIL: unexpected state tag #{inspect(elem(state, 0))}"

    # OTP 26 state record has ≥ 8 elements; OTP 27 has ≥ 12. intensity is at
    # index 5 and period at index 6 in all supported OTP versions.
    assert tuple_size(state) >= 7,
           "NFR-CONTROL-AVAIL: state tuple too small (#{tuple_size(state)} elements)"

    intensity = elem(state, 5)
    period = elem(state, 6)

    {intensity, period}
  end

  # ---------------------------------------------------------------------------
  # Test A — Tau.Supervisor (root application supervisor)
  #
  # The root supervisor runs with :rest_for_one strategy (application.ex:103).
  # Currently it carries OTP-default intensity=3, period=5. Under NFR-CONTROL-
  # AVAIL it MUST carry period >= 60 (and intensity > 3) so a transient crash-
  # loop within the 60 s RTO window does not terminate the whole application.
  # ---------------------------------------------------------------------------

  describe "NFR-CONTROL-AVAIL — Tau.Supervisor (root) restart intensity" do
    @tag :nfr_control_avail
    test "NFR-CONTROL-AVAIL: Tau.Supervisor must have max_restarts > #{@otp_default_intensity} and max_seconds >= #{@rto_seconds}" do
      root_sup = Process.whereis(Tau.Supervisor)

      assert is_pid(root_sup),
             "NFR-CONTROL-AVAIL: Tau.Supervisor must be running (application not started?)"

      {intensity, period} = supervisor_flags(root_sup)

      assert intensity > @otp_default_intensity,
             "NFR-CONTROL-AVAIL: Tau.Supervisor MUST set max_restarts > #{@otp_default_intensity} " <>
               "(the OTP default). A supervisor at intensity=#{intensity} terminates the whole " <>
               "application tree if any child crashes more than #{intensity} times in #{period} s, " <>
               "leaving control-plane recovery to an external restarter — RTO is unbounded and " <>
               "NFR-CONTROL-AVAIL is falsified. Set max_restarts to a value that accommodates " <>
               "transient crash-loops within the #{@rto_seconds} s RTO (e.g. max_restarts: 10)."

      assert period >= @rto_seconds,
             "NFR-CONTROL-AVAIL: Tau.Supervisor MUST set max_seconds >= #{@rto_seconds} " <>
               "(the NFR-CONTROL-AVAIL RTO). Current period=#{period} s means any child that " <>
               "crashes more than #{intensity} times in #{period} s kills the tree — the RTO " <>
               "window is misaligned with the 60 s recovery objective. " <>
               "Set max_seconds: #{@rto_seconds} (or higher) in Supervisor.start_link/2."
    end
  end

  # ---------------------------------------------------------------------------
  # Test B — Tau.Factory.Supervisor (factory control-plane supervisor)
  #
  # The factory supervisor runs with :rest_for_one (factory/supervisor.ex:295)
  # covering the full control subtree: LedgerWriter → Scheduler → MergeAuthority
  # → Coordinator. Currently it carries OTP-default intensity=3, period=5.
  # Under NFR-CONTROL-AVAIL, a Coordinator crash-loop > 3/5 s terminates the
  # entire factory control plane — RTO is unbounded. The conformant behaviour
  # requires period >= 60 (the RTO bound) and intensity > 3.
  # ---------------------------------------------------------------------------

  describe "NFR-CONTROL-AVAIL — Tau.Factory.Supervisor restart intensity" do
    @tag :nfr_control_avail
    test "NFR-CONTROL-AVAIL: Tau.Factory.Supervisor must have max_restarts > #{@otp_default_intensity} and max_seconds >= #{@rto_seconds}" do
      db_path = Briefly.create!(extname: ".db")
      sup_name = :"nfr_control_avail_sup_#{System.unique_integer([:positive])}"

      sup_pid =
        start_supervised!(
          {Tau.Factory.Supervisor, db_path: db_path, name: sup_name},
          id: sup_name
        )

      assert is_pid(sup_pid),
             "NFR-CONTROL-AVAIL: Tau.Factory.Supervisor must start successfully"

      {intensity, period} = supervisor_flags(sup_pid)

      assert intensity > @otp_default_intensity,
             "NFR-CONTROL-AVAIL: Tau.Factory.Supervisor MUST set max_restarts > #{@otp_default_intensity} " <>
               "(the OTP default). A factory supervisor at intensity=#{intensity} terminates the " <>
               "entire control subtree (LedgerWriter, Scheduler, MergeAuthority, Coordinator) if " <>
               "any child crashes more than #{intensity} times in #{period} s — the factory control " <>
               "plane goes dark and NFR-CONTROL-AVAIL is falsified. Set max_restarts to a value " <>
               "that accommodates transient crash-loops within the #{@rto_seconds} s RTO."

      assert period >= @rto_seconds,
             "NFR-CONTROL-AVAIL: Tau.Factory.Supervisor MUST set max_seconds >= #{@rto_seconds} " <>
               "(the NFR-CONTROL-AVAIL RTO bound). Current period=#{period} s: a child crashing " <>
               "more than #{intensity} times in #{period} s kills the factory control plane — " <>
               "the restart-intensity window is misaligned with the 60 s recovery objective. " <>
               "Set max_seconds: #{@rto_seconds} in Supervisor.init/2 (factory/supervisor.ex)."
    end
  end
end

defmodule Tau.Factory.EgressOrderVisibilityTest do
  @moduledoc """
  Gating test for INV-EGRESS-ORDER — outer telemetry span visibility (issue #548).

  ## Invariant

  INV-EGRESS-ORDER / D-351 / C211: every egress short-circuit MUST surface
  a visible telemetry event AND a tagged error to the caller — never a silent
  swallow (SPEC-FACTORY-GOV §4 B1 / C211).

  SPEC-FACTORY-GOV §4 B9 enumerates the required paired spans; the first row is:

      [:tau,:factory,:egress,:call]  | Egress (C1) | provider, layer-rejection, tokens, cost

  This span is the OUTER coverage span for the entire `Egress.call/3` call.
  Without it, a short-circuit that fires BEFORE a layer-specific event (e.g. in
  a future refactor that reorders the telemetry emit and the guard) is unobservable
  to monitoring systems that join on the outer span — violating C211's
  "never a silent swallow" guarantee at the call level.

  ## What is tested

  **INV-EGRESS-ORDER / C211 outer span**: `Egress.call/3` MUST emit a
  `[:tau,:factory,:egress,:call]` telemetry event (outer span) for every call —
  both for short-circuit paths (`:rate_limited`, `:circuit_open`,
  `:budget_exhausted`) and for the happy path (provider called).

  The test verifies the happy path: when all guards pass, the outer
  `[:tau,:factory,:egress,:call]` span is emitted with metadata including the
  `provider` key.

  ## Failure expectation

  The current `Tau.Factory.Egress.call/3` implementation emits ONLY per-layer
  events (`[:tau,:factory,:egress,:rate_limited]`, `[:tau,:circuit_breaker,:open]`,
  `[:tau,:factory,:egress,:budget_exhausted]`). It does NOT emit the outer
  `[:tau,:factory,:egress,:call]` span required by SPEC-FACTORY-GOV §4 B9.

  This test therefore FAILS against the current implementation with an
  `assert_received` failure — no outer span event arrives.

  ## AC / invariant linkage

  - INV-EGRESS-ORDER — tagged `:inv_egress_order`
  - D-351 (visible short-circuits, C211) — tagged `:d_351`
  """

  use ExUnit.Case, async: true

  @moduletag :inv_egress_order
  @moduletag :d_351
  @moduletag :capture_log

  @egress Tau.Factory.Egress

  # ---------------------------------------------------------------------------
  # Stub provider — healthy (no tripped breaker, no RL, no budget restriction)
  # ---------------------------------------------------------------------------

  defmodule StubProviderVisibility do
    @moduledoc false
    @behaviour Tau.Provider

    def stream(_messages, _opts, _ctx), do: {:ok, [%{type: :done}]}
    def context_window(_model), do: 200_000
    def name, do: "stub-visibility"
    def models, do: ["stub-visibility-model"]
    def default_model, do: "stub-visibility-model"
    def capabilities, do: []
  end

  # ---------------------------------------------------------------------------
  # Test: outer [:tau,:factory,:egress,:call] span is emitted on every call
  # ---------------------------------------------------------------------------

  describe "INV-EGRESS-ORDER / C211 — outer [:tau,:factory,:egress,:call] span required for full visibility" do
    @tag :inv_egress_order
    @tag :d_351
    test "INV-EGRESS-ORDER / C211: Egress.call/3 emits [:tau,:factory,:egress,:call] outer span on happy path" do
      # Arrange: subscribe to the outer egress span before the call.
      test_pid = self()
      handler_id = "egress_order_visibility_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :egress, :call],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:egress_call_span, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      req = %{messages: [], opts: %{model: "stub-visibility-model"}}

      # Act: call the real Egress chokepoint (no guards active — happy path).
      _result = @egress.call(StubProviderVisibility, req, %{})

      # Assert: the outer [:tau,:factory,:egress,:call] span MUST have been emitted.
      #
      # SPEC-FACTORY-GOV §4 B9 requires this span for every `Egress.call/3`
      # invocation. Without it, a monitoring system cannot observe that an egress
      # call occurred at all — C211's "never a silent swallow" guarantee is violated
      # at the call level even if per-layer events were emitted.
      #
      # FAILURE MODE (current implementation): the current `Egress.call/3` emits
      # only per-layer events; it does NOT emit `[:tau,:factory,:egress,:call]`.
      # This assert_received therefore FAILS — the message is never sent.
      assert_received {:egress_call_span, metadata},
                      "INV-EGRESS-ORDER / C211 violated: Egress.call/3 did not emit " <>
                        "[:tau,:factory,:egress,:call] outer span required by " <>
                        "SPEC-FACTORY-GOV §4 B9 / D-351 / C211. The current implementation " <>
                        "emits only per-layer events (rate_limited, circuit_open, budget_exhausted) " <>
                        "but not the outer call span that makes every egress invocation observable."

      # The outer span metadata MUST carry the provider key (C211 / D-351).
      assert Map.get(metadata, :provider) == StubProviderVisibility,
             "INV-EGRESS-ORDER / C211: outer egress span metadata must carry :provider key; " <>
               "got: #{inspect(metadata)}"
    end
  end
end

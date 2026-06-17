defmodule Tau.Factory.EgressD351NoBypassTest do
  @moduledoc """
  Gating test for D-351 — no-bypass property (issue #666).

  ## Invariant

  D-351 (SPEC-FACTORY-GOV §4 B1): "Egress.call/3 is the single chokepoint;
  ... **no provider call bypasses it**."

  The SPEC explicitly states that `egress_chain_test.exs` must "assert a bypass
  is impossible — every provider call routes through `call/3`."  This file
  carries the no-bypass test tagged `:d_351` to satisfy that requirement for
  issue #666.

  ## Audit finding (#666)

  Issue #666 found D-351 to be NOT-YET-BUILT: the egress chain did not exist,
  so every provider call bypassed it.  The chokepoint has since been implemented
  (`Tau.Factory.Egress.call/3`), and the session path (`Tau.Session.ProviderTurn`)
  routes through it.  However, the user-facing convenience entry point
  `Tau.Provider.chat/4` still contains a fast path that bypasses Egress:

      # lib/tau/provider.ex:171
      if function_exported?(provider, :chat, 3) do
        provider.chat(messages, opts, ctx)   # <-- bypasses Egress.call/3
      else
        drain_stream(provider, messages, opts, ctx)  # uses Egress.call/3
      end

  Any provider that exports the optional `chat/3` callback can therefore be
  invoked via `Tau.Provider.chat/4` and completely bypass the three fail-closed
  guards (RateLimiter → CircuitBreaker → Budget), violating D-351.

  ## What this test asserts

  1. The user-facing entry point exercised is `Tau.Provider.chat/4` — not a
     hand-built struct nor a direct `Egress.call/3` invocation.
  2. The stub provider exports `chat/3` — this triggers the `function_exported?/2`
     fast path in the current implementation.
  3. The test asserts that a `[:tau,:factory,:egress,:call]` telemetry event is
     emitted during the call — which is only true if `Egress.call/3` was invoked.
  4. The test **FAILS** against the current implementation because `chat/4` routes
     to `provider.chat(messages, opts, ctx)` directly, emitting no egress span.

  ## Implementer requirement

  Route all `Tau.Provider.chat/4` calls — including those to providers that
  export the optional `chat/3` callback — through `Egress.call/3` before
  delegating to the provider.  All provider calls (streaming and non-streaming)
  must pass through the chokepoint to satisfy D-351's no-bypass contract.

  ## AC linkage

  - D-351 (no-bypass contract, issue #666) — every test tagged `:d_351`
  """

  use ExUnit.Case, async: true

  @moduletag :d_351
  @moduletag :capture_log

  # ---------------------------------------------------------------------------
  # Stub provider that exports chat/3 — triggers the bypass fast path in
  # Tau.Provider.chat/4 under the current implementation.
  # ---------------------------------------------------------------------------

  defmodule StubProviderWithChat do
    @moduledoc false
    @behaviour Tau.Provider

    # Exporting chat/3 triggers the bypass fast path in Tau.Provider.chat/4:
    #   if function_exported?(provider, :chat, 3), do: provider.chat(...)
    # This bypasses Egress.call/3 entirely in the current implementation.
    def chat(_messages, _opts, _ctx) do
      {:ok,
       %Tau.Message.Assistant{
         content: [%{type: "text", text: "stub response"}],
         timestamp: DateTime.utc_now(),
         stop_reason: :end_turn,
         model: "stub-chat-model"
       }}
    end

    # stream/3 is required by the behaviour but should NOT be reached when
    # Tau.Provider.chat/4 routes through the chat/3 fast path.
    def stream(_messages, _opts, _ctx), do: {:ok, []}

    def context_window(_model), do: 200_000
    def name, do: "stub-provider-with-chat"
    def models, do: ["stub-chat-model"]
    def default_model, do: "stub-chat-model"

    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    def configure(_opts), do: {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # D-351 / no-bypass: Tau.Provider.chat/4 must route through Egress.call/3
  # even when the provider exports chat/3
  # ---------------------------------------------------------------------------

  describe "D-351 (#666) — no-bypass: Tau.Provider.chat/4 must route through Egress.call/3 for all provider calls" do
    @tag :d_351
    test "D-351 (#666): Tau.Provider.chat/4 emits [:tau,:factory,:egress,:call] span even when provider exports chat/3" do
      # Arrange: subscribe to the egress call span before invoking the entry point.
      test_pid = self()
      handler_id = "d351_no_bypass_#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tau, :factory, :egress, :call],
        fn _event, _measurements, metadata, _config ->
          # Capture only events for our stub provider to avoid noise.
          if Map.get(metadata, :provider) == StubProviderWithChat do
            send(test_pid, {:egress_call_span, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      messages = [%Tau.Message.User{content: "hello", timestamp: DateTime.utc_now()}]
      opts = %{model: "stub-chat-model"}
      ctx = %{}

      # Act: call the REAL user-facing entry point — Tau.Provider.chat/4.
      # This is NOT a direct call to Egress.call/3; it exercises the full
      # user-facing dispatch path that must route through the chokepoint.
      result = Tau.Provider.chat(StubProviderWithChat, messages, opts, ctx)

      # Sanity: the call must succeed (the stub's chat/3 returns a valid assistant).
      assert {:ok, %Tau.Message.Assistant{}} = result,
             "D-351 (#666): expected {:ok, %Tau.Message.Assistant{}} from Tau.Provider.chat/4, " <>
               "got: #{inspect(result)}"

      # Assert: the egress chokepoint was invoked — a [:tau,:factory,:egress,:call] span
      # must have been emitted.
      #
      # FAILURE MODE (current implementation):
      # Tau.Provider.chat/4 at lib/tau/provider.ex:171 has a fast path:
      #
      #     if function_exported?(provider, :chat, 3) do
      #       provider.chat(messages, opts, ctx)   # bypasses Egress.call/3
      #     else
      #       drain_stream(...)                    # uses Egress.call/3
      #     end
      #
      # Because StubProviderWithChat exports chat/3, the fast path fires and
      # Egress.call/3 is never called.  No [:tau,:factory,:egress,:call] event
      # is emitted.  This assert_received therefore FAILS on the current branch.
      #
      # The implementer must route all Tau.Provider.chat/4 calls — including those
      # to providers that export the optional chat/3 callback — through Egress.call/3
      # to satisfy D-351's "no provider call bypasses it" contract
      # (SPEC-FACTORY-GOV §4 B1).
      assert_received {:egress_call_span, _metadata},
                      "D-351 (#666) no-bypass contract violated: Tau.Provider.chat/4 did NOT invoke " <>
                        "Egress.call/3 for a provider that exports chat/3.  The fast path at " <>
                        "lib/tau/provider.ex:171 bypasses the RateLimiter→CircuitBreaker→Budget " <>
                        "chokepoint, violating SPEC-FACTORY-GOV §4 B1 / D-351. " <>
                        "Every provider call MUST route through Egress.call/3 regardless of " <>
                        "whether the provider implements the optional chat/3 callback."
    end
  end
end

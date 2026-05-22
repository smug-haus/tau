if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.StatusBarTest do
    @moduledoc """
    Tests for `Tau.TUI.StatusBar` — the pure status surface module (#340).

    Covers:
    - AC-3: context_pct/2 formula and ~NN% fallback
    - AC-4: warn glyph at >=75%, critical glyph at >=90%
    - AC-5: compaction segment clears on :idle
    - AC-7: StreamData property tests for context_pct/2, warn_level/1, cost_summary/1
    - AC-8: graceful degradation on nil/zero inputs

    D-NNN invariants tested:
    - D-160: model/provider segment renders
    - D-162: render_text/1 never raises on valid model maps
    - D-165: warn/critical thresholds from Application.get_env
    - D-166: context_pct/2 never raises; returns nil on bad window
    - D-167: warn_level/1 monotonic in percentage
    - D-169 (S-4): context_tokens is latest turn's input_tokens, not cumulative
    """
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Tau.TUI.StatusBar

    # --- AC-3 / D-166: context_pct/2 ----------------------------------------

    describe "context_pct/2" do
      test "returns nil when tokens is nil" do
        assert StatusBar.context_pct(nil, 200_000) == nil
      end

      test "returns nil when window is nil" do
        assert StatusBar.context_pct(1000, nil) == nil
      end

      test "returns nil when window is zero" do
        assert StatusBar.context_pct(1000, 0) == nil
      end

      test "returns nil when window is negative" do
        assert StatusBar.context_pct(1000, -1) == nil
      end

      test "returns 0 when tokens is 0" do
        assert StatusBar.context_pct(0, 200_000) == 0
      end

      test "rounds to nearest integer — formula: round(tokens / window * 100)" do
        # 100_000 / 200_000 = 50.0 → 50
        assert StatusBar.context_pct(100_000, 200_000) == 50
        # 1 / 200_000 = 0.0005% → round = 0
        assert StatusBar.context_pct(1, 200_000) == 0
        # 150_001 / 200_000 → 75.0005 → 75
        assert StatusBar.context_pct(150_001, 200_000) == 75
      end

      test "clamps to 100 when tokens exceed window (avoids >100% bug — D-169/S-4)" do
        assert StatusBar.context_pct(250_000, 200_000) == 100
        assert StatusBar.context_pct(200_000, 200_000) == 100
      end

      test "AC-3: percentage matches round(input_tokens / context_window * 100) for Anthropic" do
        # Anthropic context window: 200_000
        assert StatusBar.context_pct(50_000, 200_000) == 25
      end

      test "AC-3: percentage matches formula for Gemini (large window)" do
        # Gemini 2.0 Flash: 1_048_576 tokens
        pct = StatusBar.context_pct(100_000, 1_048_576)
        assert pct == round(100_000 / 1_048_576 * 100)
      end
    end

    # --- AC-4 / D-165 / D-167: warn_level/1 ----------------------------------

    describe "warn_level/1" do
      test "returns :ok for nil" do
        assert StatusBar.warn_level(nil) == :ok
      end

      test "returns :ok below warn threshold (default 75)" do
        assert StatusBar.warn_level(0) == :ok
        assert StatusBar.warn_level(74) == :ok
      end

      test "returns :warn at warn threshold (default 75)" do
        assert StatusBar.warn_level(75) == :warn
      end

      test "returns :warn between thresholds" do
        assert StatusBar.warn_level(80) == :warn
        assert StatusBar.warn_level(89) == :warn
      end

      test "returns :critical at critical threshold (default 90)" do
        assert StatusBar.warn_level(90) == :critical
      end

      test "returns :critical above critical threshold" do
        assert StatusBar.warn_level(100) == :critical
      end

      test "AC-4: warn glyph appears in render_text at >=75%" do
        model = base_model(%{context_tokens: 150_000, context_window: 200_000})
        text = StatusBar.render_text(model)
        # 150_000/200_000 = 75% → warn glyph ⚠
        assert String.contains?(text, "⚠"), "Expected ⚠ at 75%; got: #{text}"
      end

      test "AC-4: critical glyph appears in render_text at >=90%" do
        model = base_model(%{context_tokens: 180_000, context_window: 200_000})
        text = StatusBar.render_text(model)
        # 180_000/200_000 = 90% → critical glyph ✖
        assert String.contains?(text, "✖"), "Expected ✖ at 90%; got: #{text}"
      end

      test "no glyph in render_text below warn threshold" do
        model = base_model(%{context_tokens: 10_000, context_window: 200_000})
        text = StatusBar.render_text(model)
        refute String.contains?(text, "⚠"), "No ⚠ expected at 5%"
        refute String.contains?(text, "✖"), "No ✖ expected at 5%"
      end
    end

    # --- AC-5: compaction segment --------------------------------------------

    describe "compaction segment" do
      test "shows 'compacting…' when compaction: :running" do
        model = base_model(%{compaction: :running})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "compacting…"), "Expected 'compacting…'; got: #{text}"
      end

      test "does NOT show 'compacting…' when compaction: :idle" do
        model = base_model(%{compaction: :idle})
        text = StatusBar.render_text(model)

        refute String.contains?(text, "compacting…"),
               "compacting… must be absent when :idle; got: #{text}"
      end
    end

    # --- AC-7: StreamData property tests ------------------------------------

    describe "property tests (AC-7)" do
      property "context_pct/2 always returns nil or an integer in 0..100" do
        check all(
                tokens <- one_of([constant(nil), integer(0..1_000_000)]),
                window <-
                  one_of([constant(nil), constant(0), constant(-1), integer(1..2_000_000)])
              ) do
          result = StatusBar.context_pct(tokens, window)
          assert result == nil or (is_integer(result) and result >= 0 and result <= 100)
        end
      end

      property "context_pct/2 never raises" do
        check all(
                tokens <- one_of([constant(nil), integer(-10..2_000_000)]),
                window <- one_of([constant(nil), integer(-10..2_000_000)])
              ) do
          try do
            StatusBar.context_pct(tokens, window)
            :ok
          rescue
            e -> flunk("context_pct/2 raised: #{inspect(e)}")
          end
        end
      end

      property "warn_level/1 is monotone non-decreasing in percentage" do
        # For any a <= b, warn_level(a) <= warn_level(b) in the ordering :ok < :warn < :critical
        check all(
                a <- integer(0..100),
                b <- integer(0..100)
              ) do
          la = level_to_int(StatusBar.warn_level(a))
          lb = level_to_int(StatusBar.warn_level(b))

          if a <= b do
            assert la <= lb,
                   "D-167 monotonicity: warn_level(#{a})=#{la} must be <= warn_level(#{b})=#{lb}"
          end
        end
      end

      property "warn_level/1 never raises on nil or non-negative integer" do
        check all(pct <- one_of([constant(nil), integer(0..200)])) do
          result = StatusBar.warn_level(pct)
          assert result in [:ok, :warn, :critical]
        end
      end

      property "cost_summary/1 never raises and returns a string" do
        check all(
                inp <- one_of([constant(nil), integer(0..1_000_000)]),
                out <- one_of([constant(nil), integer(0..1_000_000)]),
                cr <- one_of([constant(nil), integer(0..1_000_000)]),
                cw <- one_of([constant(nil), integer(0..1_000_000)])
              ) do
          # Test with nil
          assert is_binary(StatusBar.cost_summary(nil))

          # Test with empty map
          assert is_binary(StatusBar.cost_summary(%{}))

          # Test with a valid map where some values may be nil (graceful degradation)
          usage =
            %{
              input_tokens: inp || 0,
              output_tokens: out || 0,
              cache_read: cr || 0,
              cache_write: cw || 0
            }

          assert is_binary(StatusBar.cost_summary(usage))
        end
      end

      property "render_text/1 never raises on well-formed model maps" do
        check all(
                context_tokens <- one_of([constant(0), constant(nil), integer(0..500_000)]),
                context_window <- one_of([constant(nil), integer(1..2_000_000)]),
                compaction <- member_of([:idle, :running]),
                status <- member_of([:idle, :streaming, :sending])
              ) do
          model =
            base_model(%{
              context_tokens: context_tokens,
              context_window: context_window,
              compaction: compaction,
              status: status
            })

          try do
            result = StatusBar.render_text(model)
            assert is_binary(result)
          rescue
            e -> flunk("render_text/1 raised: #{inspect(e)}\nmodel: #{inspect(model)}")
          end
        end
      end
    end

    # --- AC-8: graceful degradation -----------------------------------------

    describe "graceful degradation (AC-8)" do
      test "renders ctx — when context_tokens is 0 (pre-first-turn)" do
        model = base_model(%{context_tokens: 0})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "ctx —"), "Expected 'ctx —' pre-first-turn; got: #{text}"
      end

      test "renders ctx — when context_tokens is nil" do
        model = base_model(%{context_tokens: nil})
        text = StatusBar.render_text(model)

        assert String.contains?(text, "ctx —"),
               "Expected 'ctx —' on nil context_tokens; got: #{text}"
      end

      test "renders ~NN% on fallback (no context_window known)" do
        # 60_000 / 120_000 (default threshold) = 50% → ~50%
        model = base_model(%{context_tokens: 60_000, context_window: nil})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "~"), "Expected '~' prefix on fallback; got: #{text}"
        assert String.contains?(text, "%"), "Expected '%' in fallback ctx; got: #{text}"
      end

      test "renders NN% (no ~) when context_window is known" do
        model = base_model(%{context_tokens: 100_000, context_window: 200_000})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "50%"), "Expected '50%'; got: #{text}"
        refute String.contains?(text, "~50%"), "No ~ expected when window known; got: #{text}"
      end

      test "renders — for usage when usage is all zeros" do
        model =
          base_model(%{usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}})

        text = StatusBar.cost_summary(model.usage)
        assert text == "—"
      end

      test "renders — for cost_summary on nil" do
        assert StatusBar.cost_summary(nil) == "—"
      end

      test "does not crash on empty usage map" do
        assert is_binary(StatusBar.cost_summary(%{}))
      end
    end

    # --- D-160: model/provider segment --------------------------------------

    describe "model segment (D-160 / AC-1)" do
      test "shows model id" do
        model = base_model(%{model: "claude-opus-4-7", provider: Tau.Providers.Anthropic})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "claude-opus-4-7"), "Expected model id; got: #{text}"
      end

      test "shows provider short name" do
        model = base_model(%{model: "claude-opus-4-7", provider: Tau.Providers.Anthropic})
        text = StatusBar.render_text(model)
        # Short name is last module component downcased: "anthropic"
        assert String.contains?(text, "anthropic"), "Expected provider short name; got: #{text}"
      end

      test "shows 'no model' fallback when model and provider are nil" do
        model = base_model(%{model: nil, provider: nil})
        text = StatusBar.render_text(model)
        assert String.contains?(text, "no model"), "Expected 'no model' fallback; got: #{text}"
      end
    end

    # --- AC-9 (regression): coding-agent segment ----------------------------

    describe "coding-agent segment (AC-9 / SPEC-CODING-AGENT §4 B1)" do
      test "includes agent label when coding_agent_label is set" do
        model = base_model(%{coding_agent_label: "Tau.CodingAgents.ClaudeCode"})
        text = StatusBar.render_text(model)

        assert String.contains?(text, "agent: Tau.CodingAgents.ClaudeCode"),
               "AC-9: coding-agent label must appear; got: #{text}"
      end

      test "no agent segment when coding_agent_label is nil" do
        model = base_model(%{coding_agent_label: nil})
        text = StatusBar.render_text(model)
        refute String.contains?(text, "agent:"), "No agent segment expected; got: #{text}"
      end
    end

    # --- helpers ------------------------------------------------------------

    defp base_model(overrides \\ %{}) do
      Map.merge(
        %{
          model: "claude-opus-4-7",
          provider: Tau.Providers.Anthropic,
          usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
          context_tokens: 0,
          context_window: 200_000,
          compaction: :idle,
          status: :idle,
          coding_agent_label: nil
        },
        overrides
      )
    end

    defp level_to_int(:ok), do: 0
    defp level_to_int(:warn), do: 1
    defp level_to_int(:critical), do: 2
  end
end

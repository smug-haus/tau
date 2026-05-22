if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.StatusSurfaceTest do
    @moduledoc """
    Tests for the status surface event wiring in `Tau.TUI.App` (#340).

    Covers:
    - on_model_swapped/2: model field updated, context_window re-resolved
    - on_compaction_started/2: compaction transitions to :running
    - on_compaction_finished/2: compaction clears to :idle (AC-5 / D-164 / S-2)
    - on_session_start_status/4: model/provider/context_window seeded from SessionStart
    - context_window dispatch via function_exported?/3

    Also covers:
    - Tau.Provider.ContextWindows.lookup/2 — table correctness
    """
    use ExUnit.Case, async: true

    alias Tau.Provider.ContextWindows
    alias Tau.Providers.Anthropic
    alias Tau.Providers.Bedrock
    alias Tau.Providers.Gemini
    alias Tau.Session.Events
    alias Tau.TUI.App
    alias Tau.TUI.Editor
    alias Tau.TUI.History
    alias Tau.TUI.StatusBar

    # --- base model (mirrors App test fixture, plus status-surface fields) ----

    defp model do
      %{
        session_id: "sess-status-test",
        editor: Editor.new(),
        history: History.new(),
        search: nil,
        history_data_dir: System.tmp_dir!(),
        history_cwd: File.cwd!(),
        transcript: [],
        subagents: %{},
        status: :idle,
        last_assistant: nil,
        wrap_width: 80,
        coding_agent: nil,
        catalog: nil,
        menu: nil,
        # Status surface fields (#340):
        model: "claude-opus-4-7",
        provider: Anthropic,
        usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
        context_tokens: 0,
        context_window: 200_000,
        compaction: :idle,
        warn_level: :ok
      }
    end

    # --- ModelSwapped event wiring (AC-6 / D-160) ----------------------------

    describe "on_model_swapped/2 (AC-6 / D-160)" do
      test "updates model field to new model id" do
        m = model()

        event = %Events.ModelSwapped{
          session_id: m.session_id,
          from: "claude-opus-4-7",
          to: "claude-3-5-haiku-20241022"
        }

        next = App.update(m, event)
        assert next.model == "claude-3-5-haiku-20241022"
      end

      test "re-resolves context_window for the new model" do
        m = model()
        # Anthropic haiku has 200_000 window (same as opus in table)
        event = %Events.ModelSwapped{
          session_id: m.session_id,
          from: "claude-opus-4-7",
          to: "claude-3-5-haiku-20241022"
        }

        next = App.update(m, event)

        assert next.context_window ==
                 ContextWindows.lookup(Anthropic, "claude-3-5-haiku-20241022")
      end

      test "sets context_window to nil for unknown model" do
        m = model()

        event = %Events.ModelSwapped{
          session_id: m.session_id,
          from: "claude-opus-4-7",
          to: "unknown-model-xyz"
        }

        next = App.update(m, event)
        assert next.context_window == nil
      end

      test "model segment updates without string-scraping SystemNotice" do
        m = model()
        # First send a SystemNotice that would confuse a string-scraping impl.
        notice = %Events.SystemNotice{session_id: m.session_id, text: "Model changed: old → new"}
        m2 = App.update(m, notice)
        # model field should still be the old model — SystemNotice does NOT update it.
        assert m2.model == "claude-opus-4-7"
        # Only ModelSwapped updates it:
        event = %Events.ModelSwapped{
          session_id: m.session_id,
          from: "claude-opus-4-7",
          to: "claude-3-5-haiku-20241022"
        }

        m3 = App.update(m2, event)
        assert m3.model == "claude-3-5-haiku-20241022"
      end
    end

    # --- CompactionStarted / CompactionFinished wiring (AC-5 / D-163/D-164) --

    describe "on_compaction_started/2 (AC-5 / D-163)" do
      test "transitions compaction to :running" do
        m = model()
        event = %Events.CompactionStarted{session_id: m.session_id}
        next = App.update(m, event)
        assert next.compaction == :running
      end
    end

    describe "on_compaction_finished/2 (AC-5 / D-164 / S-2)" do
      test "transitions compaction back to :idle on {:ok, :compacted}" do
        m = %{model() | compaction: :running}
        event = %Events.CompactionFinished{session_id: m.session_id, outcome: {:ok, :compacted}}
        next = App.update(m, event)
        assert next.compaction == :idle
      end

      test "transitions compaction back to :idle on {:error, reason} (abort/error path)" do
        m = %{model() | compaction: :running}
        event = %Events.CompactionFinished{session_id: m.session_id, outcome: {:error, :timeout}}
        next = App.update(m, event)

        assert next.compaction == :idle,
               "AC-5 / S-2: compaction MUST clear to :idle on error exit; " <>
                 "got: #{inspect(next.compaction)}"
      end

      test "transitions compaction back to :idle on worker crash outcome" do
        m = %{model() | compaction: :running}
        event = %Events.CompactionFinished{session_id: m.session_id, outcome: {:error, :killed}}
        next = App.update(m, event)

        assert next.compaction == :idle,
               "AC-5 / S-2: compaction MUST clear to :idle on crash exit"
      end

      test "compacting… does not appear in render_text after CompactionFinished" do
        m = %{model() | compaction: :running}
        event = %Events.CompactionFinished{session_id: m.session_id, outcome: {:ok, :compacted}}
        next = App.update(m, event)
        # Build the status bar model and render
        status_model = %{
          model: next.model,
          provider: next.provider,
          usage: next.usage,
          context_tokens: next.context_tokens,
          context_window: next.context_window,
          compaction: next.compaction,
          status: next.status
        }

        text = StatusBar.render_text(status_model)

        refute String.contains?(text, "compacting…"),
               "AC-5: 'compacting…' MUST be absent after CompactionFinished; got: #{text}"
      end
    end

    # --- SessionStart status seeding (D-160) ---------------------------------

    describe "SessionStart seeds model/provider/context_window (D-160)" do
      test "model field is seeded from SessionStart" do
        m = %{model() | model: nil}

        event = %Events.SessionStart{
          session_id: m.session_id,
          provider: Anthropic,
          model: "claude-3-5-haiku-20241022"
        }

        next = App.update(m, event)
        assert next.model == "claude-3-5-haiku-20241022"
      end

      test "provider field is seeded from SessionStart" do
        m = %{model() | provider: nil}

        event = %Events.SessionStart{
          session_id: m.session_id,
          provider: Anthropic,
          model: "claude-opus-4-7"
        }

        next = App.update(m, event)
        assert next.provider == Anthropic
      end

      test "context_window resolved via context_window/1 callback on SessionStart" do
        m = %{model() | context_window: nil}

        event = %Events.SessionStart{
          session_id: m.session_id,
          provider: Gemini,
          model: "gemini-2.0-flash"
        }

        next = App.update(m, event)
        # Gemini 2.0 Flash has 1_048_576 context window
        assert next.context_window == 1_048_576
      end

      test "context_window is nil for unknown provider/model pair" do
        m = %{model() | context_window: 200_000}

        event = %Events.SessionStart{
          session_id: m.session_id,
          provider: Anthropic,
          model: "claude-unknown-xyz"
        }

        next = App.update(m, event)
        assert next.context_window == nil
      end
    end

    # --- ContextWindows lookup table -----------------------------------------

    describe "Tau.Provider.ContextWindows.lookup/2" do
      test "returns context window for Anthropic claude-opus-4-7" do
        assert ContextWindows.lookup(Anthropic, "claude-opus-4-7") == 200_000
      end

      test "returns context window for Gemini 2.0 flash" do
        assert ContextWindows.lookup(Gemini, "gemini-2.0-flash") == 1_048_576
      end

      test "returns context window for Bedrock Anthropic model" do
        assert ContextWindows.lookup(
                 Bedrock,
                 "anthropic.claude-3-5-sonnet-20241022-v2:0"
               ) ==
                 200_000
      end

      test "returns context window for Groq model" do
        assert ContextWindows.lookup(Tau.Providers.Groq, "llama-3.3-70b-versatile") == 131_072
      end

      test "returns nil for unknown model" do
        assert ContextWindows.lookup(Anthropic, "claude-unknown-xyz") == nil
      end

      test "returns nil for unknown provider" do
        assert ContextWindows.lookup(Fake.Provider, "gpt-4o") == nil
      end

      test "Replay provider has no context_window/1 callback (coding-agent pattern)" do
        refute function_exported?(Tau.Providers.Replay, :context_window, 1)
      end
    end

    # --- context_window/1 optional callback dispatch (D-160) -----------------

    describe "context_window/1 optional callback dispatch" do
      setup do
        # function_exported?/3 only works on loaded modules; ensure loading
        # before checking. At runtime all provider modules are loaded at startup.
        Code.ensure_loaded(Anthropic)
        Code.ensure_loaded(Gemini)
        Code.ensure_loaded(Bedrock)
        :ok
      end

      test "Anthropic implements context_window/1" do
        assert function_exported?(Anthropic, :context_window, 1)
        assert Anthropic.context_window("claude-opus-4-7") == 200_000
      end

      test "Gemini implements context_window/1" do
        assert function_exported?(Gemini, :context_window, 1)
        assert Gemini.context_window("gemini-2.0-flash") == 1_048_576
      end

      test "Bedrock implements context_window/1" do
        assert function_exported?(Bedrock, :context_window, 1)

        assert Bedrock.context_window("anthropic.claude-3-5-sonnet-20241022-v2:0") ==
                 200_000
      end

      test "context_window/1 returns nil for unknown model (triggers fallback)" do
        assert Anthropic.context_window("unknown-model") == nil
      end

      test "function_exported? dispatch works for optional callback detection" do
        # The dispatch pattern: if function_exported?(provider, :context_window, 1) do
        #   provider.context_window(model) — else nil end
        provider = Anthropic
        model_id = "claude-opus-4-7"

        result =
          if function_exported?(provider, :context_window, 1) do
            provider.context_window(model_id)
          else
            nil
          end

        assert result == 200_000
      end
    end
  end
end

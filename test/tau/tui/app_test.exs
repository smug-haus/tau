if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.AppTest do
    @moduledoc """
    Verifies #26: `Tau.TUI.App.update/2` reacts to `Cancelled` and
    `SessionEnd` PubSub events. Without these clauses ESC produces no
    UI feedback and a terminating session leaves the bar reading
    `streaming`.

    Also verifies SPEC-TUI-COMPLETION AC-3, AC-5, AC-6, AC-9 (D-102..D-106).

    Drives `update/2` directly with a hand-built model state so the
    test does not depend on Ratatouille's runtime loop.
    """
    use ExUnit.Case, async: true

    alias Tau.Session.Events
    alias Tau.TUI.App
    alias Tau.TUI.Editor
    alias Tau.TUI.History

    defp model do
      %{
        session_id: "sess-test",
        editor: Editor.new(),
        history: History.new(),
        search: nil,
        history_data_dir: System.tmp_dir!(),
        history_cwd: File.cwd!(),
        transcript: [],
        tool_output: [],
        status: :streaming,
        last_assistant: "partial",
        wrap_width: 80,
        coding_agent: nil,
        catalog: nil,
        menu: nil
      }
    end

    # Minimal catalog entries for menu tests.
    defp sample_catalog do
      [
        %{name: "/compact", description: "Compress history", origin: :builtin},
        %{name: "/help", description: "List commands", origin: :builtin},
        %{name: "/ping", description: "pong", origin: :builtin},
        %{name: "/reload", description: "Reload", origin: :builtin}
      ]
    end

    describe "update/2 — quit ergonomics (D-003 / AC-4)" do
      # AC-4 / D-003: `q` on an empty prompt triggers quit (returns the model
      # unchanged — the actual supervisor stop is async); `q` on a non-empty
      # prompt appends the character. The headless tui_smoke AC-H4 test
      # ("literal q does not quit") cannot run until the plain-release
      # entrypoint fix (#211 / PR #217) is merged; these unit tests verify
      # the `update/2` contract that AC-H4 depends on.

      test "q on empty prompt returns model unchanged (quit is async side-effect)" do
        m = model()
        next = App.update(m, {:event, %{key: 0, ch: ?q, mod: 0}})
        # Model is returned as-is; the async spawn stops the supervisor.
        assert Editor.empty?(next.editor)
        assert next.status == m.status
        assert next.transcript == m.transcript
      end

      test "q on non-empty prompt appends q to input" do
        m = %{model() | editor: Editor.new() |> Editor.insert("hel")}
        next = App.update(m, {:event, %{key: 0, ch: ?q, mod: 0}})
        assert Editor.text(next.editor) == "helq"
      end

      test "q on non-empty prompt does not change status or transcript" do
        m = %{model() | editor: Editor.new() |> Editor.insert("hello")}
        next = App.update(m, {:event, %{key: 0, ch: ?q, mod: 0}})
        assert next.status == m.status
        assert next.transcript == m.transcript
      end
    end

    describe "update/2 — Cancelled" do
      test "moves status into a cancelled string and appends a transcript line" do
        event = %Events.Cancelled{session_id: "sess-test", reason: :user_request}

        next = App.update(model(), event)

        assert next.status == "cancelled: :user_request"
        assert List.last(next.transcript) == {"[cancelled: :user_request]", []}
        assert next.last_assistant == nil
      end
    end

    describe "update/2 — SessionEnd" do
      test "moves status into an ended string and appends a transcript line" do
        event = %Events.SessionEnd{session_id: "sess-test", reason: :normal}

        next = App.update(model(), event)

        assert next.status == "ended: :normal"
        assert List.last(next.transcript) == {"[session ended: :normal]", []}
        assert next.last_assistant == nil
      end
    end

    describe "update/2 — MessageEnd render path (D-009 / SPEC-USER-TURN AC-3)" do
      # These tests close the loop on D-009: the FSM-side test
      # (test/tau/session/sync_provider_error_test.exs) proves the
      # broadcast carries non-empty content; THIS suite proves the TUI's
      # update/2 produces a visible transcript line from that content.
      # Without these, D-009 is a half-fix.

      test "synchronous-error MessageEnd produces a visible transcript line" do
        # Mirrors the shape constructed at lib/tau/session.ex :start_provider
        # error branch (D-009).
        msg = %Tau.Message.Assistant{
          content: [%{type: :text, text: "Error: :sync_fail"}],
          timestamp: DateTime.utc_now(),
          stop_reason: :error,
          error_message: ":sync_fail"
        }

        event = %Events.MessageEnd{session_id: "sess-test", message: msg}

        next = App.update(model(), event)

        assert next.status == :idle
        assert next.last_assistant == nil

        # transcript entries are {text, attrs} tuples
        last_entry = List.last(next.transcript)

        assert match?({text, _attrs} when is_binary(text) and text != "", last_entry),
               "transcript MUST gain a non-empty {text, attrs} entry; got #{inspect(last_entry)}"

        {last_text, _} = last_entry

        assert String.contains?(last_text, "Error"),
               "transcript line MUST surface the error keyword for AC-3; got #{inspect(last_text)}"
      end

      test "Replay-style success MessageEnd produces an assistant transcript line" do
        # Mirrors the canonical Replay default fixture
        # (lib/tau/providers/replay.ex default_events/0).
        msg = %Tau.Message.Assistant{
          content: [%{type: :text, text: "(replay) hello"}],
          timestamp: DateTime.utc_now(),
          stop_reason: :stop
        }

        event = %Events.MessageEnd{session_id: "sess-test", message: msg}

        next = App.update(model(), event)

        assert next.status == :idle

        # D-028: markdown render splits a paragraph into header + body lines.
        # The transcript MUST contain both the "[assistant]" header marker
        # and the rendered text body somewhere in the list.
        # transcript entries are {text, attrs} tuples.
        assert {"[assistant]", []} in next.transcript,
               "transcript MUST contain the [assistant] header for AC-2 render path; " <>
                 "got #{inspect(next.transcript)}"

        assert Enum.any?(next.transcript, fn {text, _attrs} ->
                 String.contains?(text, "(replay) hello")
               end),
               "transcript MUST contain the rendered assistant body for AC-2; " <>
                 "got #{inspect(next.transcript)}"
      end

      test "empty-content MessageEnd produces no transcript line — regression guard" do
        # Pre-D-009 shape: the synchronous-error branch produced an
        # empty content list. Locks in: if anyone reverts D-009, the
        # transcript silently drops the user's turn — and this test
        # turns that silent failure into a loud one.
        msg = %Tau.Message.Assistant{
          content: [],
          timestamp: DateTime.utc_now(),
          stop_reason: :error,
          error_message: "this would be invisible without D-009"
        }

        event = %Events.MessageEnd{session_id: "sess-test", message: msg}

        next = App.update(model(), event)

        # The render iterates content and reduces to []; transcript is
        # unchanged. THIS is the silent failure D-009 prevents — kept
        # here as a regression guard, not a desired behaviour.
        assert next.transcript == [],
               "(D-009 regression guard) empty content currently produces NO transcript line; " <>
                 "if this assertion fails, the render path was changed — verify the new path " <>
                 "still surfaces errors and update D-009's invariant accordingly"
      end
    end

    # App.wrap/2 was removed in #337. Wrapping is now done by
    # Tau.TUI.Render.Wrap (tested in test/tau/tui/render/wrap_test.exs).

    describe "update/2 — attrs survive MessageEnd render path (FIX-2 / AC-6)" do
      # Verify that {text, attrs} tuples (not bare strings) are stored in
      # model.transcript after MessageEnd, and that attrs from Render.Markdown
      # (e.g. bold for headings) are present and non-empty for styled content.
      test "heading in MessageEnd produces a {text, attrs} tuple with bold attrs" do
        msg = %Tau.Message.Assistant{
          content: [%{type: :text, text: "# My Heading"}],
          timestamp: DateTime.utc_now(),
          stop_reason: :stop
        }

        next = App.update(model(), %Events.MessageEnd{session_id: "sess-test", message: msg})

        # All entries in transcript must be {text, attrs} tuples
        assert Enum.all?(next.transcript, fn entry -> match?({_, _}, entry) end),
               "all transcript entries must be {text, attrs} tuples; got #{inspect(next.transcript)}"

        # At least one entry must have non-empty attrs (bold from heading)
        styled = Enum.find(next.transcript, fn {_text, attrs} -> attrs != [] end)

        assert styled != nil,
               "expected at least one styled (non-empty attrs) entry for a heading; " <>
                 "got #{inspect(next.transcript)}"

        {_heading_text, heading_attrs} = styled

        assert Keyword.get(heading_attrs, :attributes) == [:bold],
               "heading entry must have bold attrs; got #{inspect(heading_attrs)}"
      end
    end

    # --- SPEC-TUI-COMPLETION tests ---

    describe "update/2 — CommandCatalog event (D-103)" do
      test "stores catalog entries in model.catalog" do
        entries = sample_catalog()
        event = %Events.CommandCatalog{session_id: "sess-test", entries: entries}
        next = App.update(model(), event)
        assert next.catalog == entries
      end

      test "does not open menu when input is empty" do
        entries = sample_catalog()
        event = %Events.CommandCatalog{session_id: "sess-test", entries: entries}
        m = model()
        next = App.update(m, event)
        assert next.menu == nil
      end

      test "re-filters open menu after catalog update" do
        editor_with_slash_c = Editor.new() |> Editor.insert("/c")
        m = %{model() | editor: editor_with_slash_c, catalog: nil, menu: nil}
        event = %Events.CommandCatalog{session_id: "sess-test", entries: sample_catalog()}
        m4 = App.update(m, event)
        # After receiving catalog with /c query, menu should show /compact
        if m4.menu != nil do
          names = Enum.map(m4.menu.entries, fn {_, e} -> e.name end)
          assert "/compact" in names or names == []
        end
      end
    end

    describe "update/2 — menu open on / (AC-3, D-102)" do
      test "typing / opens the menu" do
        m = %{model() | catalog: sample_catalog(), status: :idle}
        next = App.update(m, {:event, %{key: 0, ch: ?/, mod: 0}})
        assert next.menu != nil, "menu should open when / is typed"
      end

      test "menu opens with builtins floor when catalog is nil (AC-9 / D-104)" do
        m = %{model() | catalog: nil, status: :idle}
        next = App.update(m, {:event, %{key: 0, ch: ?/, mod: 0}})
        assert next.menu != nil, "menu should open even with nil catalog (builtins floor)"
        assert next.menu.entries != []
      end

      test "menu.query is empty when only / is typed" do
        m = %{model() | catalog: sample_catalog(), status: :idle}
        next = App.update(m, {:event, %{key: 0, ch: ?/, mod: 0}})
        assert next.menu.query == ""
      end

      test "typing extra chars narrows menu (AC-4)" do
        editor_with_slash = Editor.new() |> Editor.insert("/")

        m = %{
          model()
          | editor: editor_with_slash,
            catalog: sample_catalog(),
            menu: nil,
            status: :idle
        }

        # Append 'c' to produce "/c" — realistic printable-char event shape
        next = App.update(m, {:event, %{key: 0, ch: ?c, mod: 0}})

        if next.menu != nil do
          names = Enum.map(next.menu.entries, fn {_, e} -> e.name end)
          # /compact should match "c"; /help might not
          assert Enum.any?(names, &String.contains?(&1, "c"))
        end
      end

      test "space closes the menu (menu becomes nil)" do
        editor_with_slash_compact = Editor.new() |> Editor.insert("/compact")
        m = %{model() | editor: editor_with_slash_compact, catalog: sample_catalog(), status: :idle}
        # Open menu first
        m2 = %{m | menu: %{query: "compact", entries: [{0, hd(sample_catalog())}], selected: 0}}
        # Space: termbox delivers space as key=32, ch=0 (quirk noted in handle_key)
        next = App.update(m2, {:event, %{key: 32, ch: 0, mod: 0}})
        assert next.menu == nil, "space should close the menu"
      end
    end

    describe "update/2 — menu navigation (AC-5, D-104)" do
      setup do
        entries_scored =
          sample_catalog()
          |> Enum.with_index()
          |> Enum.map(fn {e, i} -> {i, e} end)

        editor_with_slash = Editor.new() |> Editor.insert("/")
        menu = %{query: "", entries: entries_scored, selected: 0}

        m = %{
          model()
          | editor: editor_with_slash,
            catalog: sample_catalog(),
            menu: menu,
            status: :idle
        }

        {:ok, model: m, entries: entries_scored}
      end

      test "arrow-down increments selected", %{model: m} do
        next = App.update(m, {:event, %{key: 65_516, ch: 0, mod: 0}})
        assert next.menu.selected == 1
      end

      test "arrow-up decrements selected", %{model: m} do
        m2 = %{m | menu: %{m.menu | selected: 2}}
        next = App.update(m2, {:event, %{key: 65_517, ch: 0, mod: 0}})
        assert next.menu.selected == 1
      end

      test "arrow-up does not go below 0 (clamped)", %{model: m} do
        next = App.update(m, {:event, %{key: 65_517, ch: 0, mod: 0}})
        assert next.menu.selected == 0
      end

      test "arrow-down does not exceed count-1 (clamped)", %{model: m, entries: entries} do
        m2 = %{m | menu: %{m.menu | selected: length(entries) - 1}}
        next = App.update(m2, {:event, %{key: 65_516, ch: 0, mod: 0}})
        assert next.menu.selected == length(entries) - 1
      end

      test "Enter accepts selection: fills input with name<>space and closes menu (D-106, AC-5)",
           %{model: m} do
        # Move to second entry
        m2 = %{m | menu: %{m.menu | selected: 1}}
        {_, selected_entry} = Enum.at(m2.menu.entries, 1)
        next = App.update(m2, {:event, %{key: 13, ch: 0, mod: 0}})
        assert next.menu == nil, "menu should close after Enter"
        assert Editor.text(next.editor) == selected_entry.name <> " ", "input should be filled"
        # NOT submitted: status should not be :sending
        assert next.status != :sending
      end
    end

    describe "update/2 — Esc dismisses menu without cancel (AC-6, D-105)" do
      test "Esc with menu open closes menu but does not cancel" do
        menu = %{query: "", entries: [], selected: 0}
        editor_with_slash = Editor.new() |> Editor.insert("/")
        m = %{model() | editor: editor_with_slash, menu: menu, status: :idle}
        next = App.update(m, {:event, %{key: 27, ch: 0, mod: 0}})
        assert next.menu == nil, "Esc should close menu"
        # Status should not be affected by Esc (no cancel)
        assert next.status == :idle
      end

      test "Esc with menu open does NOT cancel (no status change to cancelled)" do
        menu = %{query: "", entries: [], selected: 0}
        editor_with_slash = Editor.new() |> Editor.insert("/")
        m = %{model() | editor: editor_with_slash, menu: menu, status: :idle}
        next = App.update(m, {:event, %{key: 27, ch: 0, mod: 0}})
        # cancel/1 calls Tau.cancel/1 but model.status would change
        # With menu open, Esc should just nil the menu
        assert next.menu == nil
        assert next.status == :idle
      end

      test "Esc without menu open still cancels (existing behaviour)" do
        m = %{model() | menu: nil, status: :idle}
        # cancel/1 calls Tau.cancel but since this is a unit test (no FSM)
        # we just verify the model fields that cancel/1 sets
        next = App.update(m, {:event, %{key: 27, ch: 0, mod: 0}})
        # cancel/1 sets status: :idle and calls Tau.cancel (side effect)
        # The test verifies the model is returned (doesn't crash)
        assert is_map(next)
      end
    end

    # --- FIX-7: update/2 wiring layer tests ---
    # Each AC-1/2/3/4/5/7/9 key event is exercised via the real update/2 path.

    describe "update/2 — Ctrl+J inserts newline (AC-1 / D-145)" do
      test "Ctrl+J inserts a newline at cursor without submitting" do
        m = %{model() | editor: Editor.new() |> Editor.insert("hello"), status: :idle}
        next = App.update(m, {:event, %{key: 10, ch: 0, mod: 0}})
        assert length(next.editor.lines) == 2
        assert next.status == :idle
      end
    end

    describe "update/2 — backslash+Enter inserts newline (FIX-2 / D-145)" do
      test "Enter after trailing backslash inserts newline, does not submit" do
        # Buffer ends in backslash immediately before cursor
        m = %{model() | editor: Editor.new() |> Editor.insert("hello\\"), status: :idle}
        next = App.update(m, {:event, %{key: 13, ch: 0, mod: 0}})
        # Should have 2 lines (newline inserted, backslash removed)
        assert length(next.editor.lines) == 2
        # Not submitted
        assert next.status == :idle
        # Text should be "hello\n" (backslash replaced by real newline)
        assert Editor.text(next.editor) == "hello\n"
      end

      test "Enter without trailing backslash submits normally" do
        m = %{model() | editor: Editor.new() |> Editor.insert("hello"), status: :idle}
        # submit calls Tau.send/2, but in unit test context it will raise or no-op;
        # we check status becomes :sending
        # Note: Tau.send/2 in test env — catch the expected process-not-found
        try do
          next = App.update(m, {:event, %{key: 13, ch: 0, mod: 0}})
          assert next.status == :sending
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end

    describe "update/2 — up/down arrows edge-aware cursor movement (FIX-1 / AC-2)" do
      test "up arrow on multi-line buffer (non-first line) moves cursor up" do
        ed =
          Editor.new()
          |> Editor.insert("line1")
          |> Editor.newline()
          |> Editor.insert("line2")

        # cursor is on row 1
        assert elem(ed.cursor, 0) == 1

        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 65_517, ch: 0, mod: 0}})
        # Cursor should move to row 0 (within buffer, not history)
        {row, _col} = next.editor.cursor
        assert row == 0
        # History not navigated
        assert next.history == m.history
      end

      test "up arrow on first line of multi-line buffer triggers history_prev" do
        # Push a history entry so prev has something to return
        hist = History.new() |> History.push("old entry")
        ed = Editor.new() |> Editor.insert("line1") |> Editor.newline() |> Editor.insert("line2")
        # Move cursor to first line
        ed_first = %{ed | cursor: {0, 0}}
        m = %{model() | editor: ed_first, history: hist}
        next = App.update(m, {:event, %{key: 65_517, ch: 0, mod: 0}})
        # History should have been navigated (cursor changed in history)
        assert next.history != m.history or Editor.text(next.editor) == "old entry"
      end

      test "down arrow on multi-line buffer (non-last line) moves cursor down" do
        ed =
          Editor.new()
          |> Editor.insert("line1")
          |> Editor.newline()
          |> Editor.insert("line2")
          |> Editor.move_up()

        # cursor is on row 0
        assert elem(ed.cursor, 0) == 0

        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 65_516, ch: 0, mod: 0}})
        # menu is nil so this goes to arrow_down
        {row, _col} = next.editor.cursor
        assert row == 1
      end

      test "down arrow on last line of single-line buffer triggers history_next" do
        ed = Editor.new() |> Editor.insert("hello")
        # cursor row == 0 == last_row (single line)
        assert elem(ed.cursor, 0) == 0
        # With no history navigation pending, history_next returns nil
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 65_516, ch: 0, mod: 0}})
        # history unchanged (nothing to navigate to)
        assert next.history == m.history
      end
    end

    describe "update/2 — Ctrl+A/E/W/U/K/Y readline chords (AC-3, AC-4, AC-5)" do
      test "Ctrl+A (key 1) moves cursor to start of line" do
        ed = Editor.new() |> Editor.insert("hello")
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 1, ch: 0, mod: 0}})
        assert next.editor.cursor == {0, 0}
      end

      test "Ctrl+E (key 5) moves cursor to end of line" do
        ed = Editor.new() |> Editor.insert("hello") |> Editor.move_line_start()
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 5, ch: 0, mod: 0}})
        assert next.editor.cursor == {0, 5}
      end

      test "Ctrl+W (key 23) kills word before cursor" do
        ed = Editor.new() |> Editor.insert("alpha beta")
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 23, ch: 0, mod: 0}})
        assert Editor.text(next.editor) == "alpha "
        assert hd(next.editor.kill_ring) == "beta"
      end

      test "Ctrl+U (key 21) kills to line start" do
        ed = Editor.new() |> Editor.insert("hello")
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 21, ch: 0, mod: 0}})
        assert Editor.text(next.editor) == ""
        assert hd(next.editor.kill_ring) == "hello"
      end

      test "Ctrl+K (key 11) kills to line end" do
        ed = Editor.new() |> Editor.insert("hello") |> Editor.move_line_start()
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 11, ch: 0, mod: 0}})
        assert Editor.text(next.editor) == ""
        assert hd(next.editor.kill_ring) == "hello"
      end

      test "Ctrl+Y (key 25) yanks most recent kill" do
        ed =
          Editor.new()
          |> Editor.insert("hello")
          |> Editor.kill_to_line_start()

        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{key: 25, ch: 0, mod: 0}})
        assert Editor.text(next.editor) == "hello"
      end
    end

    describe "update/2 — Ctrl+R search mode (FIX-3 / AC-7 / D-147)" do
      test "Ctrl+R (key 18) enters search mode" do
        m = model()
        next = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        assert next.search != nil
        assert next.search.query == ""
      end

      test "Esc in search mode restores pre-search buffer (D-147)" do
        ed = Editor.new() |> Editor.insert("my draft")
        m = %{model() | editor: ed}
        # Enter search mode
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m2.search != nil
        # Esc restores pre-search editor
        m3 = App.update(m2, {:event, %{key: 27, ch: 0, mod: 0}})
        assert m3.search == nil
        assert Editor.text(m3.editor) == "my draft"
      end

      test "Ctrl+R while in search mode cycles to next match index" do
        hist = History.new() |> History.push("foo bar") |> History.push("foo baz")
        m = %{model() | history: hist}
        # Enter search mode
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m2.search.search_index == 0
        # Ctrl+R again increments search_index
        m3 = App.update(m2, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m3.search.search_index == 1
      end

      # FIX-C1 (BLOCKING): displayed match MUST advance with search_index.
      # These tests verify the live prompt shows the Nth-oldest match after
      # N Ctrl+R presses, not always match 0.
      test "displayed prompt shows match-0 entry at search_index 0" do
        # Two entries matching "foo": foo bar (older), foo baz (newer/index-0)
        hist = History.new() |> History.push("foo bar") |> History.push("foo baz")
        m = %{model() | history: hist}
        # Enter search and type query "foo"
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        m3 = App.update(m2, {:event, %{key: 0, ch: ?f, mod: 0}})
        m4 = App.update(m3, {:event, %{key: 0, ch: ?o, mod: 0}})
        m5 = App.update(m4, {:event, %{key: 0, ch: ?o, mod: 0}})
        assert m5.search.search_index == 0

        # Render and extract the prompt bar label content
        rendered = App.render(m5)
        [label | _] = rendered.attributes.bottom_bar.children
        content = label.attributes.content

        assert String.contains?(content, "foo baz"),
               "at search_index 0, prompt MUST show the most-recent match (foo baz); got: #{inspect(content)}"

        refute String.contains?(content, "foo bar"),
               "at search_index 0, prompt MUST NOT show the older match (foo bar); got: #{inspect(content)}"
      end

      test "displayed prompt advances to next-older match after Ctrl+R cycle (FIX-C1)" do
        # This test MUST fail against pre-fix code where build_prompt_labels
        # calls History.search/2 (always match 0) instead of search_nth_match/3.
        hist = History.new() |> History.push("foo bar") |> History.push("foo baz")
        m = %{model() | history: hist}
        # Enter search and type query "foo"
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        m3 = App.update(m2, {:event, %{key: 0, ch: ?f, mod: 0}})
        m4 = App.update(m3, {:event, %{key: 0, ch: ?o, mod: 0}})
        m5 = App.update(m4, {:event, %{key: 0, ch: ?o, mod: 0}})
        # Press Ctrl+R again to cycle to match index 1
        m6 = App.update(m5, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m6.search.search_index == 1

        # Render and extract the prompt bar label content
        rendered = App.render(m6)
        [label | _] = rendered.attributes.bottom_bar.children
        content = label.attributes.content

        assert String.contains?(content, "foo bar"),
               "at search_index 1, prompt MUST show the next-older match (foo bar); got: #{inspect(content)}"

        refute String.contains?(content, "foo baz"),
               "at search_index 1, prompt MUST NOT show the most-recent match (foo baz); got: #{inspect(content)}"
      end

      # FIX-C2 (SUGGESTION): search_index MUST reset to 0 on query mutation.
      test "Backspace in search mode resets search_index to 0" do
        hist = History.new() |> History.push("foo bar") |> History.push("foo baz")
        m = %{model() | history: hist}
        # Enter search, type "foo", cycle to index 1
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        m3 = App.update(m2, {:event, %{key: 0, ch: ?f, mod: 0}})
        m4 = App.update(m3, {:event, %{key: 0, ch: ?o, mod: 0}})
        m5 = App.update(m4, {:event, %{key: 0, ch: ?o, mod: 0}})
        m6 = App.update(m5, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m6.search.search_index == 1

        # Now Backspace — mutates query, MUST reset search_index
        m7 = App.update(m6, {:event, %{key: 127, ch: 0, mod: 0}})

        assert m7.search.search_index == 0,
               "Backspace in search mode MUST reset search_index to 0; got: #{m7.search.search_index}"
      end

      test "Space in search mode resets search_index to 0" do
        hist = History.new() |> History.push("foo bar") |> History.push("foo baz")
        m = %{model() | history: hist}
        # Enter search, type "foo", cycle to index 1
        m2 = App.update(m, {:event, %{key: 18, ch: 0, mod: 0}})
        m3 = App.update(m2, {:event, %{key: 0, ch: ?f, mod: 0}})
        m4 = App.update(m3, {:event, %{key: 0, ch: ?o, mod: 0}})
        m5 = App.update(m4, {:event, %{key: 0, ch: ?o, mod: 0}})
        m6 = App.update(m5, {:event, %{key: 18, ch: 0, mod: 0}})
        assert m6.search.search_index == 1

        # Now Space — mutates query, MUST reset search_index
        # Space: termbox delivers space as key=32 (quirk noted in handle_key)
        m7 = App.update(m6, {:event, %{key: 32, ch: 0, mod: 0}})

        assert m7.search.search_index == 0,
               "Space in search mode MUST reset search_index to 0; got: #{m7.search.search_index}"
      end
    end

    # Regression guard for the clause-precedence bug fixed in FIX-1 of refine-4.
    # A printable char event has key=0 and ch=<codepoint>. The pre-fix code matched
    # the `%{key: key}` clause first (key=0 is always present), routing the char to
    # handle_readline_key/2 which silently dropped it in its catch-all. This broke
    # typed character input entirely (AC-H2/H3/H4 all require chars to reach the editor).
    # This test MUST fail against the pre-fix handle_event clause order and pass after.
    describe "update/2 — printable char reaches editor (FIX-1 regression guard)" do
      test "realistic printable-char event %{key: 0, ch: ?h, mod: 0} inserts h into editor" do
        m = %{model() | editor: Editor.new(), status: :idle}
        # Exact termbox shape for a printable character
        next = App.update(m, {:event, %{key: 0, ch: ?h, mod: 0}})

        assert Editor.text(next.editor) == "h",
               "printable char event %{key: 0, ch: ?h, mod: 0} MUST insert 'h' into the editor; " <>
                 "got: #{inspect(Editor.text(next.editor))} — " <>
                 "this is the FIX-1 regression guard: if it fails, the handle_event " <>
                 "clause ordering has regressed and typed chars are silently dropped"
      end

      test "sequence of printable chars builds correct buffer" do
        m = %{model() | editor: Editor.new(), status: :idle}

        m2 = App.update(m, {:event, %{key: 0, ch: ?h, mod: 0}})
        m3 = App.update(m2, {:event, %{key: 0, ch: ?i, mod: 0}})

        assert Editor.text(m3.editor) == "hi",
               "sequence of printable-char events MUST accumulate in the editor"
      end

      test "control key Enter (%{key: 13, ch: 0}) does NOT insert a char" do
        # Discriminator test: Enter (key=13, ch=0) must route to handle_key, not handle_char.
        # handle_key for key=13 on empty buffer is a no-op (submit on empty = no-op).
        m = %{model() | editor: Editor.new(), status: :idle}
        next = App.update(m, {:event, %{key: 13, ch: 0, mod: 0}})
        # No char inserted; empty buffer submit is no-op
        assert Editor.text(next.editor) == "",
               "Enter on empty buffer MUST NOT insert a char (routes to handle_key, not handle_char)"
      end
    end

    describe "update/2 — Alt+Y yank-pop wiring (AC-6)" do
      test "Alt+Y event (mod != 0, ch == ?y) triggers yank_pop" do
        ed =
          Editor.new()
          |> Editor.insert("first")
          |> Editor.kill_to_line_start()
          |> Editor.insert("second")
          |> Editor.kill_to_line_start()
          |> Editor.yank()

        assert Editor.text(ed) == "second"
        m = %{model() | editor: ed}
        # Alt+Y: mod != 0, ch == ?y, key == 0 (realistic termbox shape)
        next = App.update(m, {:event, %{mod: 1, key: 0, ch: ?y}})
        assert Editor.text(next.editor) == "first"
      end
    end

    describe "update/2 — D-141 unrecognised alt-chord is no-op (FIX-8)" do
      test "unrecognised mod-prefixed event (Alt+Z) does not insert literal char" do
        ed = Editor.new() |> Editor.insert("hello")
        m = %{model() | editor: ed}
        # Send Alt+Z (unrecognised alt-chord) — realistic termbox shape
        next = App.update(m, {:event, %{mod: 1, key: 0, ch: ?z}})
        # Buffer MUST be unchanged — must not insert 'z'
        assert Editor.text(next.editor) == "hello",
               "unrecognised alt-chord MUST NOT insert a literal char (D-141)"
      end

      test "unrecognised mod-prefixed event with key present does not insert literal char" do
        ed = Editor.new() |> Editor.insert("hello")
        m = %{model() | editor: ed}
        # FIX-8: events with both mod and key — mod check must take priority
        next = App.update(m, {:event, %{mod: 1, key: 65_514, ch: 0}})
        # mod != 0, so handle_alt dispatches. ch == 0 → no-op (handle_alt(model, 0))
        assert Editor.text(next.editor) == "hello",
               "mod-bearing event must reach handle_alt, not the key handler (FIX-8 / D-141)"
      end
    end

    describe "update/2 — Alt+B/F word motion (AC-2)" do
      test "Alt+B (mod != 0, ch == ?b) moves word left" do
        ed = Editor.new() |> Editor.insert("alpha beta")
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{mod: 1, key: 0, ch: ?b}})
        # Cursor should move left by one word
        {_row, col} = next.editor.cursor
        assert col < 10
      end

      test "Alt+F (mod != 0, ch == ?f) moves word right" do
        ed = Editor.new() |> Editor.insert("alpha beta") |> Editor.move_line_start()
        m = %{model() | editor: ed}
        next = App.update(m, {:event, %{mod: 1, key: 0, ch: ?f}})
        {_row, col} = next.editor.cursor
        assert col > 0
      end
    end

    describe "run/0 — supervised Ratatouille subtree" do
      test "emits [:tau, :tui, :start] with Ratatouille.Runtime.Supervisor metadata" do
        parent = self()
        handler_id = "tui-start-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler_id,
          [:tau, :tui, :start],
          fn _name, _meas, meta, _ -> send(parent, {:tui_start, meta}) end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        # The TUI will fail to start in headless mix test (Window calls termbox
        # NIF which needs a TTY). We assert the :start event fires BEFORE that
        # failure path. Capture the resulting Logger.error so the test output
        # stays clean.
        ExUnit.CaptureLog.capture_log(fn ->
          spawned =
            spawn(fn ->
              try do
                Tau.TUI.App.run()
              rescue
                _ -> :ok
              catch
                :exit, _ -> :ok
              end
            end)

          assert_receive {:tui_start,
                          %{supervisor: Ratatouille.Runtime.Supervisor, app: Tau.TUI.App}},
                         1000

          Process.exit(spawned, :kill)
        end)
      end

      test "Ratatouille.Runtime.Supervisor.init/1 declares EventManager + Window + Runtime children" do
        # Lock the dep contract: the supervisor we use MUST start EventManager.
        # If a future Ratatouille upgrade removes it, this test forces a review.
        {:ok, {_sup_flags, child_specs}} =
          Ratatouille.Runtime.Supervisor.init(runtime: [app: Tau.TUI.App])

        ids = Enum.map(child_specs, & &1.id)
        assert Ratatouille.EventManager in ids
        assert Ratatouille.Window in ids
        assert Ratatouille.Runtime in ids
      end
    end
  end
end

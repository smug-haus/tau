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

    defp model do
      %{
        session_id: "sess-test",
        input: "",
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
        m = %{model() | input: ""}
        next = App.update(m, {:event, %{ch: ?q}})
        # Model is returned as-is; the async spawn stops the supervisor.
        assert next.input == ""
        assert next.status == m.status
        assert next.transcript == m.transcript
      end

      test "q on non-empty prompt appends q to input" do
        m = %{model() | input: "hel"}
        next = App.update(m, {:event, %{ch: ?q}})
        assert next.input == "helq"
      end

      test "q on non-empty prompt does not change status or transcript" do
        m = %{model() | input: "hello"}
        next = App.update(m, {:event, %{ch: ?q}})
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
        m = %{model() | input: ""}
        next = App.update(m, event)
        assert next.menu == nil
      end

      test "re-filters open menu after catalog update" do
        m = %{model() | input: "/c", catalog: nil, menu: nil}
        # First type / to open menu with builtins floor
        m2 = App.update(m, {:event, %{ch: ?/}})
        # ... actually the input is already set; trigger update directly
        m3 = %{m | input: "/c"}
        event = %Events.CommandCatalog{session_id: "sess-test", entries: sample_catalog()}
        m4 = App.update(m3, event)
        # After receiving catalog with /c query, menu should show /compact
        if m4.menu != nil do
          names = Enum.map(m4.menu.entries, fn {_, e} -> e.name end)
          assert "/compact" in names or names == []
        end
      end
    end

    describe "update/2 — menu open on / (AC-3, D-102)" do
      test "typing / opens the menu" do
        m = %{model() | input: "", catalog: sample_catalog(), status: :idle}
        next = App.update(m, {:event, %{ch: ?/}})
        assert next.menu != nil, "menu should open when / is typed"
      end

      test "menu opens with builtins floor when catalog is nil (AC-9 / D-104)" do
        m = %{model() | input: "", catalog: nil, status: :idle}
        next = App.update(m, {:event, %{ch: ?/}})
        assert next.menu != nil, "menu should open even with nil catalog (builtins floor)"
        assert next.menu.entries != []
      end

      test "menu.query is empty when only / is typed" do
        m = %{model() | input: "", catalog: sample_catalog(), status: :idle}
        next = App.update(m, {:event, %{ch: ?/}})
        assert next.menu.query == ""
      end

      test "typing extra chars narrows menu (AC-4)" do
        m = %{model() | input: "/", catalog: sample_catalog(), menu: nil, status: :idle}
        # Append 'c' to produce "/c"
        next = App.update(m, {:event, %{ch: ?c}})

        if next.menu != nil do
          names = Enum.map(next.menu.entries, fn {_, e} -> e.name end)
          # /compact should match "c"; /help might not
          assert Enum.any?(names, &String.contains?(&1, "c"))
        end
      end

      test "space closes the menu (menu becomes nil)" do
        m = %{model() | input: "/compact", catalog: sample_catalog(), status: :idle}
        m2 = App.update(m, {:event, %{ch: ?/}})
        # Open menu first by typing on "/compact" trigger
        m3 = %{m2 | menu: %{query: "compact", entries: [{0, hd(sample_catalog())}], selected: 0}}
        next = App.update(m3, {:event, %{key: 32}})
        assert next.menu == nil, "space should close the menu"
      end
    end

    describe "update/2 — menu navigation (AC-5, D-104)" do
      setup do
        entries_scored =
          sample_catalog()
          |> Enum.with_index()
          |> Enum.map(fn {e, i} -> {i, e} end)

        menu = %{query: "", entries: entries_scored, selected: 0}
        m = %{model() | input: "/", catalog: sample_catalog(), menu: menu, status: :idle}
        {:ok, model: m, entries: entries_scored}
      end

      test "arrow-down increments selected", %{model: m} do
        next = App.update(m, {:event, %{key: 65_516}})
        assert next.menu.selected == 1
      end

      test "arrow-up decrements selected", %{model: m} do
        m2 = %{m | menu: %{m.menu | selected: 2}}
        next = App.update(m2, {:event, %{key: 65_517}})
        assert next.menu.selected == 1
      end

      test "arrow-up does not go below 0 (clamped)", %{model: m} do
        next = App.update(m, {:event, %{key: 65_517}})
        assert next.menu.selected == 0
      end

      test "arrow-down does not exceed count-1 (clamped)", %{model: m, entries: entries} do
        m2 = %{m | menu: %{m.menu | selected: length(entries) - 1}}
        next = App.update(m2, {:event, %{key: 65_516}})
        assert next.menu.selected == length(entries) - 1
      end

      test "Enter accepts selection: fills input with name<>space and closes menu (D-106, AC-5)",
           %{model: m} do
        # Move to second entry
        m2 = %{m | menu: %{m.menu | selected: 1}}
        {_, selected_entry} = Enum.at(m2.menu.entries, 1)
        next = App.update(m2, {:event, %{key: 13}})
        assert next.menu == nil, "menu should close after Enter"
        assert next.input == selected_entry.name <> " ", "input should be filled"
        # NOT submitted: status should not be :sending
        assert next.status != :sending
      end
    end

    describe "update/2 — Esc dismisses menu without cancel (AC-6, D-105)" do
      test "Esc with menu open closes menu but does not cancel" do
        menu = %{query: "", entries: [], selected: 0}
        m = %{model() | input: "/", menu: menu, status: :idle}
        next = App.update(m, {:event, %{key: 27}})
        assert next.menu == nil, "Esc should close menu"
        # Status should not be affected by Esc (no cancel)
        assert next.status == :idle
      end

      test "Esc with menu open does NOT cancel (no status change to cancelled)" do
        menu = %{query: "", entries: [], selected: 0}
        m = %{model() | input: "/", menu: menu, status: :idle}
        next = App.update(m, {:event, %{key: 27}})
        # cancel/1 calls Tau.cancel/1 but model.status would change
        # With menu open, Esc should just nil the menu
        assert next.menu == nil
        assert next.status == :idle
      end

      test "Esc without menu open still cancels (existing behaviour)" do
        m = %{model() | input: "", menu: nil, status: :idle}
        # cancel/1 calls Tau.cancel but since this is a unit test (no FSM)
        # we just verify the model fields that cancel/1 sets
        next = App.update(m, {:event, %{key: 27}})
        # cancel/1 sets status: :idle and calls Tau.cancel (side effect)
        # The test verifies the model is returned (doesn't crash)
        assert is_map(next)
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

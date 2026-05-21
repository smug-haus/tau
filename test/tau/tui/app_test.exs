if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.AppTest do
    @moduledoc """
    Verifies #26: `Tau.TUI.App.update/2` reacts to `Cancelled` and
    `SessionEnd` PubSub events. Without these clauses ESC produces no
    UI feedback and a terminating session leaves the bar reading
    `streaming`.

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
        coding_agent: nil
      }
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

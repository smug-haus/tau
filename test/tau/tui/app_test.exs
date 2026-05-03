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
        last_assistant: "partial"
      }
    end

    describe "update/2 — Cancelled" do
      test "moves status into a cancelled string and appends a transcript line" do
        event = %Events.Cancelled{session_id: "sess-test", reason: :user_request}

        next = App.update(model(), event)

        assert next.status == "cancelled: :user_request"
        assert List.last(next.transcript) == "[cancelled: :user_request]"
        assert next.last_assistant == nil
      end
    end

    describe "update/2 — SessionEnd" do
      test "moves status into an ended string and appends a transcript line" do
        event = %Events.SessionEnd{session_id: "sess-test", reason: :normal}

        next = App.update(model(), event)

        assert next.status == "ended: :normal"
        assert List.last(next.transcript) == "[session ended: :normal]"
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

        last_line = List.last(next.transcript)
        assert is_binary(last_line) and last_line != "",
               "transcript MUST gain a non-empty line; got #{inspect(last_line)}"

        assert String.contains?(last_line, "Error"),
               "transcript line MUST surface the error keyword for AC-3; got #{inspect(last_line)}"
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

        assert "[assistant] (replay) hello" in next.transcript,
               "transcript MUST contain the assistant line for AC-2 render path; " <>
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

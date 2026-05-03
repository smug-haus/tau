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

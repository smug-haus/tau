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

    describe "run/0 — Ratatouille runtime API contract" do
      # Regression for the bug fixed in PR #148: `run/0` was calling
      # `Ratatouille.Runtime.run/2`, which doesn't exist. The compile-time
      # warning never failed the build (warnings-as-errors didn't trigger
      # in the env that compiled this module pre-#147), so the bug shipped
      # in the prod / Burrito binary and the TUI exited silently.
      #
      # This test invokes `run/0` in a child process and asserts the
      # process does NOT die with `:undef`. TTY-required errors from
      # ex_termbox (the binding it tries to load when no real terminal
      # is present) are acceptable — they prove the API call landed; we
      # just don't have a tty to render into.

      test "invokes a real Ratatouille.Runtime function (not :undef)" do
        # Belt: confirm the documented API exists at all.
        assert function_exported?(Ratatouille.Runtime, :start_link, 1),
               "Ratatouille.Runtime.start_link/1 not exported — pinned dep changed shape"

        # Suspenders: actually call run/0 and confirm it doesn't raise UndefinedFunctionError.
        parent = self()

        pid =
          spawn(fn ->
            try do
              Tau.TUI.App.run()
              send(parent, {:exit_reason, :ok})
            rescue
              e -> send(parent, {:exit_reason, e})
            catch
              :exit, reason -> send(parent, {:exit_reason, {:exit, reason}})
            end
          end)

        ref = Process.monitor(pid)

        receive do
          {:exit_reason, %UndefinedFunctionError{} = e} ->
            flunk(
              "Tau.TUI.App.run/0 called a non-existent function: " <>
                Exception.message(e)
            )

          {:exit_reason, _other} ->
            :ok

          {:DOWN, ^ref, :process, ^pid, {:undef, _} = reason} ->
            flunk("Tau.TUI.App.run/0 died with :undef — #{inspect(reason)}")

          {:DOWN, ^ref, :process, ^pid, _other} ->
            :ok
        after
          1_500 ->
            # The runtime started successfully and is now blocking on terminal
            # input. That's the success case for THIS test — kill it and
            # finish.
            Process.exit(pid, :kill)
            :ok
        end
      end
    end
  end
end

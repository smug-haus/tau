if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Permission do
    @moduledoc """
    Permission dialog state management and rendering for `Tau.TUI.App`.
    Handles `%PermissionRequest{}` events, key routing while the dialog is
    open, and the Ratatouille view fragment for the approval UI.

    ## Contract

    While `model.pending_permissions` is non-empty the dialog is active.
    Only `y` (allow once) and `n` (deny) resolve the head request; all other
    keystrokes are swallowed (D-172 / SPEC-PERMISSION-PROMPTS §7 AC-B4).
    SPEC-PERMISSION-PROMPTS §7 D-090..D-099.
    """

    import Ratatouille.View

    @doc """
    Handle all key input while the permission dialog is open. Only `y` and `n`
    are recognised; every other event is swallowed (AC-B4).
    """
    @spec handle_permission_dialog_event(map(), map()) :: map()
    def handle_permission_dialog_event(model, %{ch: ?y}) do
      resolve_permission(model, :allow_once)
    end

    def handle_permission_dialog_event(model, %{ch: ?n}) do
      resolve_permission(model, :deny_once)
    end

    # All other events are swallowed while the dialog is open (AC-B4).
    def handle_permission_dialog_event(model, _event), do: model

    @doc """
    Enqueue a `%PermissionRequest{}` onto the pending queue (D-170 /
    SPEC-PERMISSION-PROMPTS §7 AC-B1, AC-B8). Pure MVU — no process.
    """
    @spec on_permission_request(map(), map()) :: map()
    def on_permission_request(model, req) do
      queue = Map.get(model, :pending_permissions, [])
      Map.put(model, :pending_permissions, queue ++ [req])
    end

    @doc """
    Render the permission approval dialog for the head of the queue (D-172 /
    SPEC-PERMISSION-PROMPTS §7 AC-B1). Shows tool name, argument summary,
    decision reason, and the `y`/`n` prompt. Returns `nil` when the queue is
    empty so the caller can skip rendering.
    """
    @spec render_permission_dialog(map()) :: term() | nil
    def render_permission_dialog(%{pending_permissions: [req | _]}) do
      args_summary =
        case req.arguments do
          args when map_size(args) == 0 -> ""
          args -> Enum.map_join(args, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
        end

      row do
        column(size: 12) do
          panel title: "Permission required — [y] allow once  [n] deny" do
            label(content: "tool: " <> req.name)

            if args_summary != "" do
              label(content: "args: " <> args_summary)
            end

            label(content: "reason: " <> req.decision_reason)
            label(content: "")
            label(content: "[y] allow once    [n] deny")
          end
        end
      end
    end

    def render_permission_dialog(_model), do: nil

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    # Resolve the head permission request with `verdict`, pop it from the queue,
    # and (when a real session is running) call decide_permission/3.
    defp resolve_permission(%{pending_permissions: [head | rest]} = model, verdict) do
      # decide_permission/3 is a cast (non-blocking); call directly like Tau.send/2.
      Tau.Session.decide_permission(model.session_id, head.tool_call_id, verdict)
      %{model | pending_permissions: rest}
    end

    defp resolve_permission(model, _verdict), do: model
  end
end

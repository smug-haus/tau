if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Input do
    @moduledoc """
    User-input submission and in-turn control actions for `Tau.TUI.App`.
    Owns submit, steer, followup, cancel, clear, and the `/perms` command handler.
    All functions are pure except for the side-effectful Tau session calls.
    """

    alias Tau.TUI.Editor
    alias Tau.TUI.History
    alias Tau.TUI.History.Store

    # Valid permissions modes for /perms command (AC-B6, D-170).
    @valid_perms_modes [:default, :accept_edits, :plan]

    @doc """
    Submit the editor contents to the session. No-op on empty input. Intercepts
    `/perms <mode>` before forwarding to the session (D-173 / SPEC-PERMISSION-PROMPTS §7 AC-B6).
    """
    @spec submit(map()) :: map()
    def submit(model) do
      text = Editor.text(model.editor)

      if Editor.empty?(model.editor) do
        model
      else
        # D-173 / SPEC-PERMISSION-PROMPTS §7 AC-B6:
        # Intercept /perms <mode> in the TUI layer before sending to the session.
        if String.starts_with?(text, "/perms") do
          handle_perms_command(model, text)
        else
          Tau.send(model.session_id, text)
          new_hist = History.push(model.history, text)
          Store.append(model.history_data_dir, model.history_cwd, text)

          %{
            model
            | editor: Editor.new(),
              history: new_hist,
              search: nil,
              transcript: bounded_append(model.transcript, {"> " <> text, []}),
              status: :sending
          }
        end
      end
    end

    @doc """
    Check for a trailing backslash before submitting. If the grapheme immediately
    before the cursor is `\\`, strip it and insert a real newline instead of
    submitting (D-145). Otherwise delegates to `submit/1`.
    """
    @spec submit_or_continue(map()) :: map()
    def submit_or_continue(model) do
      ed = model.editor
      {row, col} = ed.cursor
      line = Enum.at(ed.lines, row, "")
      graphemes = String.graphemes(line)

      if col > 0 and Enum.at(graphemes, col - 1) == "\\" do
        ed_no_bs = Editor.backspace(ed)
        ed_newline = Editor.newline(ed_no_bs)
        %{model | editor: ed_newline, search: nil}
      else
        submit(model)
      end
    end

    @doc """
    Handle the `/perms <mode>` slash command in the TUI layer (D-173 /
    SPEC-PERMISSION-PROMPTS §7 AC-B6 / AC-B7).

    Valid modes: `:default`, `:accept_edits`, `:plan`. While streaming/sending,
    the mode does not change (FSM rejects `:busy` per D-096). No/invalid
    argument reports current mode and the valid set.
    """
    @spec handle_perms_command(map(), String.t()) :: map()
    def handle_perms_command(model, text) do
      arg =
        case String.split(text, " ", parts: 2) do
          ["/perms", rest] -> String.trim(rest)
          _ -> ""
        end

      mode =
        case arg do
          "default" -> :default
          "accept_edits" -> :accept_edits
          "plan" -> :plan
          _ -> nil
        end

      model_cleared = %{model | editor: Editor.new(), search: nil}

      cond do
        mode == nil ->
          valid_set = Enum.map_join(@valid_perms_modes, ", ", &to_string/1)

          notice =
            "permissions_mode is #{model.permissions_mode}. " <>
              "Valid modes: #{valid_set}"

          %{model_cleared | transcript: bounded_append(model_cleared.transcript, {notice, []})}

        model.status in [:streaming, :sending] or is_binary(model.status) ->
          # AC-B7: mid-turn, do not change mode (FSM rejects :busy per D-096).
          model_cleared

        true ->
          # AC-B6: set mode locally and call FSM; set_permissions_mode/2 is a
          # cast (non-blocking), called directly like Tau.send/2.
          Tau.Session.set_permissions_mode(model.session_id, mode)
          %{model_cleared | permissions_mode: mode}
      end
    end

    @doc """
    Cancel the active session turn. Sets status to `:idle`.
    """
    @spec cancel(map()) :: map()
    def cancel(model) do
      Tau.cancel(model.session_id)
      %{model | status: :idle}
    end

    @doc """
    Enqueue the current editor text as a steering message (D-077 / AC-2).
    Delivered at the next tool-round boundary before the next provider call.
    No-op on empty input. Clears the editor and appends a `[queued steer]`
    notice to the transcript.
    """
    @spec steer(map()) :: map()
    def steer(model) do
      text = Editor.text(model.editor)

      if Editor.empty?(model.editor) do
        model
      else
        Tau.steer(model.session_id, text)

        %{
          model
          | editor: Editor.new(),
            search: nil,
            transcript: bounded_append(model.transcript, {"[queued steer] " <> text, []})
        }
      end
    end

    @doc """
    Enqueue the current editor text as a follow-up message (D-078 / AC-3).
    Delivered after the whole turn completes. When the session is idle, falls
    back to normal submit. No-op on empty input.
    """
    @spec followup(map()) :: map()
    def followup(model) do
      text = Editor.text(model.editor)

      cond do
        Editor.empty?(model.editor) ->
          model

        model.status == :idle ->
          # Idle: treat as normal submit (both tiers collapse to "run now").
          submit(model)

        true ->
          Tau.send(model.session_id, text)

          %{
            model
            | editor: Editor.new(),
              search: nil,
              transcript: bounded_append(model.transcript, {"[queued follow-up] " <> text, []})
          }
      end
    end

    @doc """
    Clear the editor without quitting (D-078 / AC-6). Called on Esc while idle.
    """
    @spec clear_input(map()) :: map()
    def clear_input(model) do
      %{model | editor: Editor.new(), search: nil}
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    @transcript_cap 500

    defp bounded_append(list, item) do
      new_list = list ++ [item]

      if length(new_list) > @transcript_cap do
        Enum.drop(new_list, length(new_list) - @transcript_cap)
      else
        new_list
      end
    end
  end
end

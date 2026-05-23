if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Events do
    @moduledoc """
    Session-event dispatcher and handlers for `Tau.TUI.App`. Owns the
    `update/2` body that pattern-matches on the full set of `%Tau.Session.Events.*{}`
    structs and folds them into the MVU model.

    ## Contract

    `update/2` is the `@behaviour Ratatouille.App` callback body; it is
    called from the delegating stub on `Tau.TUI.App`. The `update/2` clause
    order is load-bearing: named event structs match before the catch-all
    `update_session_event/2` sub-handler.
    """

    alias Tau.TUI.App.History, as: HistoryHelpers
    alias Tau.TUI.App.Keymap
    alias Tau.TUI.App.Completion
    alias Tau.TUI.App.Permission
    alias Tau.TUI.Render.Markdown
    alias Tau.TUI.SubagentTree
    alias Tau.TUI.StatusBar

    @transcript_cap 500

    @doc """
    Primary MVU event dispatcher. Matches on every known message shape and
    delegates to per-event handlers. The `:tick` clause drains the EventBridge
    buffer. The `{:event, event}` clause routes terminal keystrokes to `Keymap`.
    """
    @spec update(map(), term()) :: map()
    def update(model, msg) do
      case msg do
        {:event, event} ->
          Keymap.handle_event(model, event)

        # Resize: update wrap_width so subsequent wraps use the new terminal width
        {:resize, %{w: w}} ->
          %{model | wrap_width: transcript_pane_width(w)}

        {:resize, _} ->
          model

        :tick ->
          drain_bridge(model)

        %Tau.Session.Events.MessageStart{} = e ->
          on_message_start(model, e)

        %Tau.Session.Events.MessageUpdate{} = e ->
          on_message_update(model, e)

        %Tau.Session.Events.MessageEnd{} = e ->
          on_message_end(model, e)

        %Tau.Session.Events.ToolStart{} = e ->
          on_tool_start(model, e)

        %Tau.Session.Events.ToolEnd{} = e ->
          on_tool_end(model, e)

        %Tau.Session.Events.Cancelled{} = e ->
          on_cancelled(model, e)

        %Tau.Session.Events.SessionEnd{} = e ->
          on_session_end(model, e)

        %Tau.Session.Events.SystemNotice{text: t} ->
          %{model | transcript: bounded_append(model.transcript, {t, []})}

        # Delegate the remaining session-state events to a sub-handler to
        # keep update/2 cyclomatic complexity within the Credo limit (≤ 25).
        event ->
          update_session_event(model, event)
      end
    end

    @doc """
    Sub-handler for session-state events that do not fit the primary `update/2`
    case without exceeding the complexity budget.
    D-160, D-103, D-170, D-082, D-150..D-154 all live here.
    """
    @spec update_session_event(map(), term()) :: map()
    def update_session_event(model, event) do
      case event do
        # D-160 / SPEC-TUI-HEADLESS §5d: seed model/provider/context_window
        # from SessionStart. context_window resolved via optional callback.
        %Tau.Session.Events.SessionStart{model: m, provider: p} = e ->
          on_session_start_status(model, e, m, p)

        # D-160: ModelSwapped — update model segment in the status bar.
        # Do NOT string-scrape the accompanying SystemNotice (D-160 rationale).
        %Tau.Session.Events.ModelSwapped{} = e ->
          on_model_swapped(model, e)

        # D-163: CompactionStarted — transition compaction to :running.
        %Tau.Session.Events.CompactionStarted{} ->
          on_compaction_started(model)

        # D-164: CompactionFinished — clear compaction indicator regardless
        # of outcome (S-2: MUST fire on every :compacting exit, incl. abort/error).
        %Tau.Session.Events.CompactionFinished{} ->
          on_compaction_finished(model)

        # D-103 (SPEC-TUI-COMPLETION §4 B1): store the catalog and re-filter
        # the menu if it is currently open. Broadcast arrives at SessionStart
        # and after /reload (D-108).
        %Tau.Session.Events.CommandCatalog{entries: entries} ->
          model
          |> Map.put(:catalog, entries)
          |> Completion.update_menu()

        # D-170 / SPEC-PERMISSION-PROMPTS §7 AC-B1, AC-B8:
        # Push a PermissionRequest onto the pending_permissions queue.
        # The dialog renders the head; resolving it pops the head (AC-B2/B3).
        # Pure MVU state — no new process (OTP non-negotiables #3/#8).
        %Tau.Session.Events.PermissionRequest{} = req ->
          Permission.on_permission_request(model, req)

        # D-082 / SPEC-USER-TURN §6: restore queued steering messages to
        # the input editor when a cancel is issued mid-turn. The FSM drains the
        # steering queue back to the user via this event. The TUI repopulates the
        # editor with the first queued message (joining multiple with "\n" as a
        # best-effort single-line representation; the multi-line editor handles
        # multi-line content natively). Idempotent: re-delivery of the same
        # event replaces the editor with the same content.
        %Tau.Session.Events.QueueRestored{messages: msgs} when msgs != [] ->
          on_queue_restored(model, msgs)

        %Tau.Session.Events.QueueRestored{} ->
          model

        # D-150..D-154 (SPEC-TUI-HEADLESS §5c): sub-agent lifecycle events.
        # Fold into the sub-agent tree AND append boxed markers to the transcript.
        # SubagentStart: add node + append start marker line.
        %Tau.Session.Events.SubagentStart{} = e ->
          on_subagent_start(model, e)

        # SubagentProgress: update node state (tool_calls, last_activity).
        %Tau.Session.Events.SubagentProgress{} = e ->
          on_subagent_progress(model, e)

        # SubagentCost: update node cost fields.
        %Tau.Session.Events.SubagentCost{} = e ->
          on_subagent_cost(model, e)

        # SubagentEnd: transition node to terminal state + append end marker line.
        %Tau.Session.Events.SubagentEnd{} = e ->
          on_subagent_end(model, e)

        _ ->
          model
      end
    end

    @doc """
    Each tick, fold every event the EventBridge has buffered through the same
    handlers used by the unit tests (which call `update/2` directly).
    """
    @spec drain_bridge(map()) :: map()
    def drain_bridge(model) do
      model.session_id
      |> Tau.TUI.EventBridge.drain()
      |> Enum.reduce(model, fn event, acc -> update(acc, event) end)
    end

    # ---------------------------------------------------------------------------
    # Per-event private handlers
    # ---------------------------------------------------------------------------

    defp on_message_start(model, _e), do: %{model | status: :streaming, last_assistant: ""}

    defp on_message_update(model, %{message: msg}) do
      text =
        msg.content
        |> Enum.filter(&match?(%{type: :text}, &1))
        |> Enum.map_join("", & &1.text)

      %{model | last_assistant: text}
    end

    defp on_message_end(model, %{message: msg} = e) do
      transcript_lines =
        msg.content
        |> Enum.flat_map(fn block ->
          case block do
            %{type: :text, text: t} ->
              # D-028: render markdown (CommonMark + GFM tables)
              # in the TUI pane. Render.Markdown emits {content, attrs} tuples;
              # carry both through model.transcript so render/1 can apply attrs
              # to each label (AC-6: bold/colour/underline reach the terminal).
              styled_lines = Markdown.render(t)
              [{"[assistant]", []} | styled_lines]

            # Thinking models (Qwen3, DeepSeek-R1) emit chain-of-thought
            # via Thinking* events. Surface them so a long think doesn't
            # look like the TUI is hung.
            %{type: :thinking, text: t} when is_binary(t) and t != "" ->
              [{"[thinking] " <> t, []}]

            # B1 rule (D-151): if this tool call's id is owned by a known
            # sub-agent, do NOT render it as a bare [tool_call] line —
            # the sub-agent start/end markers own the visual representation.
            # For Agent tool calls without an owned id, fall back to the
            # legacy inline render (backwards compat).
            %{type: :tool_call, id: tcid, name: n} when is_binary(tcid) ->
              if SubagentTree.tool_call_owned?(model.subagents, tcid) do
                []
              else
                [{"[tool_call] " <> n <> "(...)", []}]
              end

            %{type: :tool_call, name: n} ->
              [{"[tool_call] " <> n <> "(...)", []}]

            _ ->
              []
          end
        end)

      # D-169 / S-4: context_tokens is OVERWRITTEN with the latest turn's
      # input_tokens (not cumulative). Pre-first-turn reads 0. This avoids the
      # >100% context-bar bug. Source: Tau.Cost.for_session/1 ETS table.
      session_counters = cost_for_session(model.session_id)
      session_msg = e.message
      # Extract this turn's input_tokens directly from the message usage field.
      turn_input_tokens = get_in(session_msg, [Access.key(:usage, %{}), :input_tokens]) || 0

      # D-169: context_tokens = latest turn's input_tokens (overwrite, never sum).
      new_context_tokens = turn_input_tokens

      # Telemetry: emit only on warn_level transition (D-168).
      pct =
        StatusBar.context_pct(
          new_context_tokens,
          Map.get(model, :context_window) ||
            Application.get_env(:tau, :compaction_threshold_tokens, 120_000)
        )

      new_warn = StatusBar.warn_level(pct)
      prior_warn = Map.get(model, :warn_level, :ok)

      if new_warn != prior_warn do
        :telemetry.execute(
          [:tau, :tui, :status, :update],
          %{system_time: System.system_time()},
          %{context_pct: pct, warn_level: new_warn, session_id: model.session_id}
        )
      end

      model
      |> Map.put(:status, :idle)
      |> Map.put(:transcript, bounded_append_many(model.transcript, transcript_lines))
      |> Map.put(:last_assistant, nil)
      |> Map.put(:usage, session_counters)
      |> Map.put(:context_tokens, new_context_tokens)
      |> Map.put(:warn_level, new_warn)
    end

    # Read session counters from the Tau.Cost ETS table (the source of truth).
    # Tolerates the table being unavailable (test isolation without Tracker running).
    defp cost_for_session(session_id) do
      try do
        Tau.Cost.for_session(session_id)
      rescue
        ArgumentError ->
          %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}
      end
    end

    # B1 rule (D-151): ToolStart/ToolEnd on the parent topic are no-ops.
    # Calls owned by a sub-agent: the live region and end marker own the
    # visual representation.
    defp on_tool_start(model, _e), do: model

    defp on_tool_end(model, _e), do: model

    defp on_cancelled(model, %{reason: reason}) do
      reason_str = inspect(reason)

      %{
        model
        | status: "cancelled: " <> reason_str,
          transcript: bounded_append(model.transcript, {"[cancelled: " <> reason_str <> "]", []}),
          last_assistant: nil
      }
    end

    defp on_session_end(model, %{reason: reason}) do
      reason_str = inspect(reason)

      %{
        model
        | status: "ended: " <> reason_str,
          transcript:
            bounded_append(model.transcript, {"[session ended: " <> reason_str <> "]", []}),
          last_assistant: nil
      }
    end

    # D-160 / SPEC-TUI-HEADLESS §5d: seed model/provider fields from the
    # SessionStart event. The context_window is resolved once via the optional
    # context_window/1 callback; nil means use the fallback (~NN%).
    defp on_session_start_status(model, _e, m, p) do
      context_window = resolve_context_window(p, m)
      %{model | model: m, provider: p, context_window: context_window}
    end

    # D-160: update the model segment when the user does /model <id>.
    # Resolves the new context_window for the swapped model.
    defp on_model_swapped(model, %{to: new_model}) do
      provider = Map.get(model, :provider)
      context_window = resolve_context_window(provider, new_model)
      %{model | model: new_model, context_window: context_window}
    end

    # Resolve context_window via the optional context_window/1 callback.
    # Ensures the module is loaded first (function_exported?/3 only works on
    # loaded modules; in production all provider modules are loaded at startup;
    # in tests we must load explicitly to avoid false negatives).
    defp resolve_context_window(provider, model_id)
         when is_atom(provider) and is_binary(model_id) do
      _ = Code.ensure_loaded(provider)

      if function_exported?(provider, :context_window, 1) do
        provider.context_window(model_id)
      else
        nil
      end
    end

    defp resolve_context_window(_provider, _model_id), do: nil

    # D-163: CompactionStarted — transition to :running.
    defp on_compaction_started(model), do: %{model | compaction: :running}

    # D-164 / S-2: CompactionFinished — clear to :idle regardless of outcome.
    # This MUST fire on every exit from the :compacting FSM state, including abort/error,
    # so the "compacting…" indicator never sticks in the status bar.
    defp on_compaction_finished(model), do: %{model | compaction: :idle}

    # D-150 / D-158 (SPEC-TUI-HEADLESS §5c): fold SubagentStart into the tree.
    # No static start marker is appended to the transcript — the running sub-agent
    # appears in the live region (rendered every frame from model.subagents by render/1)
    # so the tool-call count and activity excerpt update live (AC-3).
    # The permanent `└─` end marker is appended by on_subagent_end/2 when the
    # node transitions to a terminal state (AC-2).
    # If the fold rejects the event (unknown kind, D-152), model is unchanged.
    defp on_subagent_start(model, e) do
      new_tree = SubagentTree.fold(model.subagents, e)

      if Map.has_key?(new_tree, e.subagent_id) do
        %{model | subagents: new_tree}
      else
        # Unknown kind — tree unchanged (D-152).
        model
      end
    end

    # D-151 (SPEC-TUI-HEADLESS §5c): fold SubagentProgress — updates the node's
    # tool_calls count and last_activity. No transcript line; the end marker
    # carries the final rollup (AC-3).
    defp on_subagent_progress(model, e) do
      %{model | subagents: SubagentTree.fold(model.subagents, e)}
    end

    # D-153 (SPEC-TUI-HEADLESS §5c): fold SubagentCost — updates cost fields
    # in the node. Does NOT affect the parent's own cost display (R4/AC-4).
    defp on_subagent_cost(model, e) do
      %{model | subagents: SubagentTree.fold(model.subagents, e)}
    end

    # D-154 (SPEC-TUI-HEADLESS §5c): fold SubagentEnd — transitions node to
    # terminal state and appends the boxed end marker to the transcript (AC-2).
    # If the fold ignores the event (unknown subagent_id, D-152), skip marker.
    defp on_subagent_end(model, e) do
      new_tree = SubagentTree.fold(model.subagents, e)

      case Map.get(new_tree, e.subagent_id) do
        nil ->
          # Unknown subagent_id — no node, no marker (D-152).
          model

        node ->
          marker = SubagentTree.format_end_marker(node)

          %{
            model
            | subagents: new_tree,
              transcript: bounded_append(model.transcript, {marker, []})
          }
      end
    end

    # D-082 / SPEC-USER-TURN §6: restore queued steering messages to the
    # editor from a %QueueRestored{} event.
    defp on_queue_restored(model, msgs) do
      text =
        msgs
        |> Enum.map(fn
          %Tau.Message.User{content: content} ->
            content
            |> Enum.filter(&match?(%{type: :text}, &1))
            |> Enum.map_join("\n", & &1.text)

          s when is_binary(s) ->
            s

          _ ->
            ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      new_editor = HistoryHelpers.restore_editor_from_text(text)
      %{model | editor: new_editor}
    end

    # ---------------------------------------------------------------------------
    # Bounded transcript helpers
    # ---------------------------------------------------------------------------

    @doc """
    Append `item` to `list`, dropping the oldest entry when the transcript cap
    is exceeded. Each item is a `{text, attrs}` tuple (ring-buffer semantics).
    """
    @spec bounded_append([{String.t(), keyword()}], {String.t(), keyword()}) ::
            [{String.t(), keyword()}]
    def bounded_append(list, item) do
      new_list = list ++ [item]

      if length(new_list) > @transcript_cap do
        Enum.drop(new_list, length(new_list) - @transcript_cap)
      else
        new_list
      end
    end

    @doc """
    Append multiple items to the transcript in order, applying the cap after
    each append.
    """
    @spec bounded_append_many([{String.t(), keyword()}], [{String.t(), keyword()}]) ::
            [{String.t(), keyword()}]
    def bounded_append_many(list, items) do
      Enum.reduce(items, list, &bounded_append(&2, &1))
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    defp transcript_pane_width(terminal_width) when terminal_width >= 4 do
      terminal_width - 2
    end

    defp transcript_pane_width(_terminal_width), do: 1
  end
end

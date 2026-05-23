defmodule Tau.Commands.Builtin.Compact do
  @moduledoc """
  Built-in `/compact` slash command.

  Triggers asynchronous compaction of the conversation history off the
  `:gen_statem` critical path.  The FSM transitions to `:compacting` and
  returns to `:awaiting_user` when the worker finishes, fails, is
  cancelled, or times out (D-048, D-049).

  ## Outcome

  Returns `{:async_compact, notice}` — the only `t:Tau.Commands.Builtin.outcome/0`
  that changes FSM state.  The session FSM handles the transition; this
  module is a pure predicate that decides *whether* compaction should start.

  ## Guard conditions

  - `{:error, "Nothing to compact."}` — message list is empty or contains
    only a single compaction-summary message (no substantive content to
    summarise).
  - `{:error, "Compaction already in progress."}` — a worker is already
    running (`compaction_task != nil`).
  """

  @behaviour Tau.Commands.Builtin

  @impl Tau.Commands.Builtin
  def name, do: "/compact"

  @impl Tau.Commands.Builtin
  def description, do: "Summarise and compress the conversation history"

  @impl Tau.Commands.Builtin
  def run(_args, data) do
    cond do
      data.compaction_task != nil ->
        {:error, "Compaction already in progress."}

      trivial_messages?(data.messages) ->
        {:error, "Nothing to compact."}

      true ->
        {:async_compact, "Compacting conversation…"}
    end
  end

  # Empty list or a single compaction-summary marker — nothing useful to compact.
  defp trivial_messages?([]), do: true

  defp trivial_messages?([%Tau.Message.User{metadata: %{role: :compaction_summary}}]), do: true

  defp trivial_messages?(_), do: false
end

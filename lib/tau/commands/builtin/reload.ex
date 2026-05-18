defmodule Tau.Commands.Builtin.Reload do
  @moduledoc """
  Built-in `/reload` command.

  Re-discovers skills from disk and re-reads the settings cascade for
  the current session without restarting the session process.

  Returns `{:mutate, fun, notice}` where `fun` is a pure `data -> data`
  transform that:

  1. Calls `Tau.Skills.Loader.discover(data.cwd)` and
     `Tau.Skills.Loader.list_extension_skills/0` to rebuild the skill
     list, matching the merge/dedup/sort logic in `Session.load_skills/1`.
  2. Replaces `data.skills` with the refreshed list.

  Settings re-read is implicit: `Tau.Settings.Cache` is a supervised
  process that caches the parsed settings file.  Any provider or tool
  that reads settings via `Tau.Settings.Cache.get/0` on the next call
  will see the updated values automatically.  `/reload` does not need
  to push a new settings snapshot into `data` — no session FSM field
  carries a snapshot of settings at init time.

  ## Safety (D-007 complement)

  The `{:mutate, fun, notice}` outcome only fires in the
  `:awaiting_user` / `command_task: nil` dispatch arm
  (`Session.handle_event/4` line ~693).  Any `/reload` message cast
  while the FSM is in another state (`:provider_streaming`, etc.) is
  postponed by the outer `when state != :awaiting_user` guard and
  re-delivered only when the FSM returns to `:awaiting_user`.  The
  `fun` closure is therefore always applied to a quiescent `data`
  snapshot — no mid-stream data corruption is possible.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Skills.Loader, as: SkillsLoader

  @impl Tau.Commands.Builtin
  def name, do: "/reload"

  @impl Tau.Commands.Builtin
  def run(_args, _data) do
    fun = fn data ->
      discovered = SkillsLoader.discover(data.cwd)
      extension = SkillsLoader.list_extension_skills()

      skills =
        (extension ++ discovered)
        |> Enum.uniq_by(fn {name, _} -> name end)
        |> Enum.sort_by(fn {name, _} -> name end)

      %{data | skills: skills}
    end

    {:mutate, fun, "Reloaded settings and skills."}
  end
end

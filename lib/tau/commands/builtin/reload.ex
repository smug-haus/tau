defmodule Tau.Commands.Builtin.Reload do
  @moduledoc """
  Built-in `/reload` command.

  Re-discovers skills and prompt templates from disk and re-reads the
  settings cascade for the current session without restarting the session
  process.

  Returns `{:mutate, fun, notice}` where `fun` is a `data -> data`
  closure that:

  1. Calls `Tau.Skills.Loader.discover(data.cwd)` and
     `Tau.Skills.Loader.list_extension_skills/0` to rebuild the skill
     list, matching the merge/dedup/sort logic in `Session.load_skills/1`.
  2. Replaces `data.skills` with the refreshed list.
  3. Calls `Tau.PromptTemplates.discover(data.cwd)` to rebuild the prompt
     template list (AC-7 / #183) and replaces `data.prompt_templates`.

  **IO note:** `Skills.Loader.discover/1` and `PromptTemplates.discover/1`
  perform a bounded local-disk scan.  This IO runs inline on the session
  `:gen_statem` process when `session.ex`'s `handle_builtin_command/4`
  calls `fun.(data)`.

  **Justification for inline IO:** `/reload` is dispatched only from the
  `:awaiting_user` / `command_task: nil` arm — i.e. the FSM is quiescent
  and the user is waiting for the result of the command they just
  explicitly invoked.  The scan is the same bounded local-directory
  operation the session already performs unconditionally at `init/1`.
  No provider turn is in flight during dispatch.  Off-loading the IO to
  a task process would add scheduling complexity for no practical benefit
  on a command that is driven by human interaction.

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
  `fun` closure is applied to a quiescent `data` snapshot — no
  mid-stream data corruption is possible.
  """

  @behaviour Tau.Commands.Builtin

  alias Tau.Skills.Loader, as: SkillsLoader

  @impl Tau.Commands.Builtin
  def name, do: "/reload"

  @impl Tau.Commands.Builtin
  def description, do: "Reload settings, skills, and prompt templates from disk"

  @impl Tau.Commands.Builtin
  def run(_args, _data) do
    fun = fn data ->
      discovered = SkillsLoader.discover(data.cwd)
      extension = SkillsLoader.list_extension_skills()

      skills =
        (extension ++ discovered)
        |> Enum.uniq_by(fn {name, _} -> name end)
        |> Enum.sort_by(fn {name, _} -> name end)

      prompt_templates = Tau.PromptTemplates.discover(data.cwd)

      %{data | skills: skills, prompt_templates: prompt_templates}
    end

    {:mutate, fun, "Reloaded settings, skills, and prompt templates."}
  end
end

defmodule Tau.Commands.Catalog do
  @moduledoc """
  Pure projection of all resolvable slash-commands into a flat, ordered list.

  `list/1` folds four sources in precedence order and applies the same
  conflict-resolution as `Tau.Session.classify_slash_command/2`:

      builtin > extension > file > skill > template   (D-107)

  This module is **stateless** — it is a pure function of its inputs with
  no process, no cache, and no Registry writes (OTP non-negotiable #3).

  ## Candidate sources

  1. `Tau.Commands.Builtin.table/0` — compile-time built-ins (always present).
  2. `Registry.select(Tau.Commands.Registry, ...)` — extension + file commands
     registered at runtime.
  3. `session_data.skills` — `/skill:name` entries from the session.
  4. `session_data.prompt_templates` — the session-owned prompt-template list
     (a `[{name, template}]` keyword list refreshed by `/reload`). Consistent
     with `classify_slash_command/2` which reads the same field
     (SPEC-TUI-COMPLETION §3). No-ops cleanly when the field is absent or empty.

  ## Entry shape

      %{name: "/help", description: "...", origin: :builtin | :extension | :file | :skill | :template}
  """

  alias Tau.Commands.Builtin

  @type origin :: :builtin | :extension | :file | :skill | :template

  @type entry :: %{
          name: String.t(),
          description: String.t(),
          origin: origin()
        }

  @doc """
  Build the catalog list from session data.

  `session_data` is a map with at least `:skills` and optionally
  `:prompt_templates`. Passing an empty map is safe — builtin entries are
  always produced from the compile-time `Builtin.table/0`.

  Precedence: builtin > extension > file > skill > template.
  Same-named entries from lower-precedence sources are silently dropped so
  the catalog matches `classify_slash_command/2` (D-107).
  """
  @spec list(map()) :: [entry()]
  def list(session_data) when is_map(session_data) do
    builtin_entries = builtin_entries()
    taken = MapSet.new(builtin_entries, & &1.name)

    {extension_entries, taken} = extension_entries(taken)
    {skill_entries, taken} = skill_entries(session_data, taken)
    {template_entries, _taken} = template_entries(session_data, taken)

    builtin_entries ++ extension_entries ++ skill_entries ++ template_entries
  end

  # --- private source folds ---

  defp builtin_entries do
    Builtin.table()
    |> Enum.map(fn {name, mod} ->
      desc =
        if function_exported?(mod, :description, 0) do
          mod.description()
        else
          ""
        end

      %{name: name, description: desc, origin: :builtin}
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp extension_entries(taken) do
    entries =
      case Registry.select(Tau.Commands.Registry, [
             {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
           ]) do
        list when is_list(list) ->
          list
          |> Enum.map(fn {name, _pid, mod_or_path} ->
            origin = if is_binary(mod_or_path), do: :file, else: :extension

            desc =
              if is_atom(mod_or_path) and function_exported?(mod_or_path, :description, 0) do
                mod_or_path.description()
              else
                ""
              end

            %{name: name, description: desc, origin: origin}
          end)
          |> Enum.reject(fn e -> MapSet.member?(taken, e.name) end)
          |> Enum.sort_by(& &1.name)

        _ ->
          []
      end

    new_taken = Enum.reduce(entries, taken, fn e, acc -> MapSet.put(acc, e.name) end)
    {entries, new_taken}
  rescue
    _ -> {[], taken}
  end

  defp skill_entries(%{skills: skills}, taken) when is_list(skills) do
    entries =
      skills
      |> Enum.map(fn {name, _skill} ->
        %{name: "/" <> name, description: "skill", origin: :skill}
      end)
      |> Enum.reject(fn e -> MapSet.member?(taken, e.name) end)
      |> Enum.sort_by(& &1.name)

    new_taken = Enum.reduce(entries, taken, fn e, acc -> MapSet.put(acc, e.name) end)
    {entries, new_taken}
  end

  defp skill_entries(_session_data, taken), do: {[], taken}

  defp template_entries(%{prompt_templates: templates}, taken) when is_list(templates) do
    entries =
      templates
      |> Enum.map(fn {name, _template} ->
        %{name: "/" <> name, description: "prompt template", origin: :template}
      end)
      |> Enum.reject(fn e -> MapSet.member?(taken, e.name) end)
      |> Enum.sort_by(& &1.name)

    new_taken = Enum.reduce(entries, taken, fn e, acc -> MapSet.put(acc, e.name) end)
    {entries, new_taken}
  end

  defp template_entries(_session_data, taken), do: {[], taken}
end

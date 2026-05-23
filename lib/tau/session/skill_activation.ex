defmodule Tau.Session.SkillActivation do
  @moduledoc """
  Skill discovery, tool-spec derivation, and skill activation for `Tau.Session`.

  Covers skill loading from disk and extensions, building the model-visible
  tool-spec list, handling `__activate_skill__` tool calls dispatched by the
  model, processing user-initiated slash-command activations, and injecting
  skill and memory system messages into the conversation.

  ## States

  - `:turn` lifetime — `active_skill` is cleared at `:end_turn`.
  - `:session` lifetime — `active_skill` survives `:end_turn` (sub-agent personas).

  ## Invariants

  - Skill precedence: builtin > extension > file-command > skill > template.
  - `disable_model_invocation: true` skills are never included in the
    model-visible tool spec (ADR-0013 / ADR-0015).
  - `:turn` lifetime clears `active_skill` on `:end_turn`; `:session` survives.
  """

  alias Tau.Message.ToolResult
  alias Tau.Session.Events

  @activate_skill_tool_name "__activate_skill__"

  @doc """
  Load skills from the filesystem and registered extensions for `cwd`.

  Merges extension-provided skills and cwd-discovered skills, deduplicating by
  name (filesystem wins on conflict). Returns an alphabetically sorted list of
  `{name, %Tau.Skill{}}` pairs and emits a `:tau, :skills, :loaded` telemetry
  event when skills are found.
  """
  @spec load_skills(String.t()) :: [{String.t(), Tau.Skill.t()}]
  def load_skills(cwd) do
    discovered = Tau.Skills.Loader.discover(cwd)
    extension = Tau.Skills.Loader.list_extension_skills()

    skills =
      (extension ++ discovered)
      |> Enum.uniq_by(fn {name, _} -> name end)
      |> Enum.sort_by(fn {name, _} -> name end)

    if skills != [] do
      active_count = Enum.count(skills, fn {_n, s} -> not s.disable_model_invocation end)

      :telemetry.execute(
        [:tau, :skills, :loaded],
        %{count: length(skills), active: active_count, skipped: length(skills) - active_count},
        %{cwd: cwd}
      )
    end

    skills
  end

  @doc """
  Prepend skill system messages to the message list.

  Produces one user-role system message per active (non-disabled) skill,
  placing them at the front of the history so the model sees them as
  context before any conversation turns.
  """
  @spec prepend_skill_messages([Tau.Message.t()], [{String.t(), Tau.Skill.t()}]) ::
          [Tau.Message.t()]
  def prepend_skill_messages(messages, skills) do
    active = Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)

    case active do
      [] ->
        messages

      list ->
        Enum.map(list, fn {name, %Tau.Skill{} = s} ->
          Tau.Message.User.new(render_skill(name, s),
            metadata: %{role: :system, source: :skill, name: name, path: s.path}
          )
        end) ++ messages
    end
  end

  @doc """
  Prepend memory system messages to the message list.

  Loads the memory cascade for `cwd` and injects each memory file as a
  user-role system message at the front of the history.
  """
  @spec inject_memory([Tau.Message.t()], String.t()) :: [Tau.Message.t()]
  def inject_memory(messages, cwd) do
    case Tau.Memory.Loader.load(cwd) do
      [] ->
        messages

      cascade ->
        bytes = Enum.reduce(cascade, 0, fn {_p, b}, acc -> acc + byte_size(b) end)

        :telemetry.execute(
          [:tau, :memory, :loaded],
          %{file_count: length(cascade), bytes: bytes},
          %{cwd: cwd}
        )

        memory_messages =
          Enum.map(cascade, fn {path, body} ->
            Tau.Message.User.new(body, metadata: %{role: :system, source: :memory, path: path})
          end)

        memory_messages ++ messages
    end
  end

  @doc """
  Return the model-visible tool-spec list for the current session data.

  Combines the synthetic `__activate_skill__` spec (when model-invokable
  skills exist) with the active skill's allowed-tools specs. Returns `nil`
  when no tools should be exposed to the provider (some providers reject an
  empty `:tools` array — D-059).
  """
  @spec model_visible_tool_specs(Tau.Session.Data.t()) :: [map()] | nil
  def model_visible_tool_specs(data) do
    activation = skill_activation_tool_spec(data.skills)
    skill_specs = active_skill_tool_specs(data.active_skill)

    case {activation, skill_specs} do
      {nil, []} -> nil
      {nil, list} -> list
      {spec, []} -> [spec]
      {spec, list} -> [spec | list]
    end
  end

  @doc """
  Place a single tool spec under the `:tools` key in `opts`, or return `opts`
  unchanged when `spec` is nil or an empty list.
  """
  @spec maybe_put_tools(map(), map() | [map()] | nil) :: map()
  def maybe_put_tools(opts, nil), do: opts
  def maybe_put_tools(opts, []), do: opts

  def maybe_put_tools(opts, tool_specs) when is_list(tool_specs),
    do: Map.put(opts, :tools, tool_specs)

  def maybe_put_tools(opts, tool_spec) when is_map(tool_spec),
    do: Map.put(opts, :tools, [tool_spec])

  @doc """
  Handle all `__activate_skill__` tool calls in `calls` inline.

  Returns `{updated_data, in_flight_map}` where `in_flight_map` maps each
  call id to `:activated` so the FSM tracks these alongside regular tool
  results.
  """
  @spec handle_skill_activations(
          [map()],
          Tau.Session.Data.t(),
          pid()
        ) :: {Tau.Session.Data.t(), map()}
  def handle_skill_activations([], data, _parent), do: {data, %{}}

  def handle_skill_activations(calls, data, parent) do
    Enum.reduce(calls, {data, %{}}, fn %{id: id, name: tool_name, arguments: args},
                                       {data_acc, in_flight_acc} ->
      requested = skill_name_from_args(args)

      {data_acc, result} = activate_skill(data_acc, requested, id)

      :telemetry.execute(
        [:tau, :session, :skill_activated],
        %{system_time: System.system_time()},
        %{
          session_id: data_acc.id,
          skill_name: requested,
          tool_name: tool_name,
          disabled?: result.is_error
        }
      )

      Process.send(parent, {:tool_done, id, result}, [])
      {data_acc, Map.put(in_flight_acc, id, :activated)}
    end)
  end

  @doc """
  Handle a user-initiated slash-command skill activation.

  Sets `active_skill` on `data`, persists a JSONL `skill_activated` event,
  broadcasts `%Events.SkillActivated{}`, and emits telemetry. Returns updated
  data.
  """
  @spec activate_skill_via_slash(Tau.Session.Data.t(), Tau.Skill.t()) :: Tau.Session.Data.t()
  def activate_skill_via_slash(data, %Tau.Skill{name: name} = skill) do
    data =
      %{data | active_skill: skill}
      |> Tau.Session.Journal.persist("skill_activated", %{
        skill_name: name,
        tool_call_id: nil,
        allowed_tools: skill.allowed_tools
      })

    Tau.Session.broadcast(data.id, %Events.SkillActivated{
      session_id: data.id,
      skill_name: name,
      tool_call_id: nil
    })

    :telemetry.execute(
      [:tau, :session, :skill_activated],
      %{},
      %{session_id: data.id, skill_name: name, disabled?: false}
    )

    data
  end

  @doc """
  Look up `name` in `data.skills` and set `active_skill` if found.

  Returns `{updated_data, %ToolResult{}}`. On success, persists and broadcasts
  the activation event. On failure (unknown name, nil name, or
  `disable_model_invocation` set), returns `is_error: true` ToolResult and
  leaves `data` unchanged.
  """
  @spec activate_skill(Tau.Session.Data.t(), String.t() | nil, String.t()) ::
          {Tau.Session.Data.t(), ToolResult.t()}
  def activate_skill(data, nil, call_id) do
    {data,
     ToolResult.new(
       tool_call_id: call_id,
       tool_name: @activate_skill_tool_name,
       content: "Skill activation failed: missing 'name' parameter.",
       is_error: true
     )}
  end

  def activate_skill(data, name, call_id) when is_binary(name) do
    case List.keyfind(data.skills, name, 0) do
      {^name, %Tau.Skill{disable_model_invocation: true}} ->
        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content:
             "Skill '#{name}' has disable-model-invocation set; it cannot be activated by the model.",
           is_error: true
         )}

      {^name, %Tau.Skill{} = skill} ->
        data =
          %{data | active_skill: skill}
          |> Tau.Session.Journal.persist("skill_activated", %{
            skill_name: name,
            tool_call_id: call_id,
            allowed_tools: skill.allowed_tools
          })

        Tau.Session.broadcast(data.id, %Events.SkillActivated{
          session_id: data.id,
          skill_name: name,
          tool_call_id: call_id
        })

        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content: "Skill activated: #{name}",
           is_error: false
         )}

      nil ->
        {data,
         ToolResult.new(
           tool_call_id: call_id,
           tool_name: @activate_skill_tool_name,
           content: "Unknown skill: #{name}",
           is_error: true
         )}
    end
  end

  # --- Private helpers -------------------------------------------------------

  defp skill_name_from_args(args) when is_map(args) do
    Map.get(args, "name") || Map.get(args, :name)
  end

  defp skill_name_from_args(_), do: nil

  defp skill_activation_tool_spec(skills) do
    case model_invokable_skills(skills) do
      [] ->
        nil

      list ->
        names = Enum.map(list, fn {name, _s} -> name end)

        descriptions =
          list
          |> Enum.map(fn {name, %Tau.Skill{description: d}} ->
            case d do
              "" -> "  - #{name}"
              nil -> "  - #{name}"
              desc -> "  - #{name}: #{desc}"
            end
          end)
          |> Enum.join("\n")

        description =
          "Activate one of the available skills for the current turn. " <>
            "Activation scopes subsequent tool calls to the skill's allowed_tools " <>
            "whitelist (if set) and ends when you emit `end_turn`. " <>
            "Available skills:\n" <> descriptions

        %{
          name: @activate_skill_tool_name,
          description: description,
          parameters: %{
            "type" => "object",
            "properties" => %{
              "name" => %{
                "type" => "string",
                "enum" => names,
                "description" => "Name of the skill to activate."
              }
            },
            "required" => ["name"],
            "additionalProperties" => false
          }
        }
    end
  end

  defp model_invokable_skills(skills) do
    Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)
  end

  defp active_skill_tool_specs(nil), do: []

  defp active_skill_tool_specs(%Tau.Skill{allowed_tools: []}) do
    Tau.Tool.list()
    |> Enum.sort()
    |> Enum.flat_map(&tool_spec_for/1)
  end

  defp active_skill_tool_specs(%Tau.Skill{allowed_tools: names}) when is_list(names) do
    names
    |> Enum.uniq()
    |> Enum.flat_map(&tool_spec_for/1)
  end

  defp tool_spec_for(name) when is_binary(name) do
    case Tau.Tool.lookup(name) do
      {:ok, mod} ->
        [%{name: mod.name(), description: mod.description(), parameters: mod.parameters()}]

      :error ->
        []
    end
  end

  defp render_skill(name, %Tau.Skill{description: desc, body: body}) do
    header =
      if is_binary(desc) and desc != "" do
        "# Skill: #{name}\n\n_#{desc}_\n\n"
      else
        "# Skill: #{name}\n\n"
      end

    header <> body
  end
end

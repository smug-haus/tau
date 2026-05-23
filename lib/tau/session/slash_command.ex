defmodule Tau.Session.SlashCommand do
  @moduledoc """
  Slash-command classification and dispatch for `Tau.Session`.

  Parses incoming user messages for slash-command syntax, routes them to
  the appropriate handler (built-in, async extension, file-command, skill
  activation, or prompt template), and manages the supervised command-task
  lifecycle (ADR-0008).

  ## Precedence

  Outermost wins:
  `builtin > extension > file-command > skill > template > verbatim`

  D-076: prompt templates sit last before verbatim fall-through so skills
  and built-ins can shadow same-named templates.
  """

  alias Tau.Session.Events
  alias Tau.Commands.Catalog

  @doc """
  Classify a user message for slash-command routing.

  Returns one of:
  - `{:builtin, mod, args, msg}` — registered built-in command
  - `{:async, mod, args, msg}` — extension command with `execute/2`
  - `{:skill_activation, skill, rewritten_msg}` — skill name match
  - `{:model_command, args, msg}` — `/model` special case
  - `{:unknown_command, "/name"}` — unrecognized slash with no args (D-101)
  - `{:sync, msg}` — pass-through (no slash, or slash with args and no match)
  """
  @spec classify_slash_command(
          Tau.Message.User.t(),
          [{String.t(), Tau.Skill.t()}],
          [{String.t(), Tau.PromptTemplate.t()}],
          String.t()
        ) ::
          {:builtin, module(), String.t(), Tau.Message.User.t()}
          | {:async, module(), String.t(), Tau.Message.User.t()}
          | {:skill_activation, Tau.Skill.t(), Tau.Message.User.t()}
          | {:model_command, String.t(), Tau.Message.User.t()}
          | {:unknown_command, String.t()}
          | {:sync, Tau.Message.User.t()}
  def classify_slash_command(%Tau.Message.User{content: c} = msg, skills, templates, cwd)
      when is_binary(c) do
    case Tau.Commands.Parser.parse(c) do
      {:command, "/model", args} ->
        {:model_command, String.trim(args), msg}

      {:command, "/" <> bare_name = name, args} ->
        case Tau.Commands.Parser.lookup_builtin(name) do
          {:ok, mod} ->
            {:builtin, mod, args, msg}

          :error ->
            case Tau.Commands.Parser.lookup(name) do
              {:ok, mod} when is_atom(mod) ->
                if function_exported?(mod, :execute, 2) do
                  {:async, mod, args, msg}
                else
                  {:sync, msg}
                end

              {:ok, path} when is_binary(path) ->
                {:sync, invoke_file_command(path, args, msg)}

              :error ->
                case Tau.Commands.Parser.lookup_skill(bare_name, skills) do
                  {:ok, skill} ->
                    rewritten = %Tau.Message.User{msg | content: args}
                    {:skill_activation, skill, rewritten}

                  :error ->
                    # Not a skill — check prompt templates.
                    # D-076: template match rewrites the user message with the
                    # rendered body and returns {:sync, msg}.
                    case List.keyfind(templates, bare_name, 0) do
                      {_name, template} ->
                        context = build_template_context(cwd)
                        {:ok, rendered} = Tau.PromptTemplates.render(template, args, context)
                        rewritten = %Tau.Message.User{msg | content: rendered}
                        {:sync, rewritten}

                      nil ->
                        unknown_or_passthrough(bare_name, args, msg)
                    end
                end
            end
        end

      _ ->
        {:sync, msg}
    end
  end

  def classify_slash_command(msg, _skills, _templates, _cwd), do: {:sync, msg}

  @doc """
  Spawn a supervised task for an async slash command.

  Starts a child under `Tau.Tools.TaskSupervisor`, delivers the result to the
  FSM via `Process.send`, and schedules a timeout. Returns
  `{:keep_state, updated_data}`.
  """
  @spec spawn_command_task(module(), String.t(), Tau.Message.User.t(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def spawn_command_task(mod, args, msg, data) do
    parent = self()
    ctx = build_command_ctx(data)
    timeout_ms = Application.get_env(:tau, :slash_command_timeout_ms, 30_000)

    {:ok, pid} =
      Task.Supervisor.start_child(Tau.Tools.TaskSupervisor, fn ->
        result =
          try do
            case prepare_command_args(mod, args) do
              {:ok, prepared} -> mod.execute(prepared, ctx)
              {:error, _} = err -> err
            end
          rescue
            e -> {:crashed, Exception.message(e)}
          catch
            kind, value -> {:crashed, "uncaught #{kind}: #{inspect(value)}"}
          end

        Process.send(parent, {:command_done, result, msg}, [])
      end)

    Process.send_after(self(), {:command_timeout, pid, msg, timeout_ms}, timeout_ms)

    {:keep_state, %{data | command_task: pid}}
  end

  @doc """
  Apply the result of a slash-command task to the original user message.

  Transforms the message content based on the command outcome.
  """
  @spec apply_command_result(term(), Tau.Message.User.t()) :: Tau.Message.User.t()
  def apply_command_result(result, msg) do
    case result do
      {:inject, prefix} when is_binary(prefix) ->
        %Tau.Message.User{msg | content: prefix <> "\n\n" <> msg.content}

      {:replace, replacement} when is_binary(replacement) ->
        %Tau.Message.User{msg | content: replacement}

      {:run, replacement} when is_binary(replacement) ->
        %Tau.Message.User{msg | content: replacement}

      :ignore ->
        msg

      {:crashed, reason} ->
        %Tau.Message.User{
          msg
          | content: "(slash command crashed: #{reason})\n\n" <> msg.content
        }

      {:timeout, ms} ->
        %Tau.Message.User{
          msg
          | content: "(slash command timed out after #{ms}ms)\n\n" <> msg.content
        }

      {:error, reason} ->
        %Tau.Message.User{
          msg
          | content:
              "(slash command argument error: #{Tau.Command.Spec.format_error(reason)})\n\n" <>
                msg.content
        }

      _ ->
        msg
    end
  end

  @doc """
  Dispatch `mod.run(args, data)` for a built-in slash command and map the
  typed outcome to FSM actions (D-042).

  CRITICAL: `{:notice}`, `{:mutate}`, and `{:error}` branches MUST NOT call
  `process_user_message/2` — no provider turn is started. Only `:passthrough`
  falls through to the normal provider path.
  """
  @spec handle_builtin_command(module(), String.t(), Tau.Message.User.t(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_builtin_command(mod, args, original_msg, data) do
    outcome = mod.run(args, data)

    :telemetry.execute(
      [:tau, :session, :builtin_command],
      %{},
      %{session_id: data.id, command: mod.name(), outcome: outcome_tag(outcome)}
    )

    case outcome do
      {:notice, text} when is_binary(text) ->
        Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: text})
        {:keep_state, data}

      {:notice, lines} when is_list(lines) ->
        Enum.each(lines, fn line ->
          Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: line})
        end)

        {:keep_state, data}

      {:mutate, fun, notice} when is_function(fun, 1) ->
        data2 = fun.(data)

        if is_binary(notice) do
          Tau.Session.broadcast(data2.id, %Events.SystemNotice{
            session_id: data2.id,
            text: notice
          })
        end

        # D-108 (SPEC-TUI-COMPLETION §4 B1): re-broadcast the catalog after
        # any {:mutate} outcome so /reload's updated skills and templates are
        # reflected in the TUI menu immediately.
        catalog_entries2 = Catalog.list(data2)

        Tau.Session.broadcast(data2.id, %Events.CommandCatalog{
          session_id: data2.id,
          entries: catalog_entries2
        })

        {:keep_state, data2}

      {:error, text} ->
        Tau.Session.broadcast(
          data.id,
          %Events.SystemNotice{session_id: data.id, text: "Error: " <> text}
        )

        {:keep_state, data}

      {:async_compact, notice} ->
        # The only outcome that changes FSM state (to :compacting).
        Tau.Session.broadcast(data.id, %Events.SystemNotice{session_id: data.id, text: notice})
        # D-163: broadcast CompactionStarted before entering :compacting so the
        # TUI status bar transitions to :running before the task is spawned.
        Tau.Session.broadcast(data.id, %Events.CompactionStarted{session_id: data.id})

        ctx = %{provider: data.provider, model: data.model}
        timeout_ms = Application.get_env(:tau, :compaction_timeout_ms, 60_000)

        task =
          Task.Supervisor.async_nolink(Tau.Tools.TaskSupervisor, fn ->
            Tau.Compactor.impl().compact(data.messages, ctx)
          end)

        :telemetry.execute([:tau, :compaction, :start], %{system_time: System.system_time()}, %{
          session_id: data.id,
          message_count: length(data.messages),
          async: true
        })

        Process.send_after(self(), {:compaction_timeout, task.pid, timeout_ms}, timeout_ms)

        {:next_state, :compacting,
         %{data | compaction_task: task.pid, compaction_monitor: task.ref}}

      :passthrough ->
        # Fall through to the normal provider turn with the original message.
        Tau.Session.process_user_message(original_msg, data)
    end
  end

  @doc """
  Return the outcome tag atom for telemetry.
  """
  @spec outcome_tag(term()) :: atom()
  def outcome_tag({:notice, _}), do: :notice
  def outcome_tag({:mutate, _, _}), do: :mutate
  def outcome_tag({:error, _}), do: :error
  def outcome_tag({:async_compact, _}), do: :async_compact
  def outcome_tag(:passthrough), do: :passthrough

  @doc """
  Handle a `{:command_done, result, original_msg}` info message in any state.

  Applies the command result and routes through `process_user_message/2`.
  """
  @spec handle_command_done(term(), Tau.Message.User.t(), Tau.Session.Data.t()) ::
          Tau.Session.Data.fsm_result()
  def handle_command_done(result, original_msg, data) do
    msg = apply_command_result(result, original_msg)
    Tau.Session.process_user_message(msg, %{data | command_task: nil})
  end

  @doc """
  Handle a live command timeout. Kills the task and routes through
  `process_user_message/2` with a `{:timeout, ms}` result.
  """
  @spec handle_command_timeout_live(
          pid(),
          Tau.Message.User.t(),
          non_neg_integer(),
          Tau.Session.Data.t()
        ) ::
          Tau.Session.Data.fsm_result()
  def handle_command_timeout_live(pid, original_msg, ms, data) do
    if Process.alive?(pid), do: Process.exit(pid, :brutal_kill)
    msg = apply_command_result({:timeout, ms}, original_msg)
    Tau.Session.process_user_message(msg, %{data | command_task: nil})
  end

  @doc """
  Handle a stale command timeout (task already completed). Drop.
  """
  @spec handle_command_timeout_stale(Tau.Session.Data.t()) :: Tau.Session.Data.fsm_result()
  def handle_command_timeout_stale(data) do
    {:keep_state, data}
  end

  # --- Private helpers -------------------------------------------------------

  # D-101 / SPEC-TUI-COMPLETION: only intercept whitespace-free tokens
  # (args == "") with no catalog match. When args is non-empty the user provided
  # arguments, pass through to the model (AC-7 guard).
  defp unknown_or_passthrough(bare_name, "", _msg), do: {:unknown_command, "/" <> bare_name}
  defp unknown_or_passthrough(_bare_name, _args, msg), do: {:sync, msg}

  defp build_template_context(cwd) do
    user =
      case System.user_home() do
        nil -> ""
        home -> Path.basename(home)
      end

    %{
      "cwd" => cwd,
      "date" => DateTime.utc_now() |> DateTime.to_date() |> Date.to_iso8601(),
      "user" => user,
      "cursor" => ""
    }
  end

  defp prepare_command_args(mod, args) when is_binary(args) do
    if function_exported?(mod, :parameters, 0) do
      Tau.Command.Spec.parse(mod.parameters(), args)
    else
      {:ok, args}
    end
  end

  defp prepare_command_args(_mod, args), do: {:ok, args}

  defp build_command_ctx(data) do
    sid = data.id

    Tau.Command.Context.new(
      session_id: sid,
      cwd: data.cwd,
      permissions_mode: Map.get(data.metadata, :permissions_mode, :default),
      emit: fn payload ->
        Phoenix.PubSub.broadcast(Tau.PubSub, "session:#{sid}", payload)
      end,
      metadata: data.metadata
    )
  end

  defp invoke_file_command(path, args, msg) do
    case File.read(path) do
      {:ok, body} -> %Tau.Message.User{msg | content: body <> "\n\n" <> args}
      _ -> msg
    end
  end
end

defmodule Tau.Tool.Validator do
  @moduledoc """
  Validate tool arguments against the tool's `parameters/0` JSON Schema
  (Draft 7) before dispatch.

  The session FSM was previously calling `mod.execute(args, ctx)`
  unchecked; tools had to defensively validate themselves, and a model
  passing the wrong shape would crash the tool process or produce
  confusing downstream errors. Centralising validation here means:

    * tools trust their `params` argument matches `parameters/0`,
    * model-level errors come back as `is_error: true` `ToolResult`s
      with descriptive messages, so the model can self-correct on the
      next turn,
    * `[:tau, :tool, :validate, :error]` telemetry surfaces every
      rejection.

  Resolved schemas are cached in `:persistent_term` keyed by module —
  `parameters/0` is effectively compile-time constant. If a tool's
  schema can't be resolved (uses features `ex_json_schema` doesn't
  support, or is malformed), validation is bypassed rather than blocking
  the tool entirely; a one-shot
  `[:tau, :tool, :validate, :schema_error]` telemetry event fires for
  visibility.
  """

  @type validation_error :: {String.t(), String.t()}

  @doc """
  Validate `args` against `mod.parameters/0`. Returns `:ok` if the
  schema is empty/missing/unresolvable.
  """
  @spec validate(module(), term()) :: :ok | {:error, [validation_error()]}
  def validate(mod, args) when is_atom(mod) do
    args = args || %{}
    schema = safe_parameters(mod)

    if is_map(schema) and map_size(schema) > 0 do
      case resolve_cached(mod, schema) do
        {:ok, resolved} -> ExJsonSchema.Validator.validate(resolved, args)
        {:error, _} -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Format a validator error list into a single human-readable line for
  the `ToolResult.content`.
  """
  @spec format_errors([validation_error()]) :: String.t()
  def format_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn
      {msg, path} when is_binary(path) and path != "" -> "#{path}: #{msg}"
      {msg, _path} -> msg
    end)
    |> Enum.join("; ")
  end

  defp safe_parameters(mod) do
    if function_exported?(mod, :parameters, 0), do: mod.parameters(), else: %{}
  end

  defp resolve_cached(mod, schema) do
    key = {__MODULE__, mod}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        result =
          try do
            {:ok, ExJsonSchema.Schema.resolve(schema)}
          rescue
            e ->
              :telemetry.execute(
                [:tau, :tool, :validate, :schema_error],
                %{system_time: System.system_time()},
                %{tool_module: mod, error: Exception.message(e)}
              )

              {:error, Exception.message(e)}
          end

        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end
end

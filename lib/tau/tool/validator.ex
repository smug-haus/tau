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
  `parameters/0` is effectively compile-time constant. **Failures are
  not cached** (ADR-0003): a tool whose schema can't be resolved
  fails closed (every call is rejected with a clear error) until the
  schema becomes resolvable or `invalidate/1` is called. This is the
  security boundary — a hostile MCP server can't ship a malformed
  schema once and have it permanently bypass validation. Each
  failure does emit `[:tau, :tool, :validate, :schema_error]`
  telemetry for visibility.
  """

  @type validation_error :: {String.t(), String.t()}

  @doc """
  Validate `args` against `mod.parameters/0`.

  Returns:

    * `:ok` if the schema is empty / the tool has no `parameters/0`
      callback / args satisfies the resolved schema.
    * `{:error, [{msg, path}]}` if args fails validation, OR if the
      schema can't be resolved (tool fails closed, ADR-0003).
  """
  @spec validate(module(), term()) :: :ok | {:error, [validation_error()]}
  def validate(mod, args) when is_atom(mod) do
    args = args || %{}
    schema = safe_parameters(mod)

    if is_map(schema) and map_size(schema) > 0 do
      case resolve_cached(mod, schema) do
        {:ok, resolved} ->
          ExJsonSchema.Validator.validate(resolved, args)

        {:error, reason} ->
          {:error, [{"schema unresolvable: #{reason}", "#"}]}
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
      msg when is_binary(msg) -> msg
    end)
    |> Enum.join("; ")
  end

  @doc """
  Evict `mod`'s cached resolved schema. Useful after a tool
  re-registers in the same BEAM with corrected `parameters/0` (for
  example, a hot-reloaded MCP tool whose server fixed its manifest).
  """
  @spec invalidate(module()) :: :ok
  def invalidate(mod) when is_atom(mod) do
    _ = :persistent_term.erase({__MODULE__, mod})
    :ok
  end

  defp safe_parameters(mod) do
    if function_exported?(mod, :parameters, 0), do: mod.parameters(), else: %{}
  end

  defp resolve_cached(mod, schema) do
    key = {__MODULE__, mod}

    case :persistent_term.get(key, :undefined) do
      :undefined ->
        case try_resolve(mod, schema) do
          {:ok, resolved} = ok ->
            # Only successful resolutions are cached. Failures
            # re-attempt next call (cheap; failing tools stop being
            # invoked once the model sees the error).
            :persistent_term.put(key, ok)
            {:ok, resolved}

          {:error, _} = err ->
            err
        end

      cached ->
        cached
    end
  end

  defp try_resolve(mod, schema) do
    {:ok, ExJsonSchema.Schema.resolve(schema)}
  rescue
    e ->
      msg = Exception.message(e)

      :telemetry.execute(
        [:tau, :tool, :validate, :schema_error],
        %{system_time: System.system_time()},
        %{tool_module: mod, error: msg}
      )

      {:error, msg}
  end
end

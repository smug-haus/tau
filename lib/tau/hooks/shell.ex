defmodule Tau.Hooks.Shell do
  @moduledoc """
  Wraps a shell command as a `Tau.Hook`-compliant module, generated at
  settings-load time from declarative entries in `settings.hooks`:

      "hooks": {
        "preToolUse": [
          { "matcher": "Bash",
            "command": "~/.tau/hooks/audit.sh" }
        ]
      }

  Spec:

    * The hook's stdin receives the JSON payload Claude Code uses (session_id,
      transcript_path, cwd, permission_mode, hook_event_name, tool_name,
      tool_input).
    * The hook's stdout is parsed as JSON; recognised keys are
      `continue` (boolean) and `updatedInput` (replacement payload).
    * Exit codes:
        0 → `:cont` (or `{:cont, updatedInput}`)
        2 → `:halt` with stderr text as reason
        other → log + `:cont`

  Each declarative hook entry compiles into one anonymous module via
  `Module.create/3`. Lookups stay in the Hooks.Registry like any other.
  """

  require Logger

  @doc """
  Build a one-shot hook module for the given config map.

  Returns the module name; the caller is expected to `Registry.register/3`
  it under the relevant event(s).
  """
  @spec build(map(), [Tau.Hook.event()]) :: module()
  def build(%{"command" => cmd} = config, events) do
    matcher = config["matcher"]
    timeout_ms = (config["timeout"] || 60) * 1000
    name = generate_name()

    body =
      quote do
        @behaviour Tau.Hook
        @impl true
        def events, do: unquote(events)

        @impl true
        def handle(event, payload) do
          Tau.Hooks.Shell.run_command(
            unquote(cmd),
            unquote(matcher),
            unquote(timeout_ms),
            event,
            payload
          )
        end
      end

    Module.create(name, body, Macro.Env.location(__ENV__))
    name
  end

  @doc false
  def run_command(cmd, matcher, timeout_ms, event, payload) do
    if matcher && not matches?(matcher, payload),
      do: :cont,
      else: do_run(cmd, timeout_ms, event, payload)
  end

  defp do_run(cmd, timeout_ms, event, payload) do
    json =
      payload
      |> Map.put("hook_event_name", to_string(event))
      |> Jason.encode!()

    port =
      Port.open({:spawn, cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        :use_stdio
      ])

    Port.command(port, json)

    case collect(port, "", timeout_ms) do
      {:ok, output, 0} ->
        parse_response(output, payload)

      {:ok, output, 2} ->
        {:halt, output}

      {:ok, _output, status} ->
        Logger.warning("Shell hook exit #{status}; treating as :cont")
        :cont

      {:error, :timeout} ->
        {:halt, "shell hook timed out"}
    end
  end

  defp parse_response(output, original) do
    output = String.trim(output)

    if output == "" do
      :cont
    else
      case Jason.decode(output) do
        {:ok, %{"updatedInput" => updated}} -> {:cont, updated}
        {:ok, %{"continue" => false, "reason" => r}} -> {:halt, r}
        {:ok, %{"continue" => true}} -> :cont
        _ -> :cont
      end
    end
    |> tag_with(original)
  end

  defp tag_with(:cont, _orig), do: :cont
  defp tag_with({:cont, p}, _orig), do: {:cont, p}
  defp tag_with({:halt, r}, _orig), do: {:halt, r}

  defp matches?(_matcher, _payload), do: true

  defp collect(port, acc, timeout_ms) do
    receive do
      {^port, {:data, d}} -> collect(port, acc <> d, timeout_ms)
      {^port, {:exit_status, n}} -> {:ok, acc, n}
    after
      timeout_ms ->
        try do
          Port.close(port)
        catch
          _, _ -> :ok
        end

        {:error, :timeout}
    end
  end

  defp generate_name do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    Module.concat([Tau.Hooks.Shell, "Generated_#{suffix}"])
  end
end

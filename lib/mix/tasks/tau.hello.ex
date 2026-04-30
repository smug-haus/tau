defmodule Mix.Tasks.Tau.Hello do
  @shortdoc "Round-trip a single user message against a provider."

  @moduledoc """
  One-shot smoke test for a configured provider.

      mix tau.hello                       # default provider, default model, "Hello"
      mix tau.hello --provider anthropic --model claude-haiku-4-5 --prompt "Say hi"

  Streams the response to stdout. Exits 0 on `Done`, 1 on `Error`.
  """

  use Mix.Task

  alias Tau.Message.User
  alias Tau.Provider.Event

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(argv,
        strict: [provider: :string, model: :string, prompt: :string],
        aliases: [p: :prompt, m: :model]
      )

    provider = resolve_provider(opts[:provider])
    prompt = opts[:prompt] || "Hello, in one short sentence: who are you?"
    model = opts[:model] || provider.default_model()

    IO.puts("→ #{inspect(provider)} (model: #{model})")
    IO.puts("> #{prompt}\n")

    msgs = [User.new(prompt)]

    case provider.stream(msgs, %{model: model}, %{}) do
      {:ok, stream} -> stream_to_stdout(stream)
      {:error, reason} -> die("provider error: #{inspect(reason)}")
    end
  end

  defp stream_to_stdout(stream) do
    {status, _events} =
      Enum.reduce_while(stream, {:ok, 0}, fn
        %Event.TextDelta{text: t}, {st, n} ->
          IO.write(t)
          {:cont, {st, n + 1}}

        %Event.ThinkingDelta{}, acc ->
          {:cont, acc}

        %Event.Done{stop_reason: r, usage: u}, _ ->
          IO.puts("\n\n— stop_reason: #{r}, usage: #{inspect(u)}")
          {:halt, {:ok, 0}}

        %Event.Error{reason: r, retryable?: rt}, _ ->
          {:halt, {:error, {r, rt}}}

        _, acc ->
          {:cont, acc}
      end)

    case status do
      :ok -> :ok
      :error -> die("stream error")
      {:error, _} = e -> die(inspect(e))
    end
  end

  defp resolve_provider(nil), do: Tau.Provider.default()
  defp resolve_provider("anthropic"), do: Tau.Providers.Anthropic
  defp resolve_provider("replay"), do: Tau.Providers.Replay
  defp resolve_provider(other), do: Module.concat(["Tau", "Providers", String.capitalize(other)])

  defp die(msg) do
    Mix.shell().error(msg)
    System.halt(1)
  end
end

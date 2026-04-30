defmodule Tau.Commands.Parser do
  @moduledoc """
  Pure parser for slash-command syntax in user input.

      "/deploy production"   → {:command, "/deploy", "production"}
      "/foo"                 → {:command, "/foo", ""}
      "regular message"      → :passthrough
      ""                     → :empty

  Multi-word command names are not supported; the first whitespace splits
  command from args.
  """

  @doc "Parse one user input line."
  @spec parse(String.t()) :: {:command, String.t(), String.t()} | :passthrough | :empty
  def parse(""), do: :empty

  def parse("/" <> _ = line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [name, args] -> {:command, name, args}
      [name] -> {:command, name, ""}
    end
  end

  def parse(_other), do: :passthrough

  @doc "Resolve a command name to a module via the Commands.Registry."
  @spec lookup(String.t()) :: {:ok, module() | binary()} | :error
  def lookup(name) do
    case Registry.lookup(Tau.Commands.Registry, name) do
      [{_pid, mod_or_path}] -> {:ok, mod_or_path}
      _ -> :error
    end
  end
end

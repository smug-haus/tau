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

  alias Tau.Commands.Builtin

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

  @doc """
  Resolve a slash-command name against the built-in registry.

  Returns `{:ok, module}` when `name` matches an entry in
  `Tau.Commands.Builtin.table/0`, `:error` otherwise.

  Built-in resolution is intended to be called BEFORE `lookup/1` so that
  built-in commands shadow same-named extensions.
  """
  @spec lookup_builtin(String.t()) :: {:ok, module()} | :error
  def lookup_builtin(name), do: Map.fetch(Builtin.table(), name)

  @doc "Resolve a command name to a module via the Commands.Registry."
  @spec lookup(String.t()) :: {:ok, module() | binary()} | :error
  def lookup(name) do
    case Registry.lookup(Tau.Commands.Registry, name) do
      [{_pid, mod_or_path}] -> {:ok, mod_or_path}
      _ -> :error
    end
  end

  @doc """
  Look up a slash-stripped command name against a skills list.

  `name` is the raw slash-command token with the leading slash removed
  (e.g. `"deploy"` from `"/deploy"`). `skills` is the session's
  `data.skills` keyword list of `{name, %Tau.Skill{}}` pairs.

  Returns `{:ok, %Tau.Skill{}}` when a matching skill is found,
  `:error` otherwise.
  """
  @spec lookup_skill(String.t(), [{String.t(), Tau.Skill.t()}]) ::
          {:ok, Tau.Skill.t()} | :error
  def lookup_skill(name, skills) when is_binary(name) and is_list(skills) do
    case List.keyfind(skills, name, 0) do
      {^name, %Tau.Skill{} = skill} -> {:ok, skill}
      _ -> :error
    end
  end
end

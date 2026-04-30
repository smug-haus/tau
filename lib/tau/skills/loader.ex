defmodule Tau.Skills.Loader do
  @moduledoc """
  Loads `SKILL.md` files from the standard locations.

      ~/.tau/skills/<name>/SKILL.md
      <cwd>/.tau/skills/<name>/SKILL.md
      priv/skills/<name>/SKILL.md   (bundled)

  Skills are registered in `Tau.Skills.Registry` keyed by name. The
  registry value is the parsed `%Tau.Skill{}` struct.
  """

  alias Tau.Skill
  alias Tau.Skills.Frontmatter

  @doc "Discover and register all skills in the standard locations."
  @spec load_all(Path.t()) :: :ok
  def load_all(cwd) do
    candidates =
      [
        Path.join(System.user_home!() || ".", ".tau/skills"),
        Path.join(cwd, ".tau/skills"),
        Path.join(:code.priv_dir(:tau) |> to_string(), "skills")
      ]
      |> Enum.filter(&File.dir?/1)

    Enum.each(candidates, fn dir -> discover(dir) end)
  end

  defp discover(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            sk_path = Path.join([dir, entry, "SKILL.md"]),
            File.regular?(sk_path) do
          load_one(sk_path)
        end

      _ ->
        :ok
    end
  end

  @doc "Load a single SKILL.md path. Registers in Tau.Skills.Registry."
  @spec load_one(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load_one(path) do
    with {:ok, body} <- File.read(path) do
      {fm, md} = Frontmatter.parse(body)
      name = Map.get(fm, "name") || Path.basename(Path.dirname(path))

      skill = %Skill{
        name: name,
        description: Map.get(fm, "description", ""),
        allowed_tools: Map.get(fm, "allowed-tools", "") |> parse_tools_field(),
        disable_model_invocation: !!Map.get(fm, "disable-model-invocation", false),
        paths: Map.get(fm, "paths", []),
        body: md,
        path: path
      }

      Registry.register(Tau.Skills.Registry, name, skill)
      {:ok, skill}
    end
  end

  defp parse_tools_field(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp parse_tools_field(list) when is_list(list), do: list
  defp parse_tools_field(_), do: []

  @doc """
  List every skill currently registered in `Tau.Skills.Registry`.

  Returns a sorted list of `{name, %Tau.Skill{}}` tuples (sorted by name
  for determinism).
  """
  @spec list() :: [{String.t(), Skill.t()}]
  def list do
    Tau.Skills.Registry
    |> Registry.select([{{:"$1", :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.sort_by(fn {name, _} -> name end)
  end
end

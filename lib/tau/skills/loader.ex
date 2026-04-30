defmodule Tau.Skills.Loader do
  @moduledoc """
  Pure loader for `SKILL.md` files (ADR-0005).

  Three on-disk locations are scanned per session:

      ~/.tau/skills/<name>/SKILL.md
      <cwd>/.tau/skills/<name>/SKILL.md
      priv/skills/<name>/SKILL.md   (bundled)

  `discover/1` is **side-effect-free**: it walks the directories,
  parses each `SKILL.md`, and returns `[{name, %Tau.Skill{}}]`. No
  Registry mutation. The session stores the result on `data.skills`
  directly.

  Extension-provided skills (declared via `Tau.Extension`'s
  `skill/2` macro) are registered into `Tau.Skills.Registry` once
  by the long-lived `Tau.Extensions.Loader` GenServer; sessions
  read those via `list_extension_skills/0` and merge with their
  `discover/1` results.
  """

  alias Tau.Skill
  alias Tau.Skills.Frontmatter

  @doc """
  Discover every `SKILL.md` under the standard locations rooted at
  `cwd`. Pure: no filesystem state changes, no Registry mutation.

  Skills with the same name are deduplicated; the first occurrence
  in `~/.tau/skills`, then `<cwd>/.tau/skills`, then `priv/skills`
  wins (most-specific-loses-to-most-general isn't useful here; we
  preserve precedence in scan order so user-global skills mask
  bundled ones with the same name, which is what users expect).
  """
  @spec discover(Path.t()) :: [{String.t(), Skill.t()}]
  def discover(cwd) do
    home = System.user_home!() || "."
    priv = :code.priv_dir(:tau) |> to_string()

    [
      Path.join(home, ".tau/skills"),
      Path.join(cwd, ".tau/skills"),
      Path.join(priv, "skills")
    ]
    |> Enum.flat_map(&scan_dir/1)
    |> Enum.uniq_by(fn {name, _} -> name end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc """
  Parse a single `SKILL.md` path into a `%Tau.Skill{}` struct.

  Pure: does not register in any Registry. Use this from a
  long-lived owner (e.g. `Tau.Extensions.Loader`) that wants to
  register the resulting struct.
  """
  @spec parse(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def parse(path) do
    with {:ok, body} <- File.read(path) do
      {fm, md} = Frontmatter.parse(body)
      name = Map.get(fm, "name") || Path.basename(Path.dirname(path))

      {:ok,
       %Skill{
         name: name,
         description: Map.get(fm, "description", ""),
         allowed_tools: Map.get(fm, "allowed-tools", "") |> parse_tools_field(),
         disable_model_invocation: !!Map.get(fm, "disable-model-invocation", false),
         paths: Map.get(fm, "paths", []),
         body: md,
         path: path
       }}
    end
  end

  @doc """
  Return every skill currently in `Tau.Skills.Registry` —
  exclusively extension-provided skills (per ADR-0005, sessions no
  longer mutate this registry). Sorted by name for determinism.
  """
  @spec list_extension_skills() :: [{String.t(), Skill.t()}]
  def list_extension_skills do
    Tau.Skills.Registry
    |> Registry.select([{{:"$1", :_, :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.flat_map(fn
      {name, %Skill{} = skill} -> [{name, skill}]
      _ -> []
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp scan_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            sk_path = Path.join([dir, entry, "SKILL.md"]),
            File.regular?(sk_path),
            {:ok, skill} <- [parse(sk_path)] do
          {skill.name, skill}
        end

      _ ->
        []
    end
  end

  defp parse_tools_field(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp parse_tools_field(list) when is_list(list), do: list
  defp parse_tools_field(_), do: []
end

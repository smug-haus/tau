defmodule Tau.PromptTemplates do
  @moduledoc """
  Pure loader and renderer for user-defined prompt templates.

  ## Discovery

  Two on-disk locations are scanned per session:

      <cwd>/.tau/prompts/*.md    (project-local — takes precedence)
      ~/.tau/prompts/*.md        (user-global)

  **Scan order is deliberately the inverse of `Tau.Skills.Loader`.**
  `Skills.Loader` scans home-global first (home wins), because bundled
  skills should be overridable by user-global copies.  Prompt templates
  follow Pi and Claude Code's convention: project wins over home-global,
  so a project-local template always shadows a same-named home-global one.
  `Enum.uniq_by/2` keeps the first occurrence, so `<cwd>` must be scanned
  first.  **Do not "align" this with `Skills.Loader` — the inversion is
  intentional.**

  ## Substitution (D-076)

  `render/3` performs a single, non-recursive substitution pass:

  - Positional args (tokenised via `OptionParser.split/1`) are bound to
    the declared `variables` list in order.
  - Reserved context names (`cwd`, `date`, `user`, `cursor`, `args`) are
    injected by the session at render time; `args` is the full raw tail
    string (pre-tokenisation), so `/x "a b"` vs `/x a b` differ.
  - Surplus positional args are silently ignored (`:info` telemetry).
  - Unknown or unbound `{{var}}` tokens render as the literal `{{var}}`
    and emit `[:tau, :prompt_template, :unknown_variable]` telemetry —
    never a crash (D-076).
  - Substituted text is NOT re-scanned.  A template value that contains
    `{{something}}` is treated as literal output, not a nested placeholder.
    This closes a prompt-injection vector by construction.

  ## Security note

  D-076 constrains the *substituter*, not the *body*.  An untrusted
  template body (e.g. cloned from an untrusted repo) is a prompt-injection
  surface equivalent to an untrusted skill body.  Template authors are
  trusted the same way skill authors are trusted.

  ## Precedence in slash-command dispatch

  `builtin > extension > file-command > skill > **template**`

  A template named identically to a built-in or skill is shadowed.  This
  preserves the security property that unprivileged text files cannot mask
  permission-scoped personas.  The divergence from Pi's order (`commands >
  templates > skills`) is intentional; see issue #183 for rationale.
  """

  require Logger

  alias Tau.PromptTemplate
  alias Tau.Skills.Frontmatter

  @var_regex ~r/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

  @doc """
  Discover every `*.md` under `<cwd>/.tau/prompts/` and `~/.tau/prompts/`.

  Returns `[{name, %Tau.PromptTemplate{}}]`.  Pure: no filesystem state
  changes, no Registry mutation.  Project-local copies take precedence over
  home-global copies (first occurrence wins after cwd is scanned first).
  """
  @spec discover(Path.t()) :: [{String.t(), PromptTemplate.t()}]
  def discover(cwd) do
    home = System.user_home!() || "."
    discover(cwd, home)
  end

  @doc """
  Discover templates with an explicit home directory (useful for testing).

  Equivalent to `discover/1` but allows the home directory to be overridden
  instead of reading `System.user_home!/0`.  This is the real implementation;
  `discover/1` is a thin wrapper that injects the real home.
  """
  @spec discover(Path.t(), Path.t()) :: [{String.t(), PromptTemplate.t()}]
  def discover(cwd, home) do
    cwd_dir = Path.join(cwd, ".tau/prompts")
    home_dir = Path.join(home, ".tau/prompts")

    [cwd_dir, home_dir]
    |> Enum.flat_map(&scan_dir/1)
    |> Enum.uniq_by(fn {name, _} -> name end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  @doc """
  Render a prompt template by substituting `{{var}}` placeholders.

  - `template` — the `%Tau.PromptTemplate{}` to render.
  - `raw_tail` — the raw string that followed the command name in the
    user's input (e.g. `"Tau.Session start_session"` from
    `/refactor-otp Tau.Session start_session`).  Used verbatim as
    `{{args}}` and tokenised via `OptionParser.split/1` for positional
    binding.
  - `context` — a map of reserved context values injected by the session:
    `cwd`, `date`, `user`, `cursor`.

  Always returns `{:ok, rendered_body}`.  Unknown variables render as
  their literal `{{name}}` and emit telemetry; the function never raises.
  """
  @spec render(PromptTemplate.t(), String.t(), map()) :: {:ok, String.t()}
  def render(%PromptTemplate{} = template, raw_tail, context) when is_map(context) do
    positional_args =
      try do
        OptionParser.split(raw_tail)
      rescue
        _ -> String.split(raw_tail, ~r/\s+/, trim: true)
      end

    surplus_count = max(0, length(positional_args) - length(template.variables))

    if surplus_count > 0 do
      :telemetry.execute(
        [:tau, :prompt_template, :surplus_args],
        %{count: surplus_count},
        %{template: template.name}
      )
    end

    bound_vars =
      template.variables
      |> Enum.with_index()
      |> Enum.into(%{}, fn {var_name, i} ->
        {var_name, Enum.at(positional_args, i)}
      end)

    substitution_map =
      bound_vars
      |> Map.merge(%{"args" => raw_tail})
      |> Map.merge(Map.new(context, fn {k, v} -> {to_string(k), v} end))

    rendered = do_render(template.body, substitution_map, template.name)

    {:ok, rendered}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp scan_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn file ->
          path = Path.join(dir, file)

          case parse(path) do
            {:ok, template} -> [{template.name, template}]
            {:error, _} -> []
          end
        end)

      _ ->
        []
    end
  end

  defp parse(path) do
    with {:ok, raw} <- File.read(path) do
      {fm, body} = Frontmatter.parse(raw)
      name = Path.basename(path, ".md")
      description = Map.get(fm, "description", "")

      variables =
        case Map.get(fm, "variables") do
          list when is_list(list) ->
            list

          _ ->
            extract_variables_from_body(body)
        end

      {:ok,
       %PromptTemplate{
         name: name,
         body: body,
         path: path,
         description: description,
         variables: variables
       }}
    end
  end

  defp extract_variables_from_body(body) do
    reserved = PromptTemplate.reserved()

    @var_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.reject(&(&1 in reserved))
    |> Enum.uniq()
  end

  defp do_render(body, substitution_map, template_name) do
    Regex.replace(@var_regex, body, fn _full, name ->
      case Map.get(substitution_map, name) do
        nil ->
          :telemetry.execute(
            [:tau, :prompt_template, :unknown_variable],
            %{},
            %{template: template_name, variable: name}
          )

          "{{#{name}}}"

        value ->
          value
      end
    end)
  end
end

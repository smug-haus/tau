defmodule Tau.Factory.BriefAssembler do
  @moduledoc """
  Pure, network-free assembler that projects a brief/issue map into a
  `task.prompt` string delivered to the implementer worker.

  ## Contract (D-372 / D-373 / D-382, SPEC-FACTORY-CORE §4 B10 amendment)

  ### D-372 — Assembly completeness

  `assemble/2` composes a `task.prompt` from all present input fields, each
  under a distinct labelled section:

    - **Issue** — issue number, title, and body.
    - **Declared scope** — the `ConflictCheck.scope()` map (files, codepoints,
      SPEC references, resource locks, deps).
    - **Gating-test paths** — the frozen gating-test file paths for this PR.
    - **SPEC / AC / D-NNN references** — acceptance criteria and invariant tokens.
    - **Architecture pointers** — `docs/arch/04-software-architecture/` links
      (the pointer section is MANDATORY — present even when no `arch_pointers`
      key is supplied; carries at minimum the root pointer to discharge
      `feedback_brief_implementers_with_arch`).
    - **Role instructions** — when `:role` opt is supplied, a role-specific
      actionable instruction section is appended (D-382).

  ### D-373 — Injected pure seam that degrades, never crashes

  The `:assemble_fun` option (signature: `(input :: map()) -> String.t()`)
  mirrors the `:elaborate_fun` seam on `IssueSelector`. When supplied the
  injected function's output is returned as-is; the default heuristic
  assembler is bypassed. The default is pure, deterministic, and network-free.

  Absent optional keys (`gating_test_paths`, `spec_refs`, `arch_pointers`)
  degrade to `(none declared)` placeholder sections — never a crash, never a
  silently-omitted section.

  Output is always a non-empty `String.t()` for any non-empty issue map
  carrying `"number"` and `"title"`.

  ### D-382 — Role-aware brief

  When `:role` opt is supplied (`:test_author` | `:implementer`), a role-specific
  instruction section is appended to the assembled brief:

    - `:test_author` → instructs the agent to WRITE the gating test for the
      issue, names the expected `test/...` path (from `gating_test_paths`), and
      states the agent is operating in a fresh isolated worktree it must edit
      and commit.
    - `:implementer` → instructs the agent to IMPLEMENT the issue to satisfy
      the gating test.

  The two roles produce different briefs for the same input.
  The `:assemble_fun` bypass is not affected by `:role` — injected functions
  receive the full input map and are responsible for role handling if needed.

  ## API

      Tau.Factory.BriefAssembler.assemble(input, [])
      Tau.Factory.BriefAssembler.assemble(input, role: :test_author)
      Tau.Factory.BriefAssembler.assemble(input, role: :implementer)
      Tau.Factory.BriefAssembler.assemble(input, assemble_fun: fn input -> "custom" end)

  `input` keys (atoms):
    - `:issue`             — required; `%{"number" => integer, "title" => string, "body" => string}`
    - `:declared_scope`    — required; a `ConflictCheck.scope()` map
    - `:gating_test_paths` — optional; `[String.t()]`
    - `:spec_refs`         — optional; `[String.t()]`
    - `:arch_pointers`     — optional; `[String.t()]`
  """

  @default_arch_root "docs/arch/04-software-architecture"

  @doc """
  Assemble a `task.prompt` string from the given `input` map.

  Returns a non-empty `String.t()`. Never raises on partial input.
  When `:assemble_fun` is supplied in `opts`, delegates to it entirely.

  ## Options

    - `:assemble_fun` — `(input :: map() -> String.t())`; when supplied,
      overrides the default heuristic assembler entirely.
    - `:role` — `:test_author` | `:implementer`; when supplied, appends a
      role-specific actionable instruction section (D-382). Ignored when
      `:assemble_fun` is provided.
  """
  @spec assemble(map(), keyword()) :: String.t()
  def assemble(input, opts) do
    assemble_fun = Keyword.get(opts, :assemble_fun)

    if assemble_fun do
      assemble_fun.(input)
    else
      role = Keyword.get(opts, :role)
      default_assemble(input, role)
    end
  end

  # ---------------------------------------------------------------------------
  # Default heuristic assembler (D-372 template, pure and deterministic)
  # ---------------------------------------------------------------------------

  defp default_assemble(input, role) do
    issue = Map.fetch!(input, :issue)
    declared_scope = Map.fetch!(input, :declared_scope)
    gating_test_paths = Map.get(input, :gating_test_paths)
    spec_refs = Map.get(input, :spec_refs)
    arch_pointers = Map.get(input, :arch_pointers)

    # D-382: when a :role is given, use compact (no-placeholder) rendering for
    # empty sections — role-specific briefs must not contain "(none declared)"
    # noise. The D-373 contract ("absent optional keys degrade to (none declared)")
    # applies only to the role-agnostic default (no :role opt).
    compact? = not is_nil(role)

    base_sections = [
      issue_section(issue),
      scope_section(declared_scope, compact?),
      gating_tests_section(gating_test_paths, compact?),
      spec_refs_section(spec_refs, compact?),
      arch_pointers_section(arch_pointers)
    ]

    role_sections =
      case role do
        nil -> []
        r -> [role_section(r, gating_test_paths)]
      end

    Enum.join(base_sections ++ role_sections, "\n\n")
  end

  # ---------------------------------------------------------------------------
  # D-382 — Role-specific instruction section
  # ---------------------------------------------------------------------------

  defp role_section(:test_author, gating_test_paths) do
    paths_text =
      case gating_test_paths do
        nil -> "(none declared)"
        [] -> "(none declared)"
        paths -> Enum.join(paths, "\n")
      end

    """
    ## Your Role: Test Author

    You are the **test author** for this issue. Your task is to WRITE the gating
    test that will gate the implementer's work.

    **Instructions:**

    1. You are operating in a **fresh isolated worktree**. Edit files in your
       current working directory and commit your changes.
    2. Write the gating test for this issue. The test must fail before the
       implementation exists and pass after.
    3. Commit the gating test to the expected path(s) listed below.

    **Expected gating-test path(s):**

    #{paths_text}

    Do NOT implement the production code. Write ONLY the gating test and commit it.
    """
    |> String.trim_trailing()
  end

  defp role_section(:implementer, _gating_test_paths) do
    """
    ## Your Role: Implementer

    You are the **implementer** for this issue. Your task is to implement the
    issue to satisfy the gating test written by the test author.

    **Instructions:**

    1. Read the gating-test path(s) listed in the **Gating-Test Paths** section
       above to understand what the test expects.
    2. Implement the production code to make the gating test pass.
    3. Do NOT modify the gating test — implement the production code only.
    4. Commit your implementation when the gating test passes.

    Implement the issue described above. Your implementation must satisfy the
    gating test.
    """
    |> String.trim_trailing()
  end

  defp issue_section(issue) do
    number = Map.get(issue, "number", "?")
    title = Map.get(issue, "title", "")
    body = Map.get(issue, "body", "")

    body_text =
      case body do
        nil -> "(none declared)"
        "" -> "(none declared)"
        b -> b
      end

    """
    ## Issue ##{number}: #{title}

    #{body_text}
    """
    |> String.trim_trailing()
  end

  defp scope_section(scope, compact?) do
    files = Map.get(scope, :files, MapSet.new())
    codepoints = Map.get(scope, :codepoints, MapSet.new())
    specs = Map.get(scope, :specs, MapSet.new())
    resources = Map.get(scope, :resources, MapSet.new())
    deps = Map.get(scope, :deps, [])

    render_fn = if compact?, do: &render_set_or_dash/1, else: &render_set_or_none/1
    render_list_fn = if compact?, do: &render_list_or_dash/1, else: &render_list_or_none/1

    files_text = render_fn.(files)
    codepoints_text = render_fn.(codepoints)
    specs_text = render_fn.(specs)
    resources_text = render_fn.(resources)
    deps_text = render_list_fn.(deps)

    """
    ## Declared Scope

    **Files:** #{files_text}
    **Codepoints:** #{codepoints_text}
    **SPEC references:** #{specs_text}
    **Resources:** #{resources_text}
    **Dependencies:** #{deps_text}
    """
    |> String.trim_trailing()
  end

  defp gating_tests_section(nil, compact?), do: gating_tests_section([], compact?)

  defp gating_tests_section(paths, compact?) do
    content = if compact?, do: render_list_or_dash(paths), else: render_list_or_none(paths)

    """
    ## Gating-Test Paths

    #{content}
    """
    |> String.trim_trailing()
  end

  defp spec_refs_section(nil, compact?), do: spec_refs_section([], compact?)

  defp spec_refs_section(refs, compact?) do
    content = if compact?, do: render_list_or_dash(refs), else: render_list_or_none(refs)

    """
    ## SPEC / AC / D-NNN References

    #{content}
    """
    |> String.trim_trailing()
  end

  defp arch_pointers_section(nil), do: arch_pointers_section([])

  defp arch_pointers_section([]) do
    # D-372: arch-pointer section is mandatory; when no pointers supplied,
    # include the root pointer to discharge feedback_brief_implementers_with_arch.
    """
    ## Architecture Pointers

    - #{@default_arch_root}/
    """
    |> String.trim_trailing()
  end

  defp arch_pointers_section(pointers) do
    content = Enum.map_join(pointers, "\n", fn p -> "- #{p}" end)

    """
    ## Architecture Pointers

    #{content}
    """
    |> String.trim_trailing()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp render_set_or_none(set) when is_struct(set, MapSet) do
    if MapSet.size(set) == 0 do
      "(none declared)"
    else
      set
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map_join(", ", &render_set_member/1)
    end
  end

  # String members (e.g. :files) pass through unchanged.
  defp render_set_member(member) when is_binary(member), do: member

  # Codepoint tuples {path, :"line_NN"} — produced by IssueSelector for any
  # "file:line" citation — are rendered as "path:line_number" (e.g. "lib/x.ex:42").
  # Calling Enum.join on the raw tuples would trigger Protocol.UndefinedError
  # (String.Chars not implemented for tuples), crashing assemble/2 (D-373).
  defp render_set_member({path, line_atom})
       when is_binary(path) and is_atom(line_atom) do
    line_str = Atom.to_string(line_atom)

    line_number =
      case String.split(line_str, "line_", parts: 2) do
        [_, n] -> n
        _ -> line_str
      end

    "#{path}:#{line_number}"
  end

  # Atom members (e.g. :spec_FACTORY_CORE from extract_specs/1, :resource_gh_api
  # from label-derived resources) — render as their string name so spec identifiers
  # remain legible in the assembled brief (D-373 totality over real scope types).
  defp render_set_member(member) when is_atom(member), do: Atom.to_string(member)

  # Catch-all: any unforeseen member shape falls back to inspect/1 so the renderer
  # can never raise on an unexpected type (D-373 "never raises" is absolute).
  defp render_set_member(other), do: inspect(other)

  defp render_list_or_none([]), do: "(none declared)"

  defp render_list_or_none(list) when is_list(list) do
    Enum.join(list, ", ")
  end

  # Compact variants: render empty as "-" instead of "(none declared)".
  # Used in role-aware briefs (D-382) so the brief is free of the D-373
  # degradation placeholder.

  defp render_set_or_dash(set) when is_struct(set, MapSet) do
    if MapSet.size(set) == 0 do
      "-"
    else
      set
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map_join(", ", &render_set_member/1)
    end
  end

  defp render_list_or_dash([]), do: "-"

  defp render_list_or_dash(list) when is_list(list) do
    Enum.join(list, ", ")
  end
end

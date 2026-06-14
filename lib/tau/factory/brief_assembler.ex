defmodule Tau.Factory.BriefAssembler do
  @moduledoc """
  Pure, network-free assembler that projects a brief/issue map into a
  `task.prompt` string delivered to the implementer worker.

  ## Contract (D-372 / D-373, SPEC-FACTORY-CORE §4 B10 amendment)

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

  ## API

      Tau.Factory.BriefAssembler.assemble(input, [])
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
  """
  @spec assemble(map(), keyword()) :: String.t()
  def assemble(input, opts) do
    assemble_fun = Keyword.get(opts, :assemble_fun)

    if assemble_fun do
      assemble_fun.(input)
    else
      default_assemble(input)
    end
  end

  # ---------------------------------------------------------------------------
  # Default heuristic assembler (D-372 template, pure and deterministic)
  # ---------------------------------------------------------------------------

  defp default_assemble(input) do
    issue = Map.fetch!(input, :issue)
    declared_scope = Map.fetch!(input, :declared_scope)
    gating_test_paths = Map.get(input, :gating_test_paths)
    spec_refs = Map.get(input, :spec_refs)
    arch_pointers = Map.get(input, :arch_pointers)

    sections = [
      issue_section(issue),
      scope_section(declared_scope),
      gating_tests_section(gating_test_paths),
      spec_refs_section(spec_refs),
      arch_pointers_section(arch_pointers)
    ]

    Enum.join(sections, "\n\n")
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

  defp scope_section(scope) do
    files = Map.get(scope, :files, MapSet.new())
    codepoints = Map.get(scope, :codepoints, MapSet.new())
    specs = Map.get(scope, :specs, MapSet.new())
    resources = Map.get(scope, :resources, MapSet.new())
    deps = Map.get(scope, :deps, [])

    files_text = render_set_or_none(files)
    codepoints_text = render_set_or_none(codepoints)
    specs_text = render_set_or_none(specs)
    resources_text = render_set_or_none(resources)
    deps_text = render_list_or_none(deps)

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

  defp gating_tests_section(nil), do: gating_tests_section([])

  defp gating_tests_section(paths) do
    content = render_list_or_none(paths)

    """
    ## Gating-Test Paths

    #{content}
    """
    |> String.trim_trailing()
  end

  defp spec_refs_section(nil), do: spec_refs_section([])

  defp spec_refs_section(refs) do
    content = render_list_or_none(refs)

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

  # String members (e.g. :files, :specs, :resources) pass through unchanged.
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

  defp render_list_or_none([]), do: "(none declared)"

  defp render_list_or_none(list) when is_list(list) do
    Enum.join(list, ", ")
  end
end

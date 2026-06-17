defmodule Tau.Factory.Toolchain do
  @moduledoc """
  Per-language toolchain adapter behaviour (D-S2 polyglot seam).

  Adapters DESCRIBE; the engine EXECUTES and JUDGES (HR-3,
  SPEC-FACTORY-GATE §4 B4). Every callback returns a declarative struct or
  map — argv, env, and the machine-readable report format — NOT a verdict and
  NOT a side-effecting run.

  Host-enforced: adapter output is advisory data, never control. A buggy or
  adversarial adapter CANNOT bypass the gate floor, the merge serialization,
  or the isolation boundary — those live entirely on the trusted engine side.

  ## Atom dispatch (OTP non-negotiable #2)

  Adapter selection is by atom pattern-match via `for/1`. Never use
  string-keyed dispatch. Unknown language atoms fail closed.

  ## Adapters

    * `Tau.Factory.Toolchain.Elixir` — self-host bootstrap adapter.

  ## Types

  All callbacks accept a `ctx()` map that carries per-unit context (worktree
  path, policy pin, etc.). The Elixir adapter ignores all context fields
  (documented as `_ctx`); future adapters may consume them for workspace paths
  or language-version pins.
  """

  @typedoc "Per-unit context passed to every callback. Adapters may ignore it."
  @type ctx :: map()

  @typedoc "Declarative recipe: argv list + environment map."
  @type recipe :: %{required(:argv) => [String.t()], required(:env) => %{String.t() => String.t()}}

  @typedoc "Supported language atoms (pattern-matched in `for/1`)."
  @type language :: :elixir

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Returns a recipe describing how to fetch/install dependencies.

  Recipe keys:
    * `:argv` — command + args (non-empty list of strings).
    * `:env`  — environment variable overrides (map, may be empty).
  """
  @callback install_deps(ctx :: ctx()) :: recipe()

  @doc """
  Returns a recipe describing how to compile/build the project.

  Recipe keys: same as `install_deps/1`.
  """
  @callback build(ctx :: ctx()) :: recipe()

  @doc """
  Returns a recipe describing how to produce a release/package artifact.

  Recipe keys: same as `install_deps/1`.
  """
  @callback package(ctx :: ctx()) :: recipe()

  @doc """
  Returns a `%Tau.Toolchain.TestDescriptor{}` describing how the engine runs
  the full test suite and where to find the machine-readable report artifact.

  Data only — no subprocess is run, no verdict is returned.
  """
  @callback test_descriptor(ctx :: ctx()) :: Tau.Toolchain.TestDescriptor.t()

  @doc """
  Returns a `%Tau.Toolchain.TestDescriptor{}` describing how the engine runs
  only the gating-test subset for the mutation check.

  Data only — no subprocess is run, no verdict is returned.
  """
  @callback mutation_descriptor(ctx :: ctx()) :: Tau.Toolchain.TestDescriptor.t()

  @doc """
  Returns a `%Tau.Toolchain.LintDescriptor{}` describing the ordered set of
  lint/compile/typecheck steps the engine runs and judges by exit status
  (SPEC-FACTORY-GATE §5.2 HR-6).

  Data only — no subprocess is run, no verdict is returned.
  """
  @callback lint(ctx :: ctx()) :: Tau.Toolchain.LintDescriptor.t()

  @doc """
  Returns the complete list of `%Tau.Toolchain.ResourceNS{}` entries that name
  every mutable path this toolchain touches OUTSIDE the git checkout
  (HOME-namespace caches, XDG dirs, per-language download caches).

  The Worker fleet (W) allocates per-worker namespaces over exactly this set
  to prevent concurrent-worker cache collisions (SPEC-FACTORY-GATE §4 B9;
  `worktree-discipline.md`). Declarative data: W enforces isolation; the
  adapter cannot opt out.
  """
  @callback declare_resource_namespace(ctx :: ctx()) :: [Tau.Toolchain.ResourceNS.t()]

  @doc """
  Returns the filename of the project's build manifest (the file whose presence
  at a given git ref signals that a project existed at that ref).

  Used by the gate engine to determine the project-creation N/A condition
  (Gate 5.3): when the manifest file is absent at `merge_base`, the entire
  project was PR-created and the mutation check is N/A.

  Examples:
    - Elixir: `"mix.exs"`
    - Node.js: `"package.json"`
    - Rust:    `"Cargo.toml"`

  Returns `nil` when the language has no conventional single-file manifest
  (the N/A condition is then skipped — the mutation check runs unconditionally).
  """
  @callback project_manifest_file(ctx :: ctx()) :: String.t() | nil

  # ---------------------------------------------------------------------------
  # Atom dispatch
  # ---------------------------------------------------------------------------

  @doc """
  Resolves a language atom to the corresponding adapter module.

  Uses atom pattern-match (OTP non-negotiable #2; SPEC-FACTORY-GATE §3 [C218]).
  Unknown atoms fail closed — never `String.to_atom/1`, never string-keyed.

  Returns `{:error, {:unsupported_language, lang}}` for unknown atoms.
  """
  @spec for(language :: atom()) ::
          Tau.Factory.Toolchain.Elixir
          | {:error, {:unsupported_language, atom()}}
  def for(:elixir), do: Tau.Factory.Toolchain.Elixir
  def for(lang), do: {:error, {:unsupported_language, lang}}
end

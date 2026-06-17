defmodule Tau.Factory.ToolchainPolyglotSeamTest do
  @moduledoc """
  Gating test for issue #643 — D-S2 polyglot-seam conformance.

  The invariant (SPEC-FACTORY-GATE §2 C8 / §4 B4 / §3 [C206-B4]):

    > The Toolchain seam is polyglot: the gate's mutation half MUST dispatch to
    > `Tau.Factory.Toolchain.for(req.language)` to obtain a per-language adapter,
    > then call `adapter.mutation_descriptor(ctx)` to get a declarative
    > `%TestDescriptor{}`. The engine executes the descriptor. Gate correctness
    > MUST NOT depend on any language-specific code path hard-coded in the engine
    > (e.g. a Mix-specific project-sentinel check using "mix.exs", an inline
    > ExUnit TAP-runner script, or a descriptor whose `:argv` names `"elixir"`
    > directly rather than being supplied by the adapter).

  Current violation (audit finding D-S2, issue #643):

    * `Gate.run/1` -> `run_mutation_half/1` -> `run_via_engine/2` builds a
      `%TestDescriptor{argv: ["elixir", script_rel], ...}` directly, naming
      the Elixir runtime and synthesising an inline ExUnit/TAP formatter script.
      It never calls `Toolchain.for/1` or `adapter.mutation_descriptor/1`.
    * `project_creation_na?/3` walks upward looking for `"mix.exs"` — a
      Mix/Elixir sentinel hard-coded in the engine.

  This test exercises the REAL entry point `Tau.Factory.Gate.run/1` (never a
  hand-built `%Verdict{}`) and asserts:

    1. `Gate.Request` carries a `:language` field (the gate must know which
       toolchain to dispatch to — currently absent from the struct definition).
    2. When `language: :node` (a valid atom for which `Toolchain.for/1` returns
       `{:error, {:unsupported_language, :node}}`), the mutation half fails
       closed: the gate cannot run an Elixir TAP script for a Node.js project.
       The final `%Verdict{status: :fail}` is the expected signal.
    3. The Elixir adapter's `mutation_descriptor/1` returns
       `%TestDescriptor{report: :junit}`, not `:tap`. A conformant gate uses the
       adapter-supplied descriptor; the current gate ignores the adapter and
       hardcodes `%TestDescriptor{report: :tap}` with a synthesised ExUnit script.

  Fail mode against current code:
    - Test 1: `struct!(Gate.Request, %{..., language: :node})` raises
      `** (KeyError) key :language not found` because the struct has no :language
      field. This is the primary fail-before signal.
    - Test 2: If :language were added but the gate ignores it, `Gate.run/1` with
      `language: :node` would attempt to run the hardcoded Elixir TAP script inside
      a non-Elixir repo — violating D-S2 (language-specific knowledge in engine).
    - Test 3: Passes against the existing adapter (it already returns :junit), but
      confirms the seam contract so implementers know the expected shape.

  Authored by the `test-author` agent BEFORE any production fix exists (issue
  #643, oracle-separation phase, D-304). MUST NOT be resolved by adding
  production code in this file.

  AC linkage: D-S2
  """

  use ExUnit.Case, async: false

  @moduletag :d_s2

  # Runtime module references — deferred so this file compiles even before the
  # modules exist. Missing modules surface as UndefinedFunctionError at runtime.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer
  @toolchain Tau.Factory.Toolchain

  # ---------------------------------------------------------------------------
  # Setup — a per-test Ledger Writer (matches gate_run_test.exs pattern)
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_polyglot_seam_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Test 1: Gate.Request MUST carry a :language field (D-S2 prerequisite)
  #
  # The gate cannot dispatch Toolchain.for(req.language) without the language
  # atom on the request. The current struct definition has no :language key.
  # ---------------------------------------------------------------------------

  @tag :d_s2
  test "D-S2: Gate.Request struct includes a :language field for Toolchain dispatch",
       %{writer: writer} do
    # struct!/2 with an unknown key raises KeyError if :language is absent from
    # Gate.Request. This is the primary fail-before signal for D-S2.
    req_fields = %{
      unit: "pr-d-s2",
      diff: "",
      frozen_paths: MapSet.new(["test/placeholder_test.exs"]),
      policy_pin: %{oracle: %{critic: :pass, reviewer: :pass}},
      workspace: "/tmp/placeholder",
      merge_base: "deadbeef",
      hash: "cafebabe",
      run: "run-1",
      ledger: writer,
      language: :elixir
    }

    # If :language is not in Gate.Request's defined fields, struct!/2 raises:
    #   (KeyError) key :language not found in: %Tau.Factory.Gate.Request{...}
    # That KeyError IS the correct fail-before: the struct must be extended to
    # carry the language atom so the engine can dispatch Toolchain.for(language).
    result = struct!(@request_mod, req_fields)

    assert Map.has_key?(result, :language),
           "D-S2: Gate.Request (#{inspect(@request_mod)}) must define a :language " <>
             "field so the engine can dispatch Toolchain.for(req.language). " <>
             "The field is currently absent from the struct definition. " <>
             "Got keys: #{inspect(Map.keys(result))}"

    assert result.language == :elixir,
           "D-S2: Gate.Request :language field must round-trip the supplied value. " <>
             "Got: #{inspect(result.language)}"
  end

  # ---------------------------------------------------------------------------
  # Test 2: Gate.run/1 with an unsupported language fails closed (D-S2 / D-306)
  #
  # When the language atom does NOT resolve to a known adapter
  # (Toolchain.for(:node) => {:error, {:unsupported_language, :node}}), the
  # mutation half MUST fail closed. The gate cannot silently fall back to
  # running a hardcoded Elixir TAP script for an unknown language.
  # ---------------------------------------------------------------------------

  @tag :d_s2
  test "D-S2: Gate.run/1 with language: :node fails closed — unsupported language via Toolchain.for/1",
       %{writer: writer, fixture_root: root} do
    # Precondition: Toolchain.for(:node) must fail closed.
    assert {:error, {:unsupported_language, :node}} = @toolchain.for(:node),
           "D-S2 precondition: Toolchain.for(:node) must return " <>
             "{:error, {:unsupported_language, :node}} (fail-closed dispatch)"

    # A minimal git repo with no Elixir project structure.
    # Simulates a non-Elixir (e.g. Node.js) project.
    repo = build_non_elixir_repo(root)

    policy_pin = %{
      gate_manifest: [:mutation, :critic, :reviewer],
      gate_concurrency: 4,
      gate_timeout: 30_000,
      oracle: %{critic: :pass, reviewer: :pass}
    }

    # The request specifies language: :node. The conformant gate must dispatch
    # Toolchain.for(:node), receive {:error, {:unsupported_language, :node}},
    # and fail-close the mutation half. The overall verdict must be :fail.
    req =
      struct!(@request_mod, %{
        unit: "pr-d-s2-node",
        diff: diff_for(repo),
        frozen_paths: MapSet.new([repo.gating_rel]),
        policy_pin: policy_pin,
        workspace: repo.dir,
        merge_base: repo.merge_base,
        hash: repo.head,
        run: "run-d-s2",
        ledger: writer,
        language: :node
      })

    verdict = @gate.run(req)

    assert verdict.status == :fail,
           "D-S2: Gate.run/1 with an unsupported language (:node) MUST return a " <>
             ":fail verdict. The mutation half must fail closed when " <>
             "Toolchain.for(:node) returns {:error, {:unsupported_language, :node}}. " <>
             "A gate that ignores the :language field and runs an Elixir TAP script " <>
             "instead is a D-S2 violation — language-specific code inside the engine. " <>
             "Got: #{inspect(verdict)}"
  end

  # ---------------------------------------------------------------------------
  # Test 3: The Elixir adapter's mutation_descriptor reports :junit (not :tap)
  #
  # The conformant gate must dispatch Toolchain.for(:elixir) and use the adapter's
  # mutation_descriptor/1. The adapter returns %TestDescriptor{report: :junit}.
  # The CURRENT engine ignores the adapter and hardcodes report: :tap (via a
  # synthesised inline ExUnit TAP runner). A conformant engine would use :junit.
  #
  # This test pins the adapter seam contract so the D-S2 fix is verifiable:
  # after the fix, the gate's mutation half will use the adapter's :junit
  # descriptor instead of a hardcoded :tap script.
  # ---------------------------------------------------------------------------

  @tag :d_s2
  test "D-S2: Toolchain.Elixir.mutation_descriptor/1 returns :junit (not :tap) — the adapter drives the format, not the engine" do
    # The adapter must exist and be resolvable via Toolchain.for/1.
    adapter = @toolchain.for(:elixir)

    refute match?({:error, _}, adapter),
           "D-S2: Toolchain.for(:elixir) must return the adapter module, " <>
             "not an error. Got: #{inspect(adapter)}"

    descriptor = adapter.mutation_descriptor(%{})

    assert is_struct(descriptor, Tau.Toolchain.TestDescriptor),
           "D-S2: mutation_descriptor/1 must return %Tau.Toolchain.TestDescriptor{}, " <>
             "got: #{inspect(descriptor)}"

    # The Elixir adapter declares :junit format (SPEC-FACTORY-GATE Toolchain.Elixir).
    # The conformant engine MUST use this format — the adapter, not the engine,
    # supplies the report format. The current engine hardcodes :tap and never
    # calls mutation_descriptor/1 at all.
    assert descriptor.report == :junit,
           "D-S2: The Elixir adapter's mutation_descriptor must specify :junit " <>
             "report format (adapter-supplied). The current engine hardcodes :tap " <>
             "via an inline ExUnit TAP runner — Elixir-specific knowledge in the engine. " <>
             "Adapter says report=#{inspect(descriptor.report)}, expected :junit."

    # The adapter's argv MUST be a mix-invocation (e.g. ["mix", "test"]), NOT
    # ["elixir", <generated_script>]. The engine must execute the adapter-supplied
    # argv verbatim and MUST NOT substitute its own Elixir-runtime invocation.
    assert is_list(descriptor.argv) and descriptor.argv != [],
           "D-S2: mutation_descriptor/1 must return non-empty argv list"

    refute List.first(descriptor.argv) == "elixir",
           "D-S2: The adapter's mutation_descriptor argv must NOT begin with \"elixir\" " <>
             "(that is an engine-internal implementation bypassing the Toolchain seam). " <>
             "The engine must execute the adapter-supplied argv verbatim. " <>
             "Current adapter argv: #{inspect(descriptor.argv)}"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # A minimal git repo with no Elixir project structure (no mix.exs).
  # Represents a non-Elixir project (e.g. a Node.js repo).
  defp build_non_elixir_repo(root) do
    dir = Path.join(root, "non_elixir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    # Merge-base: a plain text file (not a Mix project).
    File.write!(Path.join(dir, "README.md"), "placeholder\n")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    # Implementer adds a test file (for a hypothetical Node test runner).
    gating_rel = "test/widget.test.js"
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, gating_rel), """
    // A trivial Node.js test placeholder.
    test("widget", () => { expect(1).toBe(1); });
    """)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/widget.js"), "module.exports = { value: 42 };\n")
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "impl"])
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    %{
      dir: dir,
      merge_base: merge_base,
      head: String.trim(head),
      gating_rel: gating_rel
    }
  end

  defp diff_for(repo) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    diff
  end
end

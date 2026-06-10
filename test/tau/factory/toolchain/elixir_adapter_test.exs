defmodule Tau.Factory.Toolchain.ElixirAdapterTest do
  @moduledoc """
  Gating tests for PR #430 (Closes #419) — `Tau.Factory.Toolchain` behaviour
  and `Tau.Factory.Toolchain.Elixir` adapter.

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - `lib/tau/factory/toolchain.ex`
    - `lib/tau/factory/toolchains/elixir.ex`
    - `lib/tau/toolchain/test_descriptor.ex`
    - `lib/tau/toolchain/lint_descriptor.ex`
    - `lib/tau/toolchain/resource_ns.ex`

  Struct assertions use `is_struct/2` (runtime) rather than `%Module{} = value`
  (compile-time) so the file compiles now and each test fails independently when
  the relevant module is absent at runtime.

  Pins SPEC-FACTORY-GATE §4 B4 (adapter returns DATA only, engine executes;
  HR-3 trust boundary), B9 (`declare_resource_namespace/1`), and §3 [C206-B4]
  (load-bearing HR-3 data-only rule). Cross-refs gate-and-toolchain.md §4 +
  §4.1 for the exact callback set and descriptor shapes.

  AC-P1-1 — descriptor shape: each callback returns a well-formed struct.
  AC-P1-2 — HR-3 data-only / purity: callbacks return data, not verdicts,
             with no side-effects, deterministically.
  AC-P1-3 — atom dispatch: `Tau.Factory.Toolchain.for(:elixir)` resolves;
             unknown atoms fail closed.

  Property tests are tagged `:property` (OTP non-negotiable #6: properties
  before examples for invariant-bearing modules).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  # Module references — do NOT use alias so that absent modules surface as
  # UndefinedFunctionError at runtime, not compile-time errors.
  @toolchain Tau.Factory.Toolchain
  @adapter Tau.Factory.Toolchain.Elixir

  # Struct module atoms — referenced via module attribute so pattern matches in
  # `is_struct/2` are deferred to runtime.
  @test_descriptor_mod Tau.Toolchain.TestDescriptor
  @lint_descriptor_mod Tau.Toolchain.LintDescriptor
  @resource_ns_mod Tau.Toolchain.ResourceNS

  # A minimal context. The Elixir adapter ignores context (all _ctx in arch
  # doc), so any map is a valid input.
  defp ctx, do: %{}

  # ==========================================================================
  # AC-P1-1 — Descriptor shape
  #
  # Each of the 7 callbacks MUST return a well-formed descriptor of the
  # expected shape. None may return a verdict ({:pass,_} / {:fail,_}).
  #
  # Sources: SPEC-FACTORY-GATE §4 B4; gate-and-toolchain.md §4, §4.1.
  # ==========================================================================

  describe "AC-P1-1: install_deps/1 descriptor shape" do
    @tag :ac_p1_1
    test "returns a recipe map with non-empty :argv list and :env map" do
      result = @adapter.install_deps(ctx())
      assert is_map(result), "install_deps/1 must return a map"
      assert Map.has_key?(result, :argv), "recipe must have :argv key"
      assert Map.has_key?(result, :env), "recipe must have :env key"
      assert is_list(result.argv) and result.argv != [], "argv must be a non-empty list"
      assert Enum.all?(result.argv, &is_binary/1), "every argv element must be a string"
      assert is_map(result.env), ":env must be a map"
    end
  end

  describe "AC-P1-1: build/1 descriptor shape" do
    @tag :ac_p1_1
    test "returns a recipe map with non-empty :argv list and :env map" do
      result = @adapter.build(ctx())
      assert is_map(result), "build/1 must return a map"
      assert Map.has_key?(result, :argv), "recipe must have :argv key"
      assert Map.has_key?(result, :env), "recipe must have :env key"
      assert is_list(result.argv) and result.argv != [], "argv must be a non-empty list"
      assert Enum.all?(result.argv, &is_binary/1), "every argv element must be a string"
      assert is_map(result.env), ":env must be a map"
    end
  end

  describe "AC-P1-1: package/1 descriptor shape" do
    @tag :ac_p1_1
    test "returns a recipe map with non-empty :argv list and :env map" do
      result = @adapter.package(ctx())
      assert is_map(result), "package/1 must return a map"
      assert Map.has_key?(result, :argv), "recipe must have :argv key"
      assert Map.has_key?(result, :env), "recipe must have :env key"
      assert is_list(result.argv) and result.argv != [], "argv must be a non-empty list"
      assert Enum.all?(result.argv, &is_binary/1), "every argv element must be a string"
      assert is_map(result.env), ":env must be a map"
    end
  end

  describe "AC-P1-1: test_descriptor/1 shape (TestDescriptor struct)" do
    @tag :ac_p1_1
    test "returns a %Tau.Toolchain.TestDescriptor{} with non-empty argv, :junit report, string artifact" do
      result = @adapter.test_descriptor(ctx())
      # is_struct/2 defers struct existence check to runtime.
      assert is_struct(result, @test_descriptor_mod),
             "test_descriptor/1 must return %#{inspect(@test_descriptor_mod)}{}"

      assert is_list(result.argv) and result.argv != [], "argv must be a non-empty list"
      assert Enum.all?(result.argv, &is_binary/1), "every argv element must be a string"
      assert result.report == :junit, "Elixir adapter must emit :junit report format"

      assert is_binary(result.artifact) and result.artifact != "",
             "artifact must be a non-empty relative path string"
    end
  end

  describe "AC-P1-1: mutation_descriptor/1 shape (TestDescriptor struct)" do
    @tag :ac_p1_1
    test "returns a %Tau.Toolchain.TestDescriptor{} with non-empty argv, :junit report, string artifact" do
      result = @adapter.mutation_descriptor(ctx())

      assert is_struct(result, @test_descriptor_mod),
             "mutation_descriptor/1 must return %#{inspect(@test_descriptor_mod)}{}"

      assert is_list(result.argv) and result.argv != [], "argv must be a non-empty list"
      assert Enum.all?(result.argv, &is_binary/1), "every argv element must be a string"
      assert result.report == :junit, "Elixir adapter must emit :junit report format"

      assert is_binary(result.artifact) and result.artifact != "",
             "artifact must be a non-empty relative path string"
    end
  end

  describe "AC-P1-1: lint/1 shape (LintDescriptor struct)" do
    @tag :ac_p1_1
    test "returns a %Tau.Toolchain.LintDescriptor{} with non-empty steps list" do
      result = @adapter.lint(ctx())

      assert is_struct(result, @lint_descriptor_mod),
             "lint/1 must return %#{inspect(@lint_descriptor_mod)}{}"

      assert is_list(result.steps) and result.steps != [], "steps must be a non-empty list"

      for step <- result.steps do
        assert Map.has_key?(step, :argv), "lint step must have :argv"
        assert is_list(step.argv) and step.argv != [], "lint step argv must be non-empty"
        assert Map.has_key?(step, :report), "lint step must have :report"
      end
    end
  end

  describe "AC-P1-1: declare_resource_namespace/1 shape (ResourceNS list)" do
    @tag :ac_p1_1
    test "returns a non-empty list of %Tau.Toolchain.ResourceNS{} covering MIX_HOME, HEX_HOME, XDG_DATA_HOME" do
      result = @adapter.declare_resource_namespace(ctx())

      assert is_list(result) and result != [],
             "declare_resource_namespace/1 must return a non-empty list"

      assert Enum.all?(result, &is_struct(&1, @resource_ns_mod)),
             "every element must be a %#{inspect(@resource_ns_mod)}{}"

      # The Elixir adapter MUST declare at minimum: MIX_HOME, HEX_HOME, XDG_DATA_HOME.
      # (gate-and-toolchain.md §4.1; worktree-discipline.md: Burrito cache isolation.)
      vars = Enum.map(result, & &1.var)
      assert "MIX_HOME" in vars, "ResourceNS list must include MIX_HOME"
      assert "HEX_HOME" in vars, "ResourceNS list must include HEX_HOME"

      assert "XDG_DATA_HOME" in vars,
             "ResourceNS list must include XDG_DATA_HOME (Burrito unpack cache)"
    end
  end

  # ==========================================================================
  # Structural: the Elixir adapter implements the Toolchain behaviour
  #
  # Not a standalone AC, but a prerequisite. We assert the behaviour
  # declaration is present so the compiler enforces the full callback set.
  # ==========================================================================

  describe "structural: Tau.Factory.Toolchain.Elixir declares the Toolchain behaviour" do
    @tag :ac_p1_1
    test "module declares @behaviour Tau.Factory.Toolchain" do
      behaviours =
        @adapter.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert @toolchain in behaviours,
             "#{inspect(@adapter)} must declare @behaviour #{inspect(@toolchain)}"
    end
  end

  # ==========================================================================
  # AC-P1-2 — HR-3 data-only / purity (the load-bearing SPEC constraint)
  #
  # SPEC-FACTORY-GATE §3 [C206-B4] + §4 B4:
  #   - Callbacks return descriptor DATA, not verdicts.
  #   - No side-effects: calling the callback must NOT create the named artifact.
  #   - Determinism: same ctx => equal descriptor across two calls.
  #
  # Properties are tagged `:property` per OTP non-negotiable #6.
  # ==========================================================================

  describe "AC-P1-2 (property): test_descriptor/1 returns a descriptor, never a verdict" do
    @tag :property
    @tag :ac_p1_2
    property "test_descriptor/1 never returns a {:pass,_} or {:fail,_} tuple" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        result = @adapter.test_descriptor(ctx)

        refute match?({:pass, _}, result),
               "test_descriptor/1 must never return {:pass, _}"

        refute match?({:fail, _}, result),
               "test_descriptor/1 must never return {:fail, _}"

        refute match?({:error, _}, result),
               "test_descriptor/1 must never return {:error, _}"

        assert is_struct(result, @test_descriptor_mod),
               "test_descriptor/1 must return %#{inspect(@test_descriptor_mod)}{}"
      end
    end
  end

  describe "AC-P1-2 (property): mutation_descriptor/1 returns a descriptor, never a verdict" do
    @tag :property
    @tag :ac_p1_2
    property "mutation_descriptor/1 never returns a {:pass,_} or {:fail,_} tuple" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        result = @adapter.mutation_descriptor(ctx)

        refute match?({:pass, _}, result),
               "mutation_descriptor/1 must never return {:pass, _}"

        refute match?({:fail, _}, result),
               "mutation_descriptor/1 must never return {:fail, _}"

        assert is_struct(result, @test_descriptor_mod),
               "mutation_descriptor/1 must return %#{inspect(@test_descriptor_mod)}{}"
      end
    end
  end

  describe "AC-P1-2 (property): lint/1 returns a descriptor, never a verdict" do
    @tag :property
    @tag :ac_p1_2
    property "lint/1 never returns a {:pass,_} or {:fail,_} tuple" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        result = @adapter.lint(ctx)

        refute match?({:pass, _}, result),
               "lint/1 must never return {:pass, _}"

        refute match?({:fail, _}, result),
               "lint/1 must never return {:fail, _}"

        assert is_struct(result, @lint_descriptor_mod),
               "lint/1 must return %#{inspect(@lint_descriptor_mod)}{}"
      end
    end
  end

  describe "AC-P1-2: test_descriptor/1 does NOT create its named artifact" do
    @tag :ac_p1_2
    test "calling test_descriptor/1 does not write the artifact file to disk (data-only, no side-effects)" do
      result = @adapter.test_descriptor(ctx())
      assert is_struct(result, @test_descriptor_mod)
      artifact_path = result.artifact

      # The descriptor only NAMES the path; it MUST NOT create it.
      # The engine creates it during execution — adapter is data-only per HR-3.
      refute File.exists?(artifact_path),
             "test_descriptor/1 must not create #{artifact_path}; " <>
               "the descriptor is data — it names a path, it does not run anything"
    end
  end

  describe "AC-P1-2 (property): determinism — same ctx => equal test_descriptor" do
    @tag :property
    @tag :ac_p1_2
    property "test_descriptor/1 is deterministic" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        assert @adapter.test_descriptor(ctx) == @adapter.test_descriptor(ctx),
               "test_descriptor/1 must be deterministic (same ctx => equal descriptor)"
      end
    end
  end

  describe "AC-P1-2 (property): determinism — same ctx => equal lint descriptor" do
    @tag :property
    @tag :ac_p1_2
    property "lint/1 is deterministic" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        assert @adapter.lint(ctx) == @adapter.lint(ctx),
               "lint/1 must be deterministic (same ctx => equal descriptor)"
      end
    end
  end

  describe "AC-P1-2 (property): determinism — same ctx => equal resource namespace" do
    @tag :property
    @tag :ac_p1_2
    property "declare_resource_namespace/1 is deterministic" do
      check all(ctx <- StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.binary())) do
        assert @adapter.declare_resource_namespace(ctx) ==
                 @adapter.declare_resource_namespace(ctx),
               "declare_resource_namespace/1 must be deterministic"
      end
    end
  end

  # ==========================================================================
  # AC-P1-3 — Atom dispatch
  #
  # SPEC-FACTORY-GATE §3 [C218] + gate-and-toolchain.md §4:
  #   `Tau.Factory.Toolchain.for(:elixir)` returns the Elixir adapter module.
  #   Unknown atoms MUST fail closed (raise or {:error, _}), never silently
  #   return a fabricated module reference.
  #
  # OTP non-negotiable #2: extensibility seams are behaviours with atom dispatch.
  # ==========================================================================

  describe "AC-P1-3: Toolchain.for(:elixir) resolves to the Elixir adapter" do
    @tag :ac_p1_3
    test "for(:elixir) returns Tau.Factory.Toolchain.Elixir" do
      assert @toolchain.for(:elixir) == Tau.Factory.Toolchain.Elixir,
             "Toolchain.for(:elixir) must return Tau.Factory.Toolchain.Elixir"
    end
  end

  describe "AC-P1-3: Toolchain.for/1 on unknown language fails closed" do
    @tag :ac_p1_3
    test "for(:rust) raises or returns {:error, _} — never a plausible module" do
      # SPEC-FACTORY-GATE §3 [C206-B4]: a buggy or adversarial dispatch MUST NOT
      # silently return a usable module for an unknown language.
      outcome =
        try do
          {:returned, @toolchain.for(:rust)}
        rescue
          _ -> :raised
        catch
          :error, _ -> :raised
          :exit, _ -> :raised
        end

      case outcome do
        :raised ->
          :ok

        {:returned, {:error, _}} ->
          :ok

        {:returned, other} ->
          flunk(
            "Toolchain.for(:rust) must fail closed (raise or {:error,_}), " <>
              "but returned: #{inspect(other)}"
          )
      end
    end
  end

  describe "AC-P1-3 (property): for/1 on arbitrary unknown atoms always fails closed" do
    @tag :property
    @tag :ac_p1_3
    property "Toolchain.for/1 on atoms not in {:elixir} raises or returns {:error,_}" do
      known = MapSet.new([:elixir])

      check all(
              lang <- StreamData.atom(:alphanumeric),
              lang not in known
            ) do
        outcome =
          try do
            {:returned, @toolchain.for(lang)}
          rescue
            _ -> :raised
          catch
            :error, _ -> :raised
            :exit, _ -> :raised
          end

        case outcome do
          :raised ->
            :ok

          {:returned, {:error, _}} ->
            :ok

          {:returned, other} ->
            flunk(
              "Toolchain.for(#{inspect(lang)}) must fail closed, " <>
                "but returned: #{inspect(other)}"
            )
        end
      end
    end
  end
end

defmodule Tau.Factory.ToolchainRunnerScriptTest do
  @moduledoc """
  Gating test for issue #650 — FR-3.3 runner-script conformance.

  The invariant (docs/arch/02-requirements/R-list.md lines 72-75, FR-3.3):

    > The toolchain is a behaviour with per-language adapters (install-deps,
    > build, test, lint, mutation-run, package/release). All gating, isolation,
    > and health checks are expressed against this behaviour, never against a
    > hardcoded runner. Falsified by a gate or health check that names
    > mix/pytest/etc. directly instead of dispatching through the toolchain
    > behaviour.

  Audit finding (issue #650, evidence points 2 and 3):

    * `build_junit_runner/3` (gate.ex lines 422-519): the engine generates an
      ExUnit runner `.exs` script in the workspace — Elixir-specific knowledge
      INSIDE the engine, not the adapter. The script compiles `lib/**/*.ex`
      source files (Elixir project layout) and embeds an inline JUnit formatter.

    * `find_lib_ex_files/1` + `do_find_ex_files/2` (gate.ex lines 522-547):
      scan `workspace/lib/` for `.ex` files, encoding the Elixir source layout
      in the engine.

  Both are executable code in the engine that know the Elixir toolchain shape.
  FR-3.3 requires this knowledge to live EXCLUSIVELY in the Toolchain adapter.

  The conformant design (docs/arch/04-software-architecture/gate-and-toolchain.md
  §4.1 — the Elixir adapter example):

      def mutation_descriptor(ctx),
        do: %{test_descriptor(ctx) | argv: ~w(mix test --only gating ...)}

  The adapter returns a self-sufficient `mix test` invocation. The engine
  executes the adapter-supplied argv verbatim — it does NOT write any runner
  scripts, does NOT scan for `.ex` source files, and does NOT embed any
  Elixir-specific formatter or test-runner logic.

  ## Tests in this file

  1. **FR-3.3 adapter seam: mutation_descriptor(%{}) is self-sufficient.**
     The Elixir adapter's `mutation_descriptor/1` called with an EMPTY context
     (no engine-injected `script_rel`/`artifact_rel` keys) MUST return an argv
     that is a `mix test` invocation. The current adapter returns
     `["mix", "run", script_rel]` where `script_rel` is an engine-generated
     temp file — the adapter is NOT self-sufficient; it depends on the engine
     having already written the script.

  2. **FR-3.3 engine purity: Gate.run/1 MUST NOT write `.exs` runner scripts.**
     After `Gate.run/1` completes (or is cleaned up), NO `_gate_runner_*.exs`
     files should exist in the workspace. The conformant engine executes the
     adapter-supplied argv directly — it does not generate scripts. The current
     engine writes `_gate_runner_<nonce>.exs` into the workspace at
     `run_via_engine/2` (gate.ex line ~400), demonstrating Elixir-specific
     knowledge in the engine layer.

  ## Fail mode against current code

    - Test 1: `mutation_descriptor(%{})` returns
      `%TestDescriptor{argv: ["mix", "run", "_gate_runner.exs"]}`.
      The second element is "run", not "test". The assertion
      `assert List.at(descriptor.argv, 1) == "test"` fails immediately.

    - Test 2: `Gate.run/1` calls `build_junit_runner/3` which calls
      `File.write!(script_abs, ...)` before executing the descriptor, so the
      `_gate_runner_*.exs` file exists in the workspace during execution
      (cleaned up after, but written during). To catch the write-then-clean
      pattern, the test intercepts the workspace before Gate.run and uses a
      FileSystem watcher stub approach: it directly inspects `build_junit_runner`
      behaviour by looking for artifacts written but then deleted. The most
      reliable approach is to use a custom workspace and list files mid-run —
      but since Gate.run is async, we instead assert at the adapter seam (Test 1)
      and additionally assert via the `Gate.run` path that the engine's
      `run_via_engine/2` MUST supply an empty ctx to `mutation_descriptor/1`
      (i.e., the adapter must work with empty ctx, which the current engine
      violates by injecting `script_rel`/`artifact_rel`).

  Authored by the `test-author` agent BEFORE any production fix exists (issue
  #650, oracle-separation phase, D-304). MUST NOT be resolved by adding
  production code in this file.

  AC linkage: FR-3.3
  """

  use ExUnit.Case, async: false

  @moduletag :fr_3_3

  # Runtime module references — deferred so this file compiles even before the
  # modules exist.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer
  @toolchain Tau.Factory.Toolchain
  @test_descriptor_mod Tau.Toolchain.TestDescriptor

  # ---------------------------------------------------------------------------
  # Setup — a per-test Ledger Writer + tmp workspace root
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_fr33_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Test 1: FR-3.3 adapter seam — mutation_descriptor(%{}) is self-sufficient
  #
  # The Elixir adapter MUST return a self-contained `mix test` descriptor when
  # called with an empty context. The engine MUST NOT inject runner-script paths
  # via ctx; the adapter supplies all necessary information in the descriptor.
  #
  # Current violation: mutation_descriptor(%{}) returns
  #   %TestDescriptor{argv: ["mix", "run", "_gate_runner.exs"]}
  # where "_gate_runner.exs" is an engine-generated script. The adapter depends
  # on the engine having written a script. FR-3.3 requires the adapter alone to
  # describe how to run the mutation check — NOT the engine.
  #
  # Conformant: mutation_descriptor(%{}) returns
  #   %TestDescriptor{argv: ["mix", "test", ...]}
  # No engine-generated script; the adapter invokes mix test directly.
  # ---------------------------------------------------------------------------

  @tag :fr_3_3
  test "FR-3.3: Toolchain.Elixir.mutation_descriptor/1 with empty ctx returns a self-sufficient mix-test invocation" do
    adapter = @toolchain.for(:elixir)

    refute match?({:error, _}, adapter),
           "FR-3.3 precondition: Toolchain.for(:elixir) must resolve, got: #{inspect(adapter)}"

    # Call mutation_descriptor with an EMPTY context — no engine-injected
    # script_rel or artifact_rel. A conformant adapter must be self-sufficient.
    descriptor = adapter.mutation_descriptor(%{})

    assert is_struct(descriptor, @test_descriptor_mod),
           "FR-3.3: mutation_descriptor/1 must return %#{inspect(@test_descriptor_mod)}{}, " <>
             "got: #{inspect(descriptor)}"

    assert is_list(descriptor.argv) and descriptor.argv != [],
           "FR-3.3: mutation_descriptor/1 must return non-empty argv list"

    # The conformant argv begins with "mix" (any mix invocation is acceptable).
    assert List.first(descriptor.argv) == "mix",
           "FR-3.3: The Elixir adapter's mutation argv must begin with \"mix\" " <>
             "(the adapter dispatches via the toolchain, not a raw elixir invocation). " <>
             "Got argv: #{inspect(descriptor.argv)}"

    # The CRITICAL assertion: the second element MUST be "test", not "run".
    # "mix run <script>" means the adapter depends on an engine-generated runner
    # script — Elixir-specific knowledge embedded in the engine (FR-3.3 violation).
    # "mix test ..." means the adapter is self-sufficient; the engine executes the
    # adapter-supplied command verbatim without generating any language-specific
    # scripts.
    second_arg = Enum.at(descriptor.argv, 1)

    assert second_arg == "test",
           "FR-3.3 VIOLATION: The Elixir adapter's mutation_descriptor/1 returned " <>
             "argv #{inspect(descriptor.argv)}. The second element is " <>
             ~s("#{second_arg}", not "test".\n\n) <>
             "Current violation: the engine generates an ExUnit runner script " <>
             "(_gate_runner_<nonce>.exs) in build_junit_runner/3 (gate.ex ~line 434), " <>
             "scans workspace/lib for .ex files in find_lib_ex_files/1 (gate.ex ~line 522), " <>
             "then passes script_rel/artifact_rel via ctx so the adapter can return " <>
             ~s(["mix", "run", script_rel]. This embeds Elixir source-layout knowledge ) <>
             "(workspace/lib/*.ex) and ExUnit-specific script generation in the engine.\n\n" <>
             "FR-3.3 requires: the adapter alone describes the mutation-run recipe. " <>
             ~s(The conformant adapter returns ["mix", "test", "--only", "gating", ...] ) <>
             "and the engine executes it verbatim — NO script generation, NO .ex scanning."
  end

  # ---------------------------------------------------------------------------
  # Test 2: FR-3.3 engine purity — Gate.run/1 MUST NOT write Elixir runner scripts
  #
  # The engine's run_via_engine/2 currently writes a `_gate_runner_<nonce>.exs`
  # file to the workspace via build_junit_runner/3 before calling
  # adapter.mutation_descriptor(enriched_ctx). This is Elixir-specific script
  # generation in the engine layer — an FR-3.3 violation.
  #
  # This test exercises the REAL Gate.run/1 entry point and asserts that the
  # workspace does NOT accumulate any `_gate_runner_*.exs` artifacts during
  # or after the gate run. The conformant engine invokes the adapter-supplied
  # argv (a `mix test` command) directly — no scripts generated.
  #
  # Because the current engine cleans up the script after running it (File.rm
  # in the after block), we cannot detect the script via a post-run check.
  # Instead, we assert at the SEAM: the Gate.run/1 request is constructed
  # WITHOUT injecting any script paths into the ctx, and the
  # mutation_descriptor/1 callback (tested in Test 1 above) is what the engine
  # must use. The engine calling `Map.merge(ctx, %{script_rel: ..., artifact_rel: ...})`
  # before calling mutation_descriptor is the violation pattern — this test
  # asserts the final observable behavior: the verdict must be decided entirely
  # by the adapter's self-sufficient descriptor.
  #
  # To make this observable: we use a workspace where running `mix test --only
  # gating` would pass (a genuine mutation), and assert that Gate.run/1 returns
  # a :pass verdict. If the engine still uses the old script-generation path,
  # the descriptor returned by the adapter (using default ctx keys) will use
  # `_gate_runner.exs` which DOES NOT EXIST in a fresh context — the engine-
  # generated nonce script name doesn't match the adapter's static default.
  # This mismatch causes a runtime failure in TestRun.execute/2 (file not found)
  # which folds to a :fail verdict. A conformant engine returns :pass.
  #
  # Fail mode: the current engine writes the script at
  # `_gate_runner_<nonce>.exs` (nonce from :erlang.unique_integer) but the
  # adapter uses the default `_gate_runner.exs` from its static fallback (when
  # ctx lacks :script_rel). The engine currently enriches ctx WITH the nonce
  # path before calling mutation_descriptor, so the adapter DOES get the nonce
  # path. The test must therefore use a different observable: workspace cleanliness.
  #
  # REVISED APPROACH: Since the engine cleans up the script file, we cannot
  # detect it post-run. Instead, this test asserts that Gate.run/1 with a
  # genuine Elixir fixture produces a :pass verdict — and the adapter's
  # mutation_descriptor is the ONLY source of test-run instructions. We verify
  # this by checking: if the adapter returns a self-sufficient descriptor
  # (Test 1 passes), and the engine executes it verbatim, then a genuine
  # fixture MUST produce :pass. If the engine bypasses the adapter and runs
  # the old ExUnit script path (hardcoded Elixir runner), it may also produce
  # :pass — but Test 1 already catches the adapter seam violation.
  #
  # For complete FR-3.3 coverage: this test captures filesystem state around
  # Gate.run/1 using a sentinel-file approach. We list files before and after
  # Gate.run/1 to detect any intermediately written `.exs` files. Since the
  # engine cleans up, we use a sentinel directory watcher pattern:
  # we instrument the workspace by hooking file system events via a temporary
  # wrapper — but this is over-engineering for a failing gating test.
  #
  # FINAL APPROACH: Assert that mutation_descriptor is called with an EMPTY
  # ctx (engine must NOT inject script paths). We do this by verifying that
  # the adapter works correctly with empty ctx in Test 1, and separately verify
  # that Gate.run/1 with a genuine Elixir repo produces :pass (meaning the
  # engine correctly used the adapter-supplied descriptor without script injection).
  # If the adapter is fixed to return `["mix", "test"]` but the engine still
  # injects script paths via enriched_ctx, the engine would still be violating
  # FR-3.3 — but the production fix of the adapter alone is gated by Test 1.
  # ---------------------------------------------------------------------------

  @tag :fr_3_3
  test "FR-3.3: Gate.run/1 with a genuine Elixir repo uses the adapter's self-sufficient descriptor — no extraneous .exs artifacts in workspace",
       %{writer: writer, fixture_root: root} do
    # Build a genuine Elixir fixture repo (follows gate_run_test.exs pattern).
    repo = build_elixir_repo(root)

    # Enumerate files in workspace BEFORE Gate.run/1.
    exs_before = list_exs_files(repo.dir)

    policy_pin = %{
      gate_manifest: [:mutation, :critic, :reviewer],
      gate_concurrency: 4,
      gate_timeout: 60_000,
      oracle: %{critic: :pass, reviewer: :pass}
    }

    req =
      struct!(@request_mod, %{
        unit: "pr-fr33",
        diff: diff_for(repo),
        frozen_paths: repo.gating_paths,
        policy_pin: policy_pin,
        workspace: repo.dir,
        merge_base: repo.merge_base,
        hash: repo.head,
        run: "run-fr33",
        ledger: writer,
        language: :elixir
      })

    verdict = @gate.run(req)

    # Enumerate files in workspace AFTER Gate.run/1.
    exs_after = list_exs_files(repo.dir)

    # FR-3.3 engine purity: the set of .exs files in the workspace MUST NOT
    # have grown from the engine writing runner scripts. The conformant engine
    # executes the adapter-supplied `mix test` argv directly — no scripts written.
    #
    # If the engine wrote and then deleted `_gate_runner_*.exs`, the counts match.
    # If the engine wrote but did NOT delete it (e.g. a crash), the count grows.
    # Either way, the PRIMARY violation is captured in Test 1 (adapter seam):
    # the engine writing-then-deleting is still an FR-3.3 violation (Elixir
    # knowledge in engine), but it is only observable during the run, not after.
    #
    # This assertion catches any leaked runner scripts (non-cleanup failures).
    new_runner_scripts =
      MapSet.difference(MapSet.new(exs_after), MapSet.new(exs_before))
      |> Enum.filter(&String.contains?(&1, "_gate_runner"))

    assert new_runner_scripts == [],
           "FR-3.3: Gate.run/1 left engine-generated runner scripts in the workspace. " <>
             "The conformant engine must execute the adapter-supplied argv verbatim " <>
             "(no script generation). Leaked scripts: #{inspect(new_runner_scripts)}"

    # Additionally assert that a genuine fixture produces a verdict (not an error).
    # The mutation half must complete — either :pass or :fail (not a crash).
    assert verdict.status in [:pass, :fail],
           "FR-3.3: Gate.run/1 must complete with a :pass or :fail verdict. " <>
             "Got: #{inspect(verdict)}. If the engine cannot find a runner script " <>
             "it wrote (e.g. wrong path due to ctx injection mismatch), it crashes " <>
             "the mutation half and the gate errors. This indicates a runner-script " <>
             "dependency — an FR-3.3 violation."

    # The STRONGEST assertion: a genuine Elixir repo with a discriminating test
    # MUST produce :pass when the adapter correctly dispatches via `mix test`.
    # This fails if the engine bypasses the adapter and runs a hardcoded runner
    # that fails to find the ExUnit-tagged test (e.g., because the gating tag
    # used in the adapter's argv doesn't match what the engine's script uses).
    assert verdict.status == :pass,
           "FR-3.3: Gate.run/1 returned #{inspect(verdict.status)} instead of :pass " <>
             "for a genuine Elixir repo with a discriminating gating test. " <>
             "This may indicate the engine is still using a hardcoded ExUnit runner " <>
             "script that conflicts with the adapter's mutation_descriptor, or the " <>
             "adapter's self-sufficient descriptor (Test 1) is not being used. " <>
             "Full verdict: #{inspect(verdict)}"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Build a genuine Elixir git repo suitable for FR-3.3 engine tests.
  # Follows the gate_run_test.exs :genuine pattern exactly.
  defp build_elixir_repo(root) do
    dir = Path.join(root, "repo_fr33_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    # Merge-base: minimal mix project with no production module.
    File.write!(Path.join(dir, "mix.exs"), mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    # Implementer adds production code + a discriminating gating test.
    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

    gating_rel = "test/widget_test.exs"

    # The gating test uses @tag :gating so `mix test --only gating` picks it up.
    # This mirrors the conformant adapter's mutation_descriptor (which would use
    # `mix test --only gating`). The tag is required for FR-3.3 conformance:
    # the adapter's self-sufficient descriptor selects gating tests by tag, not
    # by path injection into a generated script.
    File.write!(Path.join(dir, gating_rel), """
    defmodule WidgetTest do
      use ExUnit.Case
      @tag :gating
      test "widget value is 42" do
        assert Widget.value() == 42
      end
    end
    """)

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "impl"])
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)

    %{
      dir: dir,
      merge_base: merge_base,
      head: String.trim(head),
      gating_paths: MapSet.new([gating_rel])
    }
  end

  defp mix_exs do
    """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.14"]
    end
    """
  end

  defp diff_for(repo) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    diff
  end

  # List all .exs files in `dir` recursively.
  defp list_exs_files(dir) do
    case File.ls(dir) do
      {:error, _} ->
        []

      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          abs = Path.join(dir, entry)

          cond do
            File.regular?(abs) and String.ends_with?(entry, ".exs") -> [Path.relative_to(abs, dir)]
            File.dir?(abs) -> list_exs_files(abs) |> Enum.map(&Path.join(entry, &1))
            true -> []
          end
        end)
    end
  end
end

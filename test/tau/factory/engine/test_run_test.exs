defmodule Tau.Factory.Engine.TestRunTest do
  @moduledoc """
  Gating tests for PR #431 (Closes #420) — `Tau.Factory.Engine.TestRun` (C6).

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - `lib/tau/factory/engine/test_run.ex`
    - `lib/tau/toolchain/report_parser.ex`
    - `lib/tau/toolchain/test_report.ex`

  The central invariant tested is HR-3: the ENGINE runs the subprocess, captures
  the artifact, selects a trusted parser by format tag, parses it ITSELF, and
  returns an engine-produced %TestReport{}. The adapter never touches the verdict
  path. A stubbed adapter that returns a fabricated "passed" descriptor CANNOT
  fold the mutation half PASS — the engine runs and parses the artifact itself,
  and a forged adapter claim has no path into the verdict.

  Approach for non-flakiness: every test uses a SYNTHETIC %TestDescriptor{} whose
  recipe is a tiny shell command that writes a KNOWN, deterministic JUnit-XML
  artifact to the named artifact path. This avoids invoking a real `mix test`
  subprocess (which would be slow, environment-dependent, and flaky) while still
  exercising the real Engine.TestRun.execute/2 code path with a real Port, real
  file write, and real parser invocation.

  The synthetic recipe:
    argv: ["sh", "-c", "<write known JUnit XML to $artifact_path>"]
    env: %{}
    report: :junit
    artifact: <relative path under tmp workspace>

  The workspace is a per-test tmp directory (System.tmp_dir!/0).

  AC linkage (SPEC-FACTORY-GATE §7):
    - AC-5 (D-306/HR-3): engine runs descriptor, parses artifact, returns %TestReport{}.
    - AC-DZ-1 / D-354: a forged adapter claim cannot make the engine return :passed
      when the artifact reports :failed.

  All property tests are tagged `:property`.
  """

  use ExUnit.Case, async: true

  @moduletag :ac_5
  @moduletag :d_306

  # Module references — runtime, so the file compiles before modules exist.
  @engine Tau.Factory.Engine.TestRun
  @test_report_mod Tau.Toolchain.TestReport
  @test_descriptor_mod Tau.Toolchain.TestDescriptor

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A tiny JUnit XML artifact with one FAILING case (the reverted-tree scenario).
  defp junit_one_failure do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites>
      <testsuite name="GatingTest" tests="2" failures="1">
        <testcase classname="GatingTest" name="gating test passes on real tree" time="0.001"/>
        <testcase classname="GatingTest" name="gating test fails on reverted tree" time="0.002">
          <failure message="Expected implementation, got nothing">UndefinedFunctionError</failure>
        </testcase>
      </testsuite>
    </testsuites>
    """
  end

  # A tiny JUnit XML artifact with ALL cases PASSING (vacuous suite / real-tree scenario).
  defp junit_all_pass do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites>
      <testsuite name="GatingTest" tests="2" failures="0">
        <testcase classname="GatingTest" name="gating test passes on real tree" time="0.001"/>
        <testcase classname="GatingTest" name="second passing test" time="0.002"/>
      </testsuite>
    </testsuites>
    """
  end

  # Build a synthetic TestDescriptor whose recipe writes `content` to the
  # relative artifact path within the workspace, then exits 0.
  # Uses `sh -c` so it runs on any POSIX system (same constraint as the engine).
  defp descriptor_writing_artifact(content, artifact_rel) do
    # Escape single quotes in content for embedding in a sh -c string.
    safe = String.replace(content, "'", "'\\''")

    script = "mkdir -p \"$(dirname \"$artifact\")\" && printf '%s' '#{safe}' > \"$artifact\""

    %{
      __struct__: @test_descriptor_mod,
      argv: ["sh", "-c", script],
      env: %{"artifact" => artifact_rel},
      report: :junit,
      artifact: artifact_rel
    }
  end

  # Create a fresh tmp workspace directory for each test.
  defp tmp_workspace do
    base = System.tmp_dir!()
    dir = Path.join(base, "tau_engine_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # ---------------------------------------------------------------------------
  # AC-5 / HR-3 — Engine executes descriptor and returns engine-parsed report
  #
  # This is the core HR-3 test: execute/2 runs the subprocess via Port, reads
  # the artifact, and returns a %TestReport{} whose content matches the artifact.
  # The adapter (descriptor) supplied only the recipe + format tag; the engine
  # parsed the artifact itself.
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-306 / HR-3: Engine.TestRun.execute/2 — engine runs and parses the artifact" do
    test "execute/2 with a descriptor that writes a failing JUnit artifact returns {:ok, %TestReport{}} with :failed cases" do
      ws = tmp_workspace()
      descriptor = descriptor_writing_artifact(junit_one_failure(), "report.xml")

      result = @engine.execute(descriptor, ws)

      assert {:ok, report} = result,
             "execute/2 must return {:ok, %TestReport{}}; got #{inspect(result)}"

      assert is_struct(report, @test_report_mod),
             "The Ok payload must be %#{inspect(@test_report_mod)}{}; got #{inspect(report)}"

      assert is_list(report.cases),
             "TestReport.cases must be a list"

      failed_cases = Enum.filter(report.cases, &(&1.status == :failed))

      assert failed_cases != [],
             "Engine-parsed report must contain :failed cases matching the artifact; " <>
               "cases: #{inspect(report.cases)}"

      File.rm_rf!(ws)
    end

    test "execute/2 with a descriptor that writes an all-pass JUnit artifact returns {:ok, %TestReport{}} with only :passed cases" do
      ws = tmp_workspace()
      descriptor = descriptor_writing_artifact(junit_all_pass(), "report.xml")

      result = @engine.execute(descriptor, ws)

      assert {:ok, report} = result
      assert is_struct(report, @test_report_mod)
      assert is_list(report.cases)

      failed_cases = Enum.filter(report.cases, &(&1.status == :failed))

      assert failed_cases == [],
             "Engine-parsed report must have no :failed cases for an all-pass artifact; " <>
               "cases: #{inspect(report.cases)}"

      File.rm_rf!(ws)
    end

    test "execute/2 returns {:error, _} when the recipe crashes (absent executable)" do
      ws = tmp_workspace()

      # A descriptor whose argv references a non-existent executable.
      # The engine must fail-closed: a crashing recipe => {:error, _}, not a fake pass.
      bad_descriptor = %{
        __struct__: @test_descriptor_mod,
        argv: ["/nonexistent/binary/that/does/not/exist"],
        env: %{},
        report: :junit,
        artifact: "report.xml"
      }

      result =
        try do
          @engine.execute(bad_descriptor, ws)
        rescue
          _e -> :raised
        catch
          k, v -> {:caught, k, v}
        end

      case result do
        {:error, _} ->
          # Correct: fail-closed.
          :ok

        :raised ->
          # Also acceptable: fail-closed (the engine raises, not returns a fake pass).
          :ok

        {:caught, _, _} ->
          # Also acceptable.
          :ok

        {:ok, report} ->
          flunk(
            "execute/2 must fail-closed on a crashing recipe; " <>
              "but returned {:ok, #{inspect(report)}} — this is a fake pass"
          )
      end

      File.rm_rf!(ws)
    end

    test "execute/2 returns {:error, _} when the artifact is absent after recipe runs" do
      ws = tmp_workspace()

      # Recipe runs successfully (exits 0) but does NOT write the artifact.
      no_artifact_descriptor = %{
        __struct__: @test_descriptor_mod,
        argv: ["sh", "-c", "true"],
        # sh -c "true" exits 0 but writes nothing
        env: %{},
        report: :junit,
        artifact: "nonexistent-report.xml"
      }

      result = @engine.execute(no_artifact_descriptor, ws)

      assert match?({:error, _}, result),
             "execute/2 must return {:error, _} when artifact is absent; got #{inspect(result)}"

      File.rm_rf!(ws)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-DZ-1 / D-354 — Anti-forge: the engine follows the ARTIFACT, not any
  # adapter claim.
  #
  # This is the load-bearing HR-3 anti-gaming test. The scenario:
  #   1. A descriptor's recipe writes a JUnit artifact reporting FAILURE.
  #   2. Some hypothetical adapter claim says "tests passed" — but this claim
  #      has no path into Engine.TestRun.execute/2; the engine ignores it.
  #   3. The engine's returned %TestReport{} reflects the ARTIFACT (failure),
  #      not the adapter claim.
  #
  # The "adapter claim" is simulated by verifying that the return value of
  # execute/2 matches the artifact, regardless of any field we might inject
  # into the descriptor struct beyond what the engine uses.
  # ---------------------------------------------------------------------------

  describe "AC-DZ-1 / D-354: Engine follows the artifact, not any adapter-supplied verdict" do
    @describetag :ac_dz_1
    @describetag :d_354

    test "descriptor recipe writes FAILING artifact; engine returns :failed cases (adapter claim is irrelevant)" do
      ws = tmp_workspace()

      # The descriptor's recipe writes a FAILING JUnit artifact.
      # We add a fabricated field to the descriptor map that an adversarial adapter
      # might hope the engine reads as a "verdict" — the engine must ignore it.
      descriptor =
        descriptor_writing_artifact(junit_one_failure(), "report.xml")
        |> Map.put(:__adapter_verdict__, :passed)
        |> Map.put(:__adapter_result__, {:pass, []})

      result = @engine.execute(descriptor, ws)

      assert {:ok, report} = result,
             "execute/2 must return {:ok, _}; got #{inspect(result)}"

      assert is_struct(report, @test_report_mod)

      # The ARTIFACT says failure — the engine must reflect that.
      failed_cases = Enum.filter(report.cases, &(&1.status == :failed))

      assert failed_cases != [],
             "AC-DZ-1 / D-354: engine must follow the ARTIFACT (has failures), " <>
               "not the fabricated adapter verdict field (:passed). " <>
               "Returned cases: #{inspect(report.cases)}"

      File.rm_rf!(ws)
    end

    test "descriptor recipe writes PASSING artifact; engine returns :passed cases (no fabricated failure)" do
      ws = tmp_workspace()

      # Inverse: adapter might try to inject a :failed verdict, but artifact is all-pass.
      descriptor =
        descriptor_writing_artifact(junit_all_pass(), "report.xml")
        |> Map.put(:__adapter_verdict__, :failed)
        |> Map.put(:__adapter_result__, {:fail, :some_fabricated_reason})

      result = @engine.execute(descriptor, ws)

      assert {:ok, report} = result
      assert is_struct(report, @test_report_mod)

      failed_cases = Enum.filter(report.cases, &(&1.status == :failed))

      assert failed_cases == [],
             "AC-DZ-1 / D-354: engine must follow the all-pass ARTIFACT, " <>
               "not the fabricated adapter :failed verdict. " <>
               "Returned cases: #{inspect(report.cases)}"

      File.rm_rf!(ws)
    end

    test "engine-parsed report case ids from the artifact are stable across two identical runs (both engine-produced)" do
      # This tests the cross-check binding: killed_ids from the reverted run must
      # appear in the passing ids from the real run. Both runs are engine-produced.
      # We verify that the same artifact yields the same case ids on two executions.
      ws1 = tmp_workspace()
      ws2 = tmp_workspace()
      descriptor = descriptor_writing_artifact(junit_one_failure(), "report.xml")

      {:ok, report1} = @engine.execute(descriptor, ws1)
      {:ok, report2} = @engine.execute(descriptor, ws2)

      ids1 = Enum.map(report1.cases, & &1.id) |> Enum.sort()
      ids2 = Enum.map(report2.cases, & &1.id) |> Enum.sort()

      assert ids1 == ids2,
             "AC-DZ-1 / D-354: same artifact must yield same case ids across runs " <>
               "(cross-check requires stable ids). Got #{inspect(ids1)} vs #{inspect(ids2)}"

      File.rm_rf!(ws1)
      File.rm_rf!(ws2)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 — The engine selects the parser by the descriptor's :report format tag
  #
  # The adapter supplies :report => :junit (or :tap). The engine selects the
  # trusted parser by that tag. The adapter does NOT supply the parser itself.
  # We verify this indirectly: a descriptor with :report => :junit is parsed as
  # JUnit; one with :report => :tap is parsed as TAP.
  # ---------------------------------------------------------------------------

  describe "AC-5: engine selects parser by format tag from the descriptor" do
    test "format tag :junit → JUnit parser is used (case count matches JUnit fixture)" do
      ws = tmp_workspace()
      descriptor = descriptor_writing_artifact(junit_one_failure(), "report.xml")

      {:ok, report} = @engine.execute(descriptor, ws)

      # JUnit fixture has exactly 2 testcases; the JUnit parser should produce 2 cases.
      assert length(report.cases) == 2,
             "JUnit parser must produce 2 cases from the 2-testcase JUnit fixture; " <>
               "got #{length(report.cases)} cases: #{inspect(report.cases)}"

      File.rm_rf!(ws)
    end

    test "a TAP artifact with TAP format tag is parsed as TAP" do
      ws = tmp_workspace()

      tap_content = """
      TAP version 13
      1..2
      ok 1 first test
      not ok 2 second test
      """

      safe = String.replace(tap_content, "'", "'\\''")
      script = "mkdir -p \"$(dirname \"$artifact\")\" && printf '%s' '#{safe}' > \"$artifact\""

      tap_descriptor = %{
        __struct__: @test_descriptor_mod,
        argv: ["sh", "-c", script],
        env: %{"artifact" => "tap-report.txt"},
        report: :tap,
        artifact: "tap-report.txt"
      }

      result = @engine.execute(tap_descriptor, ws)

      assert {:ok, report} = result,
             "execute/2 with :tap format must return {:ok, _}; got #{inspect(result)}"

      assert is_struct(report, @test_report_mod)
      statuses = Enum.map(report.cases, & &1.status)
      assert :passed in statuses, "TAP 'ok 1' must parse as :passed"
      assert :failed in statuses, "TAP 'not ok 2' must parse as :failed"

      File.rm_rf!(ws)
    end
  end
end

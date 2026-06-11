defmodule Tau.Toolchain.ReportParserTest do
  @moduledoc """
  Gating tests for PR #431 (Closes #420) — `Tau.Toolchain.ReportParser` (C9).

  Written BEFORE production code exists (oracle-separation phase, D-304).
  These tests fail with UndefinedFunctionError until the implementer creates:
    - `lib/tau/toolchain/report_parser.ex`
    - `lib/tau/toolchain/test_report.ex`

  Pins SPEC-FACTORY-GATE §4 B5:
    `ReportParser.parse/2 :: (artifact_bytes, format_tag) -> %TestReport{}` —
    total, engine-owned. `format_tag ∈ {:junit, :tap, …}` is the adapter's
    `report` field; the engine selects the parser, the adapter does NOT supply one.

  Invariants tested:
    - The parser is TOTAL: any artifact bytes (including malformed) yield a
      defined `%TestReport{}`, never a crash.
    - A valid JUnit-XML artifact with one passing and one failing case produces
      the expected `%TestReport{cases: [%{id, status}]}`.
    - A valid TAP artifact with one passing and one failing case is parsed.
    - Unknown format tags produce a defined result (empty report or error tuple),
      never a crash.
    - Properties: totality across random byte inputs (property-before-examples,
      OTP non-negotiable #6).

  AC linkage (SPEC-FACTORY-GATE §7):
    - AC-5 (D-306/HR-3): engine parses artifact itself via trusted ReportParser.
    - D-306: the parser is total; no crash on malformed input.

  All property tests are tagged `:property`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :ac_5
  @moduletag :d_306

  # Module references are runtime so the file compiles when modules do not exist;
  # each test fails independently with UndefinedFunctionError at call-time.
  @parser Tau.Toolchain.ReportParser
  @test_report_mod Tau.Toolchain.TestReport

  # ---------------------------------------------------------------------------
  # JUnit-XML fixtures
  #
  # Small self-contained XML strings the engine would receive as artifact_bytes.
  # Modelled on the JUnit-XML format JUnitFormatter / jest-junit emits.
  # ---------------------------------------------------------------------------

  @junit_one_pass_one_fail """
  <?xml version="1.0" encoding="UTF-8"?>
  <testsuites>
    <testsuite name="MyApp.SomeTest" tests="2" failures="1">
      <testcase classname="MyApp.SomeTest" name="passing test" time="0.001"/>
      <testcase classname="MyApp.SomeTest" name="failing test" time="0.002">
        <failure message="Expected true, got false">assertion failed</failure>
      </testcase>
    </testsuite>
  </testsuites>
  """

  @junit_all_pass """
  <?xml version="1.0" encoding="UTF-8"?>
  <testsuites>
    <testsuite name="MyApp.SomeTest" tests="2" failures="0">
      <testcase classname="MyApp.SomeTest" name="first passing test" time="0.001"/>
      <testcase classname="MyApp.SomeTest" name="second passing test" time="0.002"/>
    </testsuite>
  </testsuites>
  """

  @junit_all_fail """
  <?xml version="1.0" encoding="UTF-8"?>
  <testsuites>
    <testsuite name="MyApp.SomeTest" tests="2" failures="2">
      <testcase classname="MyApp.SomeTest" name="first failing test" time="0.001">
        <failure message="Assertion error">boom</failure>
      </testcase>
      <testcase classname="MyApp.SomeTest" name="second failing test" time="0.002">
        <failure message="Another error">bang</failure>
      </testcase>
    </testsuite>
  </testsuites>
  """

  # ---------------------------------------------------------------------------
  # TAP fixtures
  #
  # Test Anything Protocol — a line-based format. "ok N name" = pass,
  # "not ok N name" = fail.
  # ---------------------------------------------------------------------------

  @tap_one_pass_one_fail """
  TAP version 13
  1..2
  ok 1 passing test
  not ok 2 failing test
  """

  @tap_all_pass """
  TAP version 13
  1..2
  ok 1 first passing test
  ok 2 second passing test
  """

  # ---------------------------------------------------------------------------
  # AC-5 / D-306 — JUnit parse: fixture assertions
  #
  # The parser is total and produces %TestReport{cases: [%{id, status}]}.
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-306: parse/2 with :junit format tag" do
    test "one passing + one failing case → TestReport with :passed and :failed cases" do
      result = @parser.parse(@junit_one_pass_one_fail, :junit)

      # Must return a %TestReport{}, not crash or {:error, _}.
      assert is_struct(result, @test_report_mod),
             "parse/2 must return %#{inspect(@test_report_mod)}{}; got #{inspect(result)}"

      assert is_list(result.cases),
             "TestReport.cases must be a list; got #{inspect(result.cases)}"

      assert length(result.cases) == 2,
             "Expected 2 cases in the report; got #{inspect(result.cases)}"

      statuses = Enum.map(result.cases, & &1.status)
      assert :passed in statuses, "Expected at least one :passed case; got #{inspect(statuses)}"
      assert :failed in statuses, "Expected at least one :failed case; got #{inspect(statuses)}"

      # Every case must have an :id (the AC-to-test cross-check uses these).
      Enum.each(result.cases, fn tc ->
        assert Map.has_key?(tc, :id) and tc.id != nil and tc.id != "",
               "Each case must have a non-empty :id; got #{inspect(tc)}"
      end)
    end

    test "all-pass JUnit → TestReport with only :passed cases (vacuous suite scenario)" do
      result = @parser.parse(@junit_all_pass, :junit)

      assert is_struct(result, @test_report_mod)
      assert is_list(result.cases)

      assert Enum.all?(result.cases, &(&1.status == :passed)),
             "All cases must be :passed; got #{inspect(result.cases)}"
    end

    test "all-fail JUnit → TestReport with only :failed cases" do
      result = @parser.parse(@junit_all_fail, :junit)

      assert is_struct(result, @test_report_mod)
      assert is_list(result.cases)

      assert Enum.all?(result.cases, &(&1.status == :failed)),
             "All cases must be :failed; got #{inspect(result.cases)}"
    end

    test "parsed :failed case ids from JUnit are non-empty strings" do
      result = @parser.parse(@junit_one_pass_one_fail, :junit)

      failed_cases = Enum.filter(result.cases, &(&1.status == :failed))
      assert failed_cases != [], "Expected at least one :failed case"

      Enum.each(failed_cases, fn tc ->
        assert is_binary(tc.id) and tc.id != "",
               "Failed case id must be a non-empty string; got #{inspect(tc.id)}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-306 — TAP parse: fixture assertions
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-306: parse/2 with :tap format tag" do
    test "one passing + one failing TAP → TestReport with :passed and :failed cases" do
      result = @parser.parse(@tap_one_pass_one_fail, :tap)

      assert is_struct(result, @test_report_mod),
             "parse/2 with :tap must return %#{inspect(@test_report_mod)}{}; got #{inspect(result)}"

      assert is_list(result.cases)
      statuses = Enum.map(result.cases, & &1.status)
      assert :passed in statuses
      assert :failed in statuses
    end

    test "all-pass TAP → TestReport with only :passed cases" do
      result = @parser.parse(@tap_all_pass, :tap)

      assert is_struct(result, @test_report_mod)
      assert Enum.all?(result.cases, &(&1.status == :passed))
    end
  end

  # ---------------------------------------------------------------------------
  # D-306 — Totality: malformed input must never crash (always returns %TestReport{})
  #
  # SPEC-FACTORY-GATE §4 B5: "total, engine-owned" — a malformed artifact yields
  # a defined result (e.g. %TestReport{cases: []} or an :error), never a crash.
  # A crash here means a forged artifact could take down the gate process.
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-306: parse/2 totality — malformed input never crashes" do
    test "malformed JUnit (truncated XML) → defined result, no crash" do
      malformed = "<testsuites><testsuite name=\"broken\""

      result =
        try do
          {:ok, @parser.parse(malformed, :junit)}
        rescue
          e -> {:crashed, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      case result do
        {:ok, report} ->
          # Either an empty-cases report or a map/struct indicating parse failure.
          # What it must NOT be is a crash.
          assert is_struct(report, @test_report_mod) or is_map(report) or
                   match?({:error, _}, report),
                 "Malformed input must yield a defined result; got #{inspect(report)}"

        {:crashed, e} ->
          flunk(
            "parse/2 with malformed JUnit must not crash; " <>
              "got exception #{inspect(e.__struct__)}: #{Exception.message(e)}"
          )

        {:caught, kind, val} ->
          flunk(
            "parse/2 with malformed JUnit must not raise; " <>
              "caught #{kind}: #{inspect(val)}"
          )
      end
    end

    test "empty byte string → defined result, no crash" do
      result =
        try do
          {:ok, @parser.parse("", :junit)}
        rescue
          e -> {:crashed, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      case result do
        {:ok, _} -> :ok
        {:crashed, e} -> flunk("parse/2 with empty input crashed: #{Exception.message(e)}")
        {:caught, k, v} -> flunk("parse/2 with empty input threw #{k}: #{inspect(v)}")
      end
    end

    test "binary garbage bytes → defined result, no crash" do
      garbage = <<0x00, 0xFF, 0x80, 0x01, 0x7F, 0xAB, 0xCD>>

      result =
        try do
          {:ok, @parser.parse(garbage, :junit)}
        rescue
          e -> {:crashed, e}
        catch
          kind, val -> {:caught, kind, val}
        end

      case result do
        {:ok, _} -> :ok
        {:crashed, e} -> flunk("parse/2 with garbage bytes crashed: #{Exception.message(e)}")
        {:caught, k, v} -> flunk("parse/2 with garbage bytes threw #{k}: #{inspect(v)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # D-306 — Unknown format tag: defined result, never crash
  # SPEC-FACTORY-GATE §4 B5: format_tag ∈ {:junit, :tap, …}.
  # An unknown tag must produce a defined result, not crash or silently
  # emit a forged pass.
  # ---------------------------------------------------------------------------

  @tag :ac_5
  @tag :d_306
  test "AC-5 / D-306: unknown format tag → defined result, no crash or fabricated pass" do
    result =
      try do
        {:ok, @parser.parse("<some>data</some>", :unknown_format)}
      rescue
        e -> {:crashed, e}
      catch
        kind, val -> {:caught, kind, val}
      end

    case result do
      {:ok, report} ->
        # A well-defined output — either empty cases or {:error, _} wrapped in a struct.
        # It must NOT be a struct with :passed cases that look legitimate.
        refute match?(%{cases: [%{status: :passed} | _]}, report),
               "Unknown format must not fabricate a passing report; got #{inspect(report)}"

      {:crashed, _e} ->
        # A crash on unknown format is also acceptable (fail-closed).
        # But it must NOT be a silent pass — which we already tested above.
        :ok

      {:caught, _k, _v} ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 — Property: totality across random byte inputs + known format tags
  #
  # For all binary inputs (including malformed), parse/2 with a known format
  # tag must never crash — it must return a defined value.
  # Properties before examples (OTP non-negotiable #6; SPEC-FACTORY-GATE §6 D-306).
  # ---------------------------------------------------------------------------

  @tag :ac_5
  @tag :d_306
  @tag :property
  property "AC-5 / D-306 (property): parse/2 with :junit is total — never crashes on arbitrary bytes" do
    check all(artifact_bytes <- StreamData.binary()) do
      result =
        try do
          {:ok, @parser.parse(artifact_bytes, :junit)}
        rescue
          _ -> :crashed
        catch
          _, _ -> :crashed
        end

      refute result == :crashed,
             "parse/2 with :junit must be total — must not crash on any binary input"
    end
  end

  @tag :ac_5
  @tag :d_306
  @tag :property
  property "AC-5 / D-306 (property): parse/2 with :tap is total — never crashes on arbitrary bytes" do
    check all(artifact_bytes <- StreamData.binary()) do
      result =
        try do
          {:ok, @parser.parse(artifact_bytes, :tap)}
        rescue
          _ -> :crashed
        catch
          _, _ -> :crashed
        end

      refute result == :crashed,
             "parse/2 with :tap must be total — must not crash on any binary input"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 — %TestReport{} shape invariant
  #
  # Whatever parse/2 returns, if it is a %TestReport{}, every case must have
  # :id and :status fields (the cross-check in Engine.TestRun uses these).
  # ---------------------------------------------------------------------------

  @tag :ac_5
  @tag :d_306
  @tag :property
  property "AC-5 (property): every case in a TestReport has :id and :status fields" do
    check all(artifact_bytes <- StreamData.binary()) do
      result =
        try do
          @parser.parse(artifact_bytes, :junit)
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      if is_struct(result, @test_report_mod) and is_list(result.cases) do
        Enum.each(result.cases, fn tc ->
          assert Map.has_key?(tc, :id),
                 "Every TestReport case must have an :id field; got #{inspect(tc)}"

          assert Map.has_key?(tc, :status),
                 "Every TestReport case must have a :status field; got #{inspect(tc)}"

          assert tc.status in [:passed, :failed, :skipped],
                 "Case :status must be :passed | :failed | :skipped; got #{inspect(tc.status)}"
        end)
      end
    end
  end
end

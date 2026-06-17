defmodule Tau.Factory.Gate.MaskingSurfacingTest do
  @moduledoc """
  Gating test for INV-MASKING-DETECTION-ONLY (issue #551) — Clause 2:

    "Every flagged masking finding MUST be surfaced to the critic as a mandatory
     review item; there is no self-authored bypass tag."

  The PARTIAL audit verdict confirmed that:
    - Clause 1 (Masking.scan/2 returns only {:clean | :flagged, findings}) IS
      enforced and tested by masking_property_test.exs (P-MK3).
    - Clause 2 (Gate.run/1 MUST surface flagged findings to the critic oracle)
      has NO executable implementation. Gate.run/1 never calls Masking.scan/2;
      masking is only reachable via the standalone Mix CLI shim.

  This test exercises Gate.run/1 (the real user-facing entry point, SPEC §4 B1)
  with a diff containing masking violations and asserts that:

    1. The [:tau, :factory, :gate, :masking, :flagged] telemetry event is emitted
       (arch §8 contract: "count: count, unit: unit, findings: findings"). This
       event is the observable proof that Gate.run/1 calls Masking.scan/2 on the
       diff during a gate run.

    2. The emitted event carries the actual findings (non-empty list), confirming
       the findings are not discarded before being surfaced.

  Both assertions currently FAIL because Gate.run/1 never dispatches masking:
  the telemetry event is never emitted. This is the fail-before state — the
  implementer must wire Gate.run/1 → Masking.scan/2 → telemetry + oracle surfacing.

  Entry point: Tau.Factory.Gate.run/1 (SPEC-FACTORY-GATE §4 B1).
  Invariant id: INV-MASKING-DETECTION-ONLY.
  SPEC: SPEC-FACTORY-GATE §4 B6 / §3 C3/C207-B6.
  Arch: docs/arch/04-software-architecture/gate-and-toolchain.md §2.2, §6, §8.
  """

  use ExUnit.Case, async: false

  @moduletag :inv_masking_detection_only
  @moduletag :capture_log

  alias Tau.Factory.Gate
  alias Tau.Factory.Gate.Request
  alias Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Setup: isolated Ledger Writer + real git fixture repo
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_masking_surf_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {Writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Fixture helpers
  # ---------------------------------------------------------------------------

  defp init_git_repo(dir) do
    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git
  end

  defp diff_for(repo) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    diff
  end

  defp policy_pin do
    %{
      gate_manifest: [:mutation, :critic, :reviewer],
      gate_concurrency: 4,
      gate_timeout: 60_000,
      oracle: %{critic: :pass, reviewer: :pass}
    }
  end

  defp build_request(repo, writer, opts \\ []) do
    struct!(Request, %{
      unit: Keyword.get(opts, :unit, "inv-masking-detection-only-test"),
      diff: diff_for(repo),
      frozen_paths: Keyword.get(opts, :frozen_paths, repo.gating_paths),
      policy_pin: policy_pin(),
      workspace: repo.dir,
      merge_base: repo.merge_base,
      hash: repo.head,
      run: Keyword.get(opts, :run, "run-masking-surfacing-1"),
      ledger: writer
    })
  end

  # ---------------------------------------------------------------------------
  # Fixture: a repo where the implementer DELETES an assertion in the gating test.
  #
  # The gating test EXISTS at the merge-base commit (so it's a modification, not
  # an addition). The implementer's diff removes one assert. The gating test is
  # NOT in frozen_paths, so only assertion-deletion detection (P-MK1) fires.
  # The production module is added in the implementer commit, so the mutation
  # half has something real to revert.
  # ---------------------------------------------------------------------------
  defp build_repo_with_assertion_deletion(root) do
    dir = Path.join(root, "repo_masking_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git = init_git_repo(dir)

    gating_rel = "test/widget_test.exs"

    # merge-base: production module absent; gating test with TWO assertions.
    File.write!(Path.join(dir, gating_rel), """
    defmodule WidgetTest do
      use ExUnit.Case
      @tag :gating
      test "widget value is 42" do
        assert Widget.value() == 42
        assert Widget.value() > 0
      end
    end
    """)

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    # implementer: adds production code AND deletes the second assertion.
    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

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

    # frozen_paths is EMPTY — the gating test is not in the declared set.
    # Only assertion-deletion (P-MK1) fires; the path-violation (P-MK2) is silent.
    %{
      dir: dir,
      merge_base: merge_base,
      head: String.trim(head),
      gating_paths: MapSet.new([])
    }
  end

  # ---------------------------------------------------------------------------
  # Fixture: a repo with NO masking violations.
  #
  # The implementer ONLY adds new code — no assertion deletions and no edits to
  # any declared gating-test path. The gating test is newly added (not in any
  # prior commit) AND not in frozen_paths.
  # ---------------------------------------------------------------------------
  defp build_clean_repo(root) do
    dir = Path.join(root, "repo_clean_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git = init_git_repo(dir)

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    # implementer: adds production code + a brand-new gating test (no assertions removed).
    # gating_paths is empty so no path-violation fires.
    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

    File.write!(Path.join(dir, "test/widget_test.exs"), """
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
      gating_paths: MapSet.new([])
    }
  end

  # ---------------------------------------------------------------------------
  # Primary test: INV-MASKING-DETECTION-ONLY (Clause 2)
  #
  # Gate.run/1 MUST invoke Masking.scan/2 and emit
  # [:tau, :factory, :gate, :masking, :flagged] telemetry (arch §8) when the
  # diff contains masking violations.
  #
  # FAILS against current code: Gate.run/1 never calls Masking.scan/2.
  # ---------------------------------------------------------------------------

  @tag :inv_masking_detection_only
  test "INV-MASKING-DETECTION-ONLY: Gate.run/1 emits [:tau,:factory,:gate,:masking,:flagged] telemetry when the diff has masking violations",
       %{writer: writer, fixture_root: root} do
    repo = build_repo_with_assertion_deletion(root)
    req = build_request(repo, writer)

    # Precondition: Masking.scan/2 called directly on the fixture diff confirms
    # there IS a masking violation (assertion deletion). This proves the test is
    # not vacuous — the violation exists and Gate.run/1 should detect it.
    {masking_status, masking_findings} =
      Tau.Factory.Gate.Masking.scan(req.diff, req.frozen_paths)

    assert masking_status == :flagged,
           "INV-MASKING-DETECTION-ONLY: precondition failed — the fixture diff must " <>
             "contain a masking violation (deleted assertion). Got: #{inspect({masking_status, masking_findings})}. " <>
             "Diff snippet: #{String.slice(req.diff, 0, 500)}"

    assert masking_findings != [],
           "INV-MASKING-DETECTION-ONLY: precondition: Masking.scan/2 must return " <>
             "at least one finding."

    # Attach a telemetry spy for [:tau, :factory, :gate, :masking, :flagged].
    # This event is documented in SPEC-FACTORY-GATE §8 / arch gate-and-toolchain.md §8:
    #   "[:tau, :factory, :gate, :masking, :flagged] | count | unit, findings"
    # Gate.run/1 MUST emit it when Masking.scan/2 returns {:flagged, findings}.
    handler_id = "inv-masking-detection-only-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tau, :factory, :gate, :masking, :flagged],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:masking_flagged, metadata})
      end,
      nil
    )

    try do
      _verdict = Gate.run(req)
    after
      :telemetry.detach(handler_id)
    end

    masking_events =
      Stream.repeatedly(fn ->
        receive do
          {:masking_flagged, meta} -> meta
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    # Clause 2 assertion (the failing one):
    # Gate.run/1 must call Masking.scan/2 and emit the telemetry event.
    # FAILS against current code: masking_events == [] (event never emitted).
    assert masking_events != [],
           "INV-MASKING-DETECTION-ONLY (Clause 2): Gate.run/1 MUST call " <>
             "Masking.scan/2 on the diff during a gate run and emit " <>
             "[:tau, :factory, :gate, :masking, :flagged] telemetry when findings " <>
             "are present, so they can be surfaced to the critic as mandatory review " <>
             "items (SPEC-FACTORY-GATE §4 B6 / C207-B6). " <>
             "Gate.run/1 never dispatches masking — no event emitted. " <>
             "Issue #551 Clause 2 gap. " <>
             "Masking.scan/2 confirmed #{inspect(length(masking_findings))} finding(s) " <>
             "in the diff, but Gate.run/1 discarded them silently."

    [first_event | _] = masking_events

    assert Map.get(first_event, :findings, []) != [],
           "INV-MASKING-DETECTION-ONLY (Clause 2): the masking-flagged telemetry " <>
             "event metadata MUST carry the non-empty findings list. " <>
             "Got metadata: #{inspect(first_event)}"
  end

  # ---------------------------------------------------------------------------
  # Negative control: Gate.run/1 must NOT emit the masking:flagged event when
  # the diff is clean (no assertion deletions, no gating-path edits).
  # ---------------------------------------------------------------------------

  @tag :inv_masking_detection_only
  test "INV-MASKING-DETECTION-ONLY: Gate.run/1 does NOT emit masking:flagged telemetry when the diff has no masking violations",
       %{writer: writer, fixture_root: root} do
    repo = build_clean_repo(root)
    req = build_request(repo, writer, unit: "inv-masking-no-violation-test", run: "run-masking-clean-1")

    # Precondition: Masking.scan/2 must confirm no violations.
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    {clean_status, _clean_findings} =
      Tau.Factory.Gate.Masking.scan(diff, req.frozen_paths)

    assert clean_status == :clean,
           "INV-MASKING-DETECTION-ONLY: negative-control precondition failed — " <>
             "the clean fixture diff must have no masking violations. " <>
             "Got: #{inspect(clean_status)}"

    handler_id = "inv-masking-clean-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:tau, :factory, :gate, :masking, :flagged],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:masking_flagged_unexpected, metadata})
      end,
      nil
    )

    try do
      _verdict = Gate.run(req)
    after
      :telemetry.detach(handler_id)
    end

    unexpected_events =
      Stream.repeatedly(fn ->
        receive do
          {:masking_flagged_unexpected, meta} -> meta
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    assert unexpected_events == [],
           "INV-MASKING-DETECTION-ONLY: Gate.run/1 MUST NOT emit " <>
             "[:tau, :factory, :gate, :masking, :flagged] when the diff has no " <>
             "masking violations. Got unexpected events: #{inspect(unexpected_events)}"
  end
end

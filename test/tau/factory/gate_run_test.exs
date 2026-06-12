defmodule Tau.Factory.GateRunTest do
  @moduledoc """
  Gating tests for PR #464 (P5c-2 — Closes #463): the Gate orchestrator
  `Tau.Factory.Gate.run/1`.

  Authored by the `test-author` agent BEFORE any production code exists
  (oracle-separation phase, D-304). `Tau.Factory.Gate.run/1`,
  `Tau.Factory.Gate.compose/1`, `Tau.Factory.Gate.gate_floor/0`,
  `Tau.Factory.Gate.Request`, and `Tau.Factory.Gate.Verdict` do NOT yet exist;
  these tests are expected to FAIL (compile error / UndefinedFunctionError)
  until the implementer lands the orchestrator. That fail-before is the correct
  state and MUST NOT be resolved by adding production code in this file.

  ## What this gates (SPEC-FACTORY-GATE §3/§4/§6)

  The orchestrator fans out the gate halves, folds them into ONE `%Verdict{}`,
  and enforces the mandatory FLOOR `[:mutation, :critic, :reviewer]` regardless
  of Policy (D-354, non-shrinkable). Four load-bearing assertions, all against
  the REAL `run/1` / `compose/1` entry points (never a hand-built `%Verdict{}`):

  1. **AC-4 / D-306 (vacuous → :fail).** A Request whose production diff is
     empty/vacuous (a gating suite that passes wholesale against the
     production-absent reverted tree) folds the mutation half FAIL, so
     `run/1` returns `%Verdict{status: :fail}`. The load-bearing anti-vacuity
     oracle: a vacuous gating test cannot reach a PASS verdict.

  2. **AC-6 / D-304 / D-354 (genuine → :pass, full floor).** A Request over a
     fixture worktree with a genuine production change + a discriminating
     gating test (mutation half passes) returns `%Verdict{status: :pass}` with
     ALL floor members `:mutation`, `:critic`, `:reviewer` present in the
     folded verdict's `halves`.

  3. **D-335 (verdict lands append-only in L).** After `run/1`, the verdict is
     durable in the Ledger (`verdicts` table) — readable via the Writer's
     `latest_verdict_status/2`, append-only.

  4. **AC-6 / D-354 (floor non-shrinkable).** A `policy_pin` whose
     `gate_manifest` OMITS `:critic` is REJECTED by `compose/1`
     (`{:error, {:gate_floor_violation, _}}`), and `run/1` does NOT return a
     `:pass` verdict with the floor incomplete. The floor is re-asserted by the
     engine, never trusted from policy.

  ## Fixtures — REAL git worktrees, not hand-built half-results

  The mutation half is engine-owned (HR-3): it reverts `tracked ∖ gating_paths`
  to the merge-base and runs the gating tests in a host-isolated workspace. To
  exercise the real `run/1` without invoking a real LLM (for the critic/reviewer
  oracle halves) or a slow `mix test` subprocess, each fixture is a small,
  self-contained git repository:

    - a "genuine" repo: a production module with real behaviour + a gating test
      that FAILS when the production code is reverted to the merge-base (so the
      mutation half discriminates) and PASSES on the real tree;
    - a "vacuous" repo: a gating test that PASSES regardless of the production
      code (so reverting production does not break it — the vacuous hole).

  The deterministic critic/reviewer oracle results are injected through the
  `policy_pin` (see `policy_pin/1`). SEE THE TEST-AUTHOR REPORT: the SPEC §4 does
  not pin a concrete oracle-injection seam for unit testing; this test asserts
  against the SPEC-fixed floor/fold contract and uses the policy_pin oracle
  override as the seam. If the implementer's seam differs, this is a SPEC gap to
  be closed by a §3 amendment, NOT by editing this gating test.

  AC linkage (SPEC-FACTORY-GATE §7): AC-4, AC-6, D-304, D-306, D-335, D-354.
  """

  use ExUnit.Case, async: false

  @moduletag :ac_4
  @moduletag :ac_6
  @moduletag :d_304
  @moduletag :d_306
  @moduletag :d_335
  @moduletag :d_354
  @moduletag :capture_log

  # Runtime module references — the file compiles even before these exist.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Setup: one isolated Ledger Writer per test + a tmp fixture root
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_gate_run_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, writer_name: writer_name, db_path: db_path, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Fixture builders — real git repos the engine-owned mutation half evaluates
  # ---------------------------------------------------------------------------

  # Build a git repo with a merge-base commit, then an implementer commit, and
  # return its absolute path + merge-base oid + the declared gating-test paths.
  #
  # `kind` is :genuine, :vacuous, or :crash_on_revert.
  #   :genuine — production code is introduced by the implementer commit AND the
  #     gating test depends on it (fails when production is reverted).
  #   :vacuous — the gating test passes regardless (no dependency on production);
  #     reverting production does not break it → the vacuous hole.
  #   :crash_on_revert — production code is introduced by the implementer commit
  #     AND the gating test references it AT COMPILE TIME (a module attribute
  #     initialised from a production call). When production is reverted to the
  #     merge-base (the module is absent), the gating-test FILE FAILS TO COMPILE,
  #     so the reverted-tree test run produces NO test summary — a recipe crash.
  #     Per SPEC-FACTORY-GATE the mutation half MUST fail-closed (D-306, HR-3):
  #     a crash is indistinguishable from infrastructure failure, so it MUST NOT
  #     be silently treated as a discriminating PASS.
  defp build_repo(root, kind) do
    dir = Path.join(root, "repo_#{kind}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    # --- merge-base commit: a minimal mix project, no production module yet ---
    File.write!(Path.join(dir, "mix.exs"), mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    gating_rel = "test/widget_test.exs"

    case kind do
      :genuine ->
        # implementer adds production code...
        File.write!(Path.join(dir, "lib/widget.ex"), """
        defmodule Widget do
          def value, do: 42
        end
        """)

        # ...and a gating test that DEPENDS on it (fails when Widget is reverted).
        File.write!(Path.join(dir, gating_rel), """
        defmodule WidgetTest do
          use ExUnit.Case
          @tag :gating
          test "widget value is 42" do
            assert Widget.value() == 42
          end
        end
        """)

      :vacuous ->
        # implementer adds a gating test that asserts a TAUTOLOGY — it passes
        # regardless of any production code, so reverting production does not
        # break it. There is no genuine production change tied to the assertion.
        File.write!(Path.join(dir, gating_rel), """
        defmodule WidgetTest do
          use ExUnit.Case
          @tag :gating
          test "tautology" do
            assert 1 == 1
          end
        end
        """)

      :crash_on_revert ->
        # implementer adds production code...
        File.write!(Path.join(dir, "lib/widget.ex"), """
        defmodule Widget do
          def value, do: 42
        end
        """)

        # ...and a gating test that references it AT COMPILE TIME via a module
        # attribute. With Widget present the file compiles and the test passes.
        # When the mutation half reverts production (Widget is deleted at the
        # merge-base), `Widget.value()` in the module body raises at COMPILE
        # time, so the test file fails to compile and the reverted-tree run
        # yields NO "N tests, M failures" summary — i.e. a recipe crash, which
        # the mutation half MUST treat as FAIL (fail-closed; D-306 / HR-3), not
        # as a discriminating PASS.
        File.write!(Path.join(dir, gating_rel), """
        defmodule WidgetTest do
          use ExUnit.Case
          @widget_value Widget.value()
          @tag :gating
          test "widget value is 42 (compile-time pinned)" do
            assert @widget_value == 42
          end
        end
        """)
    end

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

  # The unified diff between merge-base and HEAD (the implementer's change set).
  defp diff_for(repo) do
    {diff, _} = System.cmd("git", ["diff", repo.merge_base, repo.head], cd: repo.dir)
    diff
  end

  # A policy_pin carrying deterministic oracle results so the critic/reviewer
  # floor halves do not invoke a real LLM. The floor is STILL re-asserted by
  # compose/1 — a deterministic PASS oracle does not remove a floor member, it
  # only supplies that half's result. The default manifest is the full floor.
  defp policy_pin(opts \\ []) do
    %{
      gate_manifest: Keyword.get(opts, :gate_manifest, [:mutation, :critic, :reviewer]),
      gate_concurrency: 4,
      gate_timeout: 60_000,
      # Deterministic oracle override — the seam this test relies on (SPEC gap;
      # see @moduledoc). Both oracle halves return :pass for the genuine case.
      oracle: Keyword.get(opts, :oracle, %{critic: :pass, reviewer: :pass})
    }
  end

  defp build_request(repo, writer, opts) do
    struct!(@request_mod, %{
      unit: Keyword.get(opts, :unit, "pr-464"),
      diff: diff_for(repo),
      frozen_paths: repo.gating_paths,
      policy_pin: Keyword.get(opts, :policy_pin, policy_pin()),
      # The engine-owned mutation half needs to locate the worktree + merge-base.
      # These are part of the Request the orchestrator threads to Engine.TestRun.
      workspace: repo.dir,
      merge_base: repo.merge_base,
      hash: repo.head,
      run: Keyword.get(opts, :run, "run-1"),
      ledger: writer
    })
  end

  # ---------------------------------------------------------------------------
  # 1. AC-4 / D-306 — vacuous/empty-production diff → :fail (anti-vacuity oracle)
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-306: a vacuous production diff folds the mutation half FAIL" do
    test "AC-4 / D-306: run/1 returns %Verdict{status: :fail} on a vacuous gating suite",
         %{writer: writer, fixture_root: root} do
      repo = build_repo(root, :vacuous)
      req = build_request(repo, writer, [])

      verdict = @gate.run(req)

      assert verdict.status == :fail,
             "AC-4 / D-306: a vacuous gating suite (passes wholesale against the " <>
               "production-absent reverted tree) MUST fold the mutation half FAIL, so " <>
               "run/1 returns a :fail verdict. Got: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. AC-6 / D-304 / D-354 — genuine diff → :pass with the full floor present
  # ---------------------------------------------------------------------------

  describe "AC-6 / D-304 / D-354: a genuine diff passes with the full floor folded in" do
    test "AC-6 / D-354: run/1 returns %Verdict{status: :pass} with mutation, critic, reviewer all present",
         %{writer: writer, fixture_root: root} do
      repo = build_repo(root, :genuine)
      req = build_request(repo, writer, [])

      verdict = @gate.run(req)

      assert verdict.status == :pass,
             "AC-6: a genuine diff with a discriminating gating test MUST pass the full " <>
               "floor. Got: #{inspect(verdict)}"

      # The folded verdict must carry every floor half. `halves` is a keyed
      # collection of per-half results; the floor members MUST all appear.
      half_ids = floor_half_ids(verdict)

      for floor_member <- [:mutation, :critic, :reviewer] do
        assert floor_member in half_ids,
               "AC-6 / D-354: floor member #{inspect(floor_member)} MUST be present in the " <>
                 "folded verdict halves. Floor is engine-fixed, non-shrinkable. " <>
                 "Got halves: #{inspect(half_ids)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2b. D-306 — crash-on-revert mutation half MUST fail-closed (HR-3)
  # ---------------------------------------------------------------------------
  #
  # The hole the prior 5-test suite missed (critic finding B1): when reverting
  # the production diff to the merge-base BREAKS COMPILATION of the gating test
  # (the test references the production module at compile time), the reverted-
  # tree run produces no test summary — a recipe crash, indistinguishable from
  # an infrastructure failure. SPEC-FACTORY-GATE's mutation half mandates
  # `recipe crash → FAIL` (fail-closed, HR-3 / D-306). A crash-as-:pass would let
  # a suite reach a green verdict on what should be a FAIL. This oracle exercises
  # the REAL `run/1` over such a fixture and asserts the folded verdict is :fail
  # and the mutation half result is NOT :pass.

  describe "D-306 (fail-closed): a revert-time compile crash folds the mutation half FAIL" do
    @tag :d_306
    test "D-306: run/1 returns %Verdict{status: :fail} when reverting production crashes the gating-test compile (fail-closed on crash)",
         %{writer: writer, fixture_root: root} do
      # A fixture whose gating test references the production module at COMPILE
      # TIME, so reverting production to the merge-base makes the gating-test
      # file fail to compile → the reverted-tree run crashes (no summary).
      repo = build_repo(root, :crash_on_revert)
      req = build_request(repo, writer, [])

      verdict = @gate.run(req)

      # The mutation half result must itself be :fail (fail-closed on crash) —
      # not :pass (the false-green the prior suite missed), not :skip.
      mutation_result = mutation_half_result(verdict)

      refute mutation_result == :pass,
             "D-306: a revert-time compile crash (the gating test cannot compile " <>
               "once production is reverted) is a recipe crash and MUST NOT be folded " <>
               "as a discriminating PASS. The mutation half MUST be fail-closed (HR-3). " <>
               "Got mutation half result: #{inspect(mutation_result)} in #{inspect(verdict)}"

      assert mutation_result == :fail or match?({:error, _}, mutation_result),
             "D-306: the mutation half MUST fail-closed (:fail or an {:error, _} crash " <>
               "marker) when reverting production breaks the gating-test compile. " <>
               "Got mutation half result: #{inspect(mutation_result)}"

      # ...and the folded verdict MUST therefore be :fail, never a silent :pass.
      assert verdict.status == :fail,
             "D-306: when the mutation half fails-closed on a revert-time compile crash, " <>
               "run/1 MUST return a :fail verdict (the crash cannot reach a PASS). " <>
               "Got: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. D-335 — the verdict lands append-only in L
  # ---------------------------------------------------------------------------

  describe "D-335: run/1 appends the verdict to the Ledger (append-only, durable)" do
    test "D-335: after run/1 the verdict is readable from L for the (hash, run) coordinate",
         %{writer: writer, fixture_root: root} do
      repo = build_repo(root, :genuine)
      req = build_request(repo, writer, run: "run-led-1")

      verdict = @gate.run(req)
      assert verdict.status == :pass

      # The verdict (or its floor halves) must be durable in L. We read back via
      # the Writer's projection. At least one floor half's status for this
      # coordinate must be present (not :none) — the gate is the sole producer
      # and it appended append-only (D-335).
      statuses =
        for half <- [:mutation, :critic, :reviewer] do
          @writer.latest_verdict_status(writer, %{hash: repo.head, run: "run-led-1", half: half})
        end

      assert Enum.any?(statuses, &match?({:ok, _}, &1)),
             "D-335: run/1 MUST append the verdict to the Ledger append-only; at least one " <>
               "floor half's status MUST be readable from L for (hash=#{repo.head}, " <>
               "run=run-led-1). Got: #{inspect(statuses)}"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. AC-6 / D-354 — floor non-shrinkable: a pin omitting :critic is rejected
  # ---------------------------------------------------------------------------

  describe "AC-6 / D-354: compose/1 rejects a policy that omits a floor member" do
    test "AC-6 / D-354: compose/1 rejects a gate_manifest omitting :critic (floor non-shrinkable)",
         %{} do
      # A Policy pin that tries to drop :critic from the manifest.
      shrunk_pin = policy_pin(gate_manifest: [:mutation, :reviewer])

      result = @gate.compose(shrunk_pin)

      refute match?({:ok, _}, result),
             "AC-6 / D-354: compose/1 MUST NOT accept a manifest that omits a floor member " <>
               "(:critic). The floor is re-asserted, not trusted from policy. Got: #{inspect(result)}"

      assert match?({:error, {:gate_floor_violation, _}}, result),
             "AC-6 / D-354: compose/1 MUST reject a floor-omitting pin with " <>
               "{:error, {:gate_floor_violation, _}}. Got: #{inspect(result)}"
    end

    test "AC-6 / D-354: run/1 does NOT return a :pass verdict when the pin omits :critic",
         %{writer: writer, fixture_root: root} do
      # Even with a genuine diff (mutation half would pass), a pin that shrinks
      # the floor MUST NOT yield a :pass — the floor is non-shrinkable by policy.
      repo = build_repo(root, :genuine)

      req =
        build_request(repo, writer, policy_pin: policy_pin(gate_manifest: [:mutation, :reviewer]))

      # run/1 must not produce a green verdict on a shrunk floor. Acceptable
      # behaviours: a :fail verdict, or raising (fail-closed). It must NOT be
      # a silent :pass with the floor incomplete.
      outcome =
        try do
          v = @gate.run(req)
          {:verdict, v}
        rescue
          e -> {:raised, e}
        catch
          k, v -> {:caught, k, v}
        end

      case outcome do
        {:verdict, v} ->
          refute v.status == :pass,
                 "AC-6 / D-354: run/1 MUST NOT return a :pass verdict when the policy pin " <>
                   "omits a floor member (:critic). Got: #{inspect(v)}"

        {:raised, _} ->
          :ok

        {:caught, _, _} ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Extract the mutation half's result from the folded verdict, robust to the
  # `halves` field being a map keyed by half id or a list of per-half pairs /
  # structs carrying an :id / :half key. Returns the raw per-half result
  # (`:pass` | `:fail` | `{:error, _}`), or `:absent` if the mutation half is
  # not present in the folded verdict.
  defp mutation_half_result(verdict) do
    case verdict.halves do
      %{} = m ->
        Map.get(m, :mutation, :absent)

      list when is_list(list) ->
        Enum.find_value(list, :absent, fn
          {:mutation, result} -> result
          %{id: :mutation, result: result} -> result
          %{half: :mutation, result: result} -> result
          _ -> false
        end)
    end
  end

  # Extract the set of half ids present in the folded verdict, robust to the
  # `halves` field being a map keyed by half id or a list of per-half result
  # structs/maps carrying an :id / :half key.
  defp floor_half_ids(verdict) do
    case verdict.halves do
      %{} = m ->
        Map.keys(m)

      list when is_list(list) ->
        Enum.map(list, fn
          {id, _result} -> id
          %{id: id} -> id
          %{half: id} -> id
          id when is_atom(id) -> id
        end)
    end
  end
end

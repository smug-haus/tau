defmodule Tau.Factory.EntrySymbolPresenceTest do
  @moduledoc """
  Gating test for issue #572 — D-307 (◐ INV-8) mechanizable narrowing:
  the engine asserts the declared user-entry symbol APPEARS in the gating test.

  ## What is gated (SPEC-FACTORY-GATE §6 D-307, AC-9)

  D-307 names one mechanizable narrowing of the under-asserting/wrong-path
  residual: HR-3 lets the engine assert the **declared user-entry symbol appears
  in the gating test source**.  When an entry symbol is declared in the request
  (via `policy_pin.entry_symbol`) and that symbol is ABSENT from every declared
  gating-test path at the current HEAD, the gate MUST return a `:fail` verdict.
  When the symbol IS present (appears literally in at least one gating-test
  source), the gate MUST NOT fail on that account — the mutation half or a
  dedicated entry-symbol half passes.

  This is the **mechanizable narrowing only**: "appears in the source" is not
  the same as "is the exercised path".  The under-asserting / wrong-path
  residual remains critic-bounded — D-307 explicitly states `◐ PARTIAL`.
  The SPEC names this test file (`entry_symbol_presence_test.exs`) and ties it
  to AC-9 (SPEC-FACTORY-GATE §7 AC-9).

  ## Entry point

  Tests exercise `Tau.Factory.Gate.run/1` with real git-repo fixtures — not a
  hand-built `%Verdict{}` struct.  This satisfies the factory-loop rule that
  gating tests exercise the **user-facing path** rather than a bypass seam.

  ## Fail-before state

  At the time this test is authored:
  - `Tau.Factory.Gate.Request` has no `:entry_symbol` field.
  - `Gate.run/1` composes no entry-symbol-presence half.
  - `Tau.Toolchain.TestDescriptor` has no `:entry_symbol` field.
  As a result the negative test (absent symbol → :fail) fails at assertion time:
  `run/1` returns `:pass` rather than `:fail`, because the check does not exist.
  That is the correct fail-before state.

  ## AC linkage

  AC-9, D-307.
  """

  use ExUnit.Case, async: false

  @moduletag :ac_9
  @moduletag :d_307

  # Runtime module references so this file compiles before the modules exist.
  @gate Tau.Factory.Gate
  @request_mod Tau.Factory.Gate.Request
  @writer Tau.Factory.Ledger.Writer

  # ---------------------------------------------------------------------------
  # Setup — one isolated Ledger Writer per test + a tmp fixture root
  # ---------------------------------------------------------------------------

  setup do
    db_path = Briefly.create!(extname: ".db")
    writer_name = :"test_d307_ledger_#{System.unique_integer([:positive])}"

    writer_pid =
      start_supervised!(
        {@writer, db_path: db_path, name: writer_name},
        id: writer_name
      )

    fixture_root = Briefly.create!(directory: true)

    %{writer: writer_pid, fixture_root: fixture_root}
  end

  # ---------------------------------------------------------------------------
  # Fixture helpers — real git repos
  # ---------------------------------------------------------------------------

  # Build a two-commit git repo:
  #   base commit: minimal mix project, no production code
  #   head commit: production module + gating test
  #
  # `gating_test_body` is the raw Elixir source written to the gating test file.
  # It controls whether the declared entry symbol appears in the source.
  defp build_repo(root, gating_test_body) do
    dir = Path.join(root, "repo_d307_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git = fn args -> {_out, 0} = System.cmd("git", args, cd: dir) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@t"])
    git.(["config", "user.name", "t"])

    # --- merge-base commit: minimal project, no production code ---
    File.write!(Path.join(dir, "mix.exs"), minimal_mix_exs())
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))
    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "base"])
    {merge_base, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    merge_base = String.trim(merge_base)

    gating_rel = "test/widget_gate_test.exs"

    # --- head commit: production module + gating test ---
    File.write!(Path.join(dir, "lib/widget.ex"), """
    defmodule Widget do
      def value, do: 42
    end
    """)

    File.write!(Path.join(dir, gating_rel), gating_test_body)
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

  defp minimal_mix_exs do
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

  # A policy_pin that injects deterministic oracle results (no real LLM) and
  # declares the entry symbol that must appear in the gating test source.
  # The `entry_symbol` key is the D-307 mechanizable-narrowing seam.
  defp policy_pin_with_symbol(entry_symbol) do
    %{
      gate_manifest: [:mutation, :critic, :reviewer],
      gate_concurrency: 4,
      gate_timeout: 60_000,
      oracle: %{critic: :pass, reviewer: :pass},
      entry_symbol: entry_symbol
    }
  end

  defp build_request(repo, writer, policy_pin) do
    struct!(@request_mod, %{
      unit: "pr-d307-test",
      diff: diff_for(repo),
      frozen_paths: repo.gating_paths,
      policy_pin: policy_pin,
      workspace: repo.dir,
      merge_base: repo.merge_base,
      hash: repo.head,
      run: "run-1",
      ledger: writer
    })
  end

  # ---------------------------------------------------------------------------
  # D-307 / AC-9 — declared entry symbol ABSENT from gating test → :fail
  #
  # This is the load-bearing assertion: when `policy_pin.entry_symbol` names a
  # symbol (here "Tau.CLI.main") that does NOT appear anywhere in the gating
  # test source, Gate.run/1 MUST return a :fail verdict (the mechanizable
  # narrowing of D-307).
  #
  # With current production code (no entry-symbol-presence half in Gate.run/1),
  # run/1 returns :pass on a genuine discriminating gating test — so this
  # assertion fails. That is the correct fail-before state.
  # ---------------------------------------------------------------------------

  describe "D-307 / AC-9: declared entry symbol absent from gating test → :fail" do
    @tag :d_307
    @tag :ac_9
    test "D-307: Gate.run/1 returns :fail when the entry symbol is absent from the gating test source",
         %{writer: writer, fixture_root: root} do
      # A genuine gating test that discriminates (Widget.value/0 depends on
      # production), BUT does NOT mention the declared entry symbol "Tau.CLI.main".
      gating_test_body = """
      defmodule WidgetGateTest do
        use ExUnit.Case

        @tag :gating
        test "AC-9: widget value is 42" do
          assert Widget.value() == 42
        end
      end
      """

      repo = build_repo(root, gating_test_body)

      # Declare "Tau.CLI.main" as the required user-entry symbol.
      # The gating test above does NOT mention it — the engine-owned
      # entry-symbol-presence check (D-307 narrowing) MUST fail the gate.
      pin = policy_pin_with_symbol("Tau.CLI.main")
      req = build_request(repo, writer, pin)

      verdict = @gate.run(req)

      assert verdict.status == :fail,
             "D-307 / AC-9: when `policy_pin.entry_symbol` declares \"Tau.CLI.main\" " <>
               "and that symbol does NOT appear in the gating test source, Gate.run/1 " <>
               "MUST return a :fail verdict — the engine-owned entry-symbol-presence " <>
               "check (the mechanizable narrowing of INV-8) is absent. " <>
               "Got: #{inspect(verdict)}"
    end
  end

  # ---------------------------------------------------------------------------
  # D-307 / AC-9 — declared entry symbol PRESENT in gating test → not a :fail cause
  #
  # Positive control: when the gating test source DOES contain the declared
  # entry symbol (even if only as a reference — "appears" is the contract, not
  # "is the exercised path"), the entry-symbol check MUST NOT cause the gate to
  # fail on that account. The overall verdict for a genuine discriminating test
  # with a present symbol must be :pass.
  # ---------------------------------------------------------------------------

  describe "D-307 / AC-9: declared entry symbol PRESENT in gating test → :pass" do
    @tag :d_307
    @tag :ac_9
    test "D-307: Gate.run/1 passes when the entry symbol is present in the gating test source",
         %{writer: writer, fixture_root: root} do
      # A genuine gating test that:
      #   1. discriminates on production (fails when Widget is reverted)
      #   2. mentions the declared entry symbol "Tau.CLI.main" in its source
      #      (even as a comment — "appears in source" is the D-307 narrowing).
      gating_test_body = """
      # Entry point under test: Tau.CLI.main
      defmodule WidgetGateTest do
        use ExUnit.Case

        @tag :gating
        test "AC-9: widget value is 42 (entry point Tau.CLI.main)" do
          assert Widget.value() == 42
        end
      end
      """

      repo = build_repo(root, gating_test_body)

      pin = policy_pin_with_symbol("Tau.CLI.main")
      req = build_request(repo, writer, pin)

      verdict = @gate.run(req)

      # When the entry symbol is present, the entry-symbol check passes.
      # A genuine discriminating gating test with all oracle halves passing
      # should yield a :pass verdict overall.
      assert verdict.status == :pass,
             "D-307 / AC-9: when the gating test source contains the declared entry " <>
               "symbol (\"Tau.CLI.main\"), Gate.run/1 MUST NOT fail on that account. " <>
               "A genuine discriminating gating test with the symbol present should " <>
               "yield :pass. Got: #{inspect(verdict)}"
    end
  end
end

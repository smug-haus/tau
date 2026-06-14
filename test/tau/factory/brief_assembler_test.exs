defmodule Tau.Factory.BriefAssemblerTest do
  @moduledoc """
  Gating tests for D-372 / D-373 — brief/issue → prompt assembler
  (SPEC-FACTORY-CORE §6 / §4 B10 amendment, PR #508, issue #489).

  ## What these tests enforce

  **D-372 — Brief assembly is complete over its declared inputs.**
  `Tau.Factory.BriefAssembler.assemble/2` composes `task.prompt` from all
  present input fields (issue body, declared `ConflictCheck.scope()`,
  gating-test paths, SPEC/AC/D-NNN refs), each appearing under a distinct
  labelled section. The `docs/arch/04-software-architecture` pointer section
  is mandatory and non-empty — present even when no optional input is supplied.
  `Tau.Factory.Supervisor.to_unit_work_item/1` sets `:brief` to the assembled
  prompt, not the bare issue title.

  **D-373 — Assembly is an injected pure seam that degrades, never crashes.**
  The injected `:assemble_fun :: (input -> String.t())` (defaulting to the D-372
  heuristic template) is honoured when supplied. The default assembler is pure
  and network-free. Absent optional keys degrade to explicit `(none declared)`
  placeholders without raising; output is always a non-empty `String.t()`.

  Each test exercises the REAL `Tau.Factory.BriefAssembler.assemble/2` API or
  the REAL `Tau.Factory.Supervisor.to_unit_work_item/1` invocation path — no
  hand-built bypasses. Tests MUST FAIL against the pre-D-372 implementation
  (module does not exist → `UndefinedFunctionError`; supervisor still uses bare
  title → assertion failure).
  """

  use ExUnit.Case, async: true

  alias Tau.Factory.BriefAssembler
  alias Tau.Factory.IssueSelector
  alias Tau.Factory.Supervisor, as: FactorySupervisor

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Minimal valid issue_map (the keys the §4 B10 --json projection supplies).
  defp issue(number, title, opts \\ []) do
    %{
      "number" => number,
      "title" => title,
      "body" => Keyword.get(opts, :body, ""),
      "labels" => Keyword.get(opts, :labels, [])
    }
  end

  # Minimal valid declared_scope (a ConflictCheck.scope() map).
  defp empty_scope do
    %{
      deps: [],
      files: MapSet.new(),
      codepoints: MapSet.new(),
      specs: MapSet.new(),
      resources: MapSet.new()
    }
  end

  # ---------------------------------------------------------------------------
  # D-372(a): full input → every field appears labelled in the prompt
  #
  # SPEC: "every input field present in `input` is consumed — appears, labelled,
  # in the assembled prompt ... the issue body, the declared scope, the
  # gating-test paths, the SPEC/AC/D-NNN refs, and the arch pointers each
  # occupy a distinct labelled section." (§4 B10 / D-372)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_372
  test "D-372(a): assemble/2 with all fields present returns a prompt containing each under its labelled section" do
    input = %{
      issue:
        issue(489, "A2: brief/issue→prompt assembler",
          body: "Implement the assembler for real agents."
        ),
      declared_scope: %{
        deps: [],
        files: MapSet.new(["lib/tau/factory/brief_assembler.ex"]),
        codepoints: MapSet.new(),
        specs: MapSet.new(["SPEC-FACTORY-CORE"]),
        resources: MapSet.new()
      },
      gating_test_paths: ["test/tau/factory/brief_assembler_test.exs"],
      spec_refs: ["SPEC-FACTORY-CORE", "AC-14", "D-372", "D-373"],
      arch_pointers: ["docs/arch/04-software-architecture/control-plane.md"]
    }

    result = BriefAssembler.assemble(input, [])

    assert is_binary(result),
           "D-372(a): assemble/2 must return a String.t(); got: #{inspect(result)}"

    assert result != "",
           "D-372(a): assemble/2 must return a non-empty String.t()"

    # Issue body must appear under a labelled section.
    assert result =~ "Implement the assembler for real agents.",
           "D-372(a): the issue body must appear in the assembled prompt"

    # Declared scope must appear under its own labelled section (at minimum the
    # file cited in the scope should surface).
    assert result =~ "lib/tau/factory/brief_assembler.ex",
           "D-372(a): declared scope content must appear in the assembled prompt"

    # Gating-test paths must appear under their labelled section.
    assert result =~ "test/tau/factory/brief_assembler_test.exs",
           "D-372(a): gating_test_paths must appear in the assembled prompt"

    # SPEC/AC/D-NNN refs must appear under their labelled section.
    assert result =~ "D-372",
           "D-372(a): spec_refs (D-372) must appear in the assembled prompt"

    # Arch pointers must appear under their labelled section.
    assert result =~ "docs/arch/04-software-architecture/control-plane.md",
           "D-372(a): arch_pointers must appear in the assembled prompt"
  end

  # ---------------------------------------------------------------------------
  # D-372(b): arch-pointer section is mandatory — present even with only required keys
  #
  # SPEC: "The arch-pointer section is mandatory and non-empty (it carries at
  # least the `docs/arch/04-software-architecture/` root), discharging
  # `feedback_brief_implementers_with_arch`." (§4 B10 / D-372)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_372
  test "D-372(b): assemble/2 with only required keys still includes the docs/arch/04-software-architecture pointer section" do
    # Supply only the two required keys — no optional keys.
    input = %{
      issue: issue(489, "Minimal required-only issue"),
      declared_scope: empty_scope()
    }

    result = BriefAssembler.assemble(input, [])

    assert is_binary(result),
           "D-372(b): assemble/2 must return a String.t(); got: #{inspect(result)}"

    assert result != "",
           "D-372(b): assemble/2 must return a non-empty String.t() even with only required keys"

    # The arch-pointer section is MANDATORY even when no arch_pointers key is
    # supplied in input.
    assert result =~ "docs/arch/04-software-architecture",
           "D-372(b): the assembled prompt MUST include a docs/arch/04-software-architecture " <>
             "pointer section even when no optional inputs are supplied; " <>
             "got prompt: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-372(c): Supervisor.to_unit_work_item/1 sets :brief to the assembled prompt
  #
  # SPEC: "Tau.Factory.Supervisor.to_unit_work_item/1 is the single assembly
  # site: it replaces `brief: title` with
  # `brief: BriefAssembler.assemble(%{issue: issue, declared_scope: scope, …})`."
  # (§4 B10 / D-372 invocation point)
  #
  # The invocation point is exercised via the REAL public path:
  # Supervisor.start_link/1 (enabled: true) wraps to_unit_work_item/1 inside
  # wrapped_drive_fun, so we inject a sentinel drive_fun that captures the
  # work_item it receives, deliver one open issue via gh_fun, and inspect :brief.
  #
  # PRE-IMPL FAILURE: the current wrapped_drive_fun calls to_unit_work_item/1
  # which sets `brief: title` (the bare issue title). This test asserts that
  # :brief != the bare title and contains the mandatory arch pointer. When
  # BriefAssembler does not exist the Supervisor fails to start (or compile),
  # so the start_supervised! call itself fails before the drive_fun is reached.
  # Either way the test fails — compile error or assertion failure.
  # ---------------------------------------------------------------------------
  @tag :d_372
  @tag :capture_log
  test "D-372(c): Supervisor.to_unit_work_item/1 sets :brief to the assembled prompt, not the bare title" do
    # Throwaway git repo (mirrors merge_result_pubsub_test.exs pattern).
    repo_dir = Briefly.create!(type: :directory)
    git = fn args -> System.cmd("git", args, cd: repo_dir, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "test@tau.test"])
    {_, 0} = git.(["config", "user.name", "Tau Test"])
    File.write!(Path.join(repo_dir, "README"), "initial\n")
    {_, 0} = git.(["add", "README"])
    {_, 0} = git.(["commit", "-m", "initial commit"])

    db_path = Briefly.create!(extname: ".db")
    sup_name = :"brief_asm_d372c_#{System.unique_integer([:positive])}"

    # Shared cell to capture the work_item passed to our sentinel drive_fun.
    capture = :ets.new(:d372c_capture, [:public, :set])

    # An open issue with a known title and body.
    bare_title = "A2: brief/issue→prompt assembler"

    issue_map =
      issue(489, bare_title, body: "Build BriefAssembler for real agents. References D-372.")

    gh_fun = fn _milestone -> {:ok, [issue_map]} end

    # Sentinel drive_fun: captures the work_item then returns :ok to satisfy
    # the Coordinator's drive_fun contract (§4 B10).
    sentinel_drive_fun = fn work_item, _deps ->
      :ets.insert(capture, {:work_item, work_item})
      # Prevent the Coordinator from trying to start a real Unit (no agent_bin
      # in this test scope — just return a stub pid-ish value).
      spawn(fn -> :ok end)
    end

    _sup_pid =
      start_supervised!(
        {
          FactorySupervisor,
          enabled: true,
          db_path: db_path,
          name: sup_name,
          repo_dir: repo_dir,
          milestone: "m-d372c",
          gh_fun: gh_fun,
          select_fun: &IssueSelector.select/1,
          drive_fun: sentinel_drive_fun
        },
        id: sup_name
      )

    # Give the Coordinator one cycle to call select_fun → drive_fun.
    Process.sleep(300)

    brief =
      case :ets.lookup(capture, :work_item) do
        [{:work_item, work_item}] ->
          Map.get(work_item, :brief, :__missing__)

        [] ->
          :not_captured
      end

    assert is_binary(brief),
           "D-372(c): the work_item :brief delivered to drive_fun must be a String.t(); " <>
             "got: #{inspect(brief)}. " <>
             "If :not_captured, the Coordinator did not call drive_fun — " <>
             "likely BriefAssembler is missing (compile error) or the supervisor " <>
             "does not select the injected issue."

    # The brief must not be the bare title — it must be the assembled prompt.
    refute brief == bare_title,
           "D-372(c): :brief delivered to drive_fun must be the assembled prompt, " <>
             "not the bare issue title #{inspect(bare_title)}; " <>
             "D-372 requires BriefAssembler.assemble/2 be called in to_unit_work_item/1"

    # The assembled prompt must carry the mandatory arch pointer section.
    assert brief =~ "docs/arch/04-software-architecture",
           "D-372(c): the assembled brief must include the docs/arch/04-software-architecture " <>
             "pointer section (D-372 arch-mandatory); got brief: #{inspect(brief)}"
  end

  # ---------------------------------------------------------------------------
  # D-373(a): injected :assemble_fun stub is honoured
  #
  # SPEC: "The injected `:assemble_fun` (D-373) follows the established `*_fun`
  # pattern so a stronger, LLM-assisted prompt author is a *substitution*, not
  # a rewrite ... a stub `:assemble_fun` is honoured." (§4 B10 / D-373)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_373
  test "D-373(a): a stub :assemble_fun injected via opts is honoured — its output becomes the assembled brief" do
    # A sentinel string that cannot be produced by the default heuristic assembler.
    sentinel_output = "SENTINEL_BRIEF_#{System.unique_integer([:positive])}"
    stub_assemble_fun = fn _input -> sentinel_output end

    input = %{
      issue: issue(489, "D-373 stub test"),
      declared_scope: empty_scope()
    }

    result = BriefAssembler.assemble(input, assemble_fun: stub_assemble_fun)

    assert result == sentinel_output,
           "D-373(a): injected :assemble_fun stub output must be returned by assemble/2; " <>
             "expected #{inspect(sentinel_output)}, got: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-373(b): default assembler is pure and deterministic — same input → same output
  #
  # SPEC: "the default is pure and network-free — no LLM call on the assembly
  # path ... assert determinism: same issue → same output." (§4 B10 / D-373)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_373
  test "D-373(b): default assembler is deterministic — identical inputs produce identical output" do
    input = %{
      issue: issue(489, "D-373 determinism check", body: "References D-373."),
      declared_scope: %{
        deps: [],
        files: MapSet.new(["lib/tau/factory/brief_assembler.ex"]),
        codepoints: MapSet.new(),
        specs: MapSet.new(),
        resources: MapSet.new()
      },
      gating_test_paths: ["test/tau/factory/brief_assembler_test.exs"],
      spec_refs: ["D-373"]
    }

    result_1 = BriefAssembler.assemble(input, [])
    result_2 = BriefAssembler.assemble(input, [])

    assert is_binary(result_1),
           "D-373(b): assemble/2 must return a String.t()"

    assert result_1 == result_2,
           "D-373(b): default assembler must be deterministic — same input must produce " <>
             "identical output on repeated calls; " <>
             "first=#{inspect(result_1)}, second=#{inspect(result_2)}"
  end

  # ---------------------------------------------------------------------------
  # D-373(c): partial input (missing optional keys) degrades gracefully — no raise,
  #           "(none declared)" placeholders in place of missing sections
  #
  # SPEC: "An absent optional input degrades to an explicit '(none declared)'
  # marker in its section, never a crash and never a silently-omitted section."
  # (§4 B10 / D-373)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_373
  test "D-373(c): assemble/2 with only required keys degrades missing optional fields to (none declared) placeholders without raising" do
    # Only the two required keys — no gating_test_paths, spec_refs, arch_pointers.
    input = %{
      issue: issue(489, "Partial input degradation test"),
      declared_scope: empty_scope()
    }

    # Must not raise.
    result =
      try do
        BriefAssembler.assemble(input, [])
      rescue
        err ->
          flunk(
            "D-373(c): assemble/2 must NOT raise on partial input; " <>
              "got exception: #{inspect(err)}"
          )
      end

    assert is_binary(result),
           "D-373(c): assemble/2 must return a String.t() on partial input; got: #{inspect(result)}"

    # The "(none declared)" marker must appear — indicating graceful degradation
    # rather than silent omission of expected sections.
    assert result =~ "(none declared)",
           "D-373(c): absent optional fields must degrade to '(none declared)' placeholder " <>
             "sections in the assembled prompt; got prompt: #{inspect(result)}"
  end

  # ---------------------------------------------------------------------------
  # D-373(d): output is always a non-empty String.t()
  #
  # SPEC: "for any non-empty issue (carrying 'number'/'title') the assembler
  # returns a non-empty String.t(), never raising on partial input and never
  # returning ''." (§4 B10 / D-373)
  #
  # PRE-IMPL FAILURE: BriefAssembler does not exist → UndefinedFunctionError.
  # ---------------------------------------------------------------------------
  @tag :d_373
  test "D-373(d): assemble/2 always returns a non-empty String.t() for any non-empty issue — never raises, never returns empty string" do
    minimal_inputs = [
      # Required-only
      %{
        issue: issue(1, "Minimal issue"),
        declared_scope: empty_scope()
      },
      # Empty body
      %{
        issue: issue(2, "Empty body issue", body: ""),
        declared_scope: empty_scope()
      },
      # All optional keys explicitly empty
      %{
        issue: issue(3, "All optional empty"),
        declared_scope: empty_scope(),
        gating_test_paths: [],
        spec_refs: [],
        arch_pointers: []
      }
    ]

    for input <- minimal_inputs do
      result =
        try do
          BriefAssembler.assemble(input, [])
        rescue
          err ->
            flunk(
              "D-373(d): assemble/2 must not raise for input=#{inspect(input)}; " <>
                "got: #{inspect(err)}"
            )
        end

      assert is_binary(result),
             "D-373(d): assemble/2 must return a String.t() for input=#{inspect(input)}; " <>
               "got: #{inspect(result)}"

      assert result != "",
             "D-373(d): assemble/2 must never return an empty string; " <>
               "input=#{inspect(input)}"
    end
  end
end

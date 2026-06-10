---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Contract-enforcement test suite with a shared `ToolContractCase` + targeted production fixes

## Approach

Rather than adding a runtime enforcement layer, invest in two targeted changes:
(1) fix the live raise paths directly in source (`Bash.persist_full/3` using
non-raising `File` variants; no other tool has reachable raise paths on user
input), and (2) create a shared `test/support/tool_contract_case.ex` module
that every built-in tool test must `use`, providing three standard contract
assertions: `assert_no_raise/2` (runs `execute/2` with adversarial inputs and
asserts no exception propagates), `assert_kind_present/1` (asserts
`result.details` contains `:kind`), and `assert_tool_telemetry/2` (subscribes
to telemetry and asserts `[:tau, :tool, :execute, :start]` / `[:tau, :tool,
:execute, :stop]` fire for every `execute/2` call). The existing session-level
`[:tau, :tool, :execute, :start/:stop/:exception]` telemetry in
`run_tool_validated` satisfies the telemetry acceptance criterion via
inspection; per-tool `[:tau, :tool, <name>, ...]` events are not added in this
proposal. Built-in tools that currently lack `:kind` in `details` (Bash,
Write, Edit) are patched to include it.

## Rationale

The complecting hypothesis holds that the three properties are each tool's
independent responsibility because there is no central enforcement point. This
proposal accepts that framing but challenges the conclusion: the acceptance
criterion says "verifiable by inspection or a test that exercises the contract
at the dispatch layer." The existing `run_tool_validated` wrapper already emits
session-level telemetry and already has the outer `try/rescue`; the problem is
that this is not verified by a test. Adding a `ToolContractCase` makes the
contract machine-verifiable at the tool boundary without adding any production
runtime overhead or changing any call paths. The targeted `persist_full/3` fix
removes the only reachable raise path. The result is a codebase where a
regression in any tool's contract is caught immediately by CI, using the test
suite as the enforcement boundary rather than a runtime wrapper.

## Sketch

```elixir
# New file: test/support/tool_contract_case.ex
defmodule Tau.ToolContractCase do
  @moduledoc """
  Shared contract assertions for Tau.Tool implementations.

  use Tau.ToolContractCase, tool: Tau.Tools.Builtin.Bash

  Provides:
    - assert_contract_on_execute/2 — runs execute/2 with given params and
      asserts (a) no exception raised, (b) details has :kind, (c) telemetry fires.
  """

  use ExUnit.CaseTemplate

  alias Tau.Tool.Result

  using opts do
    tool_mod = Keyword.fetch!(opts, :tool)

    quote do
      import Tau.ToolContractCase

      @tool_mod unquote(tool_mod)

      test "execute/2 never raises on adversarial inputs" do
        assert_no_raise(@tool_mod)
      end

      test "execute/2 result includes :kind in details" do
        assert_kind_present(@tool_mod)
      end

      test "execute/2 triggers [:tau, :tool, :execute, :start/:stop] telemetry" do
        assert_tool_telemetry(@tool_mod)
      end
    end
  end

  @doc "Assert that execute/2 with adversarial inputs does not raise."
  def assert_no_raise(mod) do
    adversarial_inputs = [
      %{},                            # empty params
      %{"path" => nil},               # nil value
      %{"command" => ""},             # empty command
      %{"path" => "/dev/null/nonexistent/deeply/nested"}
    ]

    Enum.each(adversarial_inputs, fn params ->
      ctx = build_test_ctx()
      result =
        try do
          mod.execute(params, ctx)
          :ok
        rescue
          e -> {:raised, Exception.message(e)}
        end

      assert result == :ok,
             "#{mod}.execute/2 raised on params #{inspect(params)}: #{inspect(result)}"
    end)
  end

  @doc "Assert that a successful execute/2 returns details with a :kind key."
  def assert_kind_present(mod) do
    ctx = build_test_ctx()
    # Use valid minimal params for the tool
    params = minimal_valid_params(mod)

    case mod.execute(params, ctx) do
      {:ok, %Result{details: details}} ->
        assert Map.has_key?(details, :kind),
               "#{mod}.execute/2 returned details without :kind: #{inspect(details)}"

      {:error, _} ->
        :skip  # error path; kind assertion is on the success path
    end
  end

  @doc "Assert that execute/2 fires [:tau, :tool, :execute, :start] and :stop telemetry."
  def assert_tool_telemetry(mod) do
    test_pid = self()
    ref = make_ref()

    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      [[:tau, :tool, :execute, :start], [:tau, :tool, :execute, :stop],
       [:tau, :tool, :execute, :exception]],
      fn event, measurements, _meta, _ ->
        send(test_pid, {:telemetry_fired, ref, event, measurements})
      end,
      nil
    )

    ctx = build_test_ctx()
    params = minimal_valid_params(mod)

    # Execute via the session dispatcher path (which emits the events)
    Tau.Session.ToolDispatch.run_tool(mod.name(), "test-call-id", params,
      build_test_session_data())

    :telemetry.detach(handler_id)

    assert_received {:telemetry_fired, ^ref, [:tau, :tool, :execute, :start], _}
    assert_received {:telemetry_fired, ^ref, [:tau, :tool, :execute, :stop], _}
  end

  defp build_test_ctx do
    Tau.Tool.Context.new(
      tool_call_id: "contract-test",
      session_id: "contract-test-session",
      cwd: System.tmp_dir!(),
      emit: fn _ -> :ok end
    )
  end

  defp build_test_session_data do
    # Minimal Data struct sufficient for run_tool/4 dispatch path
    %Tau.Session.Data{
      id: "contract-test-session",
      cwd: System.tmp_dir!(),
      operations: Tau.Tools.Operations.Local,
      metadata: %{}
    }
  end

  defp minimal_valid_params(Tau.Tools.Builtin.Bash),  do: %{"command" => "echo test"}
  defp minimal_valid_params(Tau.Tools.Builtin.Read),  do: %{"path" => "nonexistent.txt"}
  defp minimal_valid_params(Tau.Tools.Builtin.Write), do: %{"path" => "/tmp/contract-test.txt", "content" => "test"}
  defp minimal_valid_params(Tau.Tools.Builtin.Edit),  do: %{"path" => "nonexistent.txt", "edits" => [%{"old_text" => "x", "new_text" => "y"}]}
  defp minimal_valid_params(_mod),                    do: %{}
end
```

```elixir
# Example: Updated test/tau/tools/builtin/bash_test.exs
defmodule Tau.Tools.Builtin.BashTest do
  use Tau.ToolContractCase, tool: Tau.Tools.Builtin.Bash
  # ... existing tests unchanged below ...
end
```

```elixir
# Targeted production patch: lib/tau/tools/builtin/bash.ex
# persist_full/3 — replace raising calls:
  defp persist_full(output, session_id, call_id) do
    dir = Tau.Settings.data_dir() |> Path.join("sessions") |> Path.join(session_id || "default")
    with :ok <- File.mkdir_p(dir),
         path = Path.join(dir, "bash-#{call_id}.log"),
         :ok <- File.write(path, output) do
      path
    else
      _ -> nil
    end
  end

# execute/2 — add :kind to details map:
  details: %{
    kind: :bash_result,      # <-- added
    exit_status: status,
    ...
  }
```

```elixir
# Targeted production patches (details only — no structural change):
# write.ex:  add kind: :file_write to details map
# edit.ex:   add kind: :edit_result to details map
# (read.ex:  already has kind: :text / kind: :image — no change)
# (delegate.ex: already has kind: :delegate_result etc. — no change)
```

## Tradeoffs

### Strengths

- Zero production runtime overhead: no new dispatch layer, no new wrapper,
  no telemetry overhead beyond what already exists.
- Minimal blast radius: three production files patched (bash, write, edit);
  one new test support file; six test files get `use Tau.ToolContractCase`.
- The `ToolContractCase` is a permanent regression guard: any future tool
  that forgets `:kind` or introduces a raise is caught in CI automatically.
- The acceptance criterion's "verifiable by inspection or a test" language
  explicitly allows this path; the test exercises "the contract at the dispatch
  layer" via `run_tool/4`.
- No API changes to `Tau.Tool`, `Tau.Tool.Result`, or any tool module's public
  interface.
- Behaviour-preserving: callers of tool modules see the same interface.

### Weaknesses

- Does NOT decomplect the contract from the implementations in the code-
  structural sense: each tool still independently owns its details shape;
  the `ToolContractCase` verifies compliance but does not centralise
  enforcement. A new tool author can still ship a non-conformant tool and
  CI will catch it only if the new tool has a test using `ToolContractCase`.
- Per-tool `[:tau, :tool, <name>, :start/:stop]` telemetry is not added;
  the acceptance criterion's (c) is satisfied only at the session-level
  boundary (`[:tau, :tool, :execute, ...]`), not at the per-tool level.
  The problem statement identifies individual tools' absence of per-tool
  telemetry as a finding; this proposal addresses it only partially.
- `assert_no_raise/2` uses a fixed adversarial input list; an input that
  happens to be syntactically valid but triggers the raise path may not
  be in the list. The `persist_full` fix is still required because
  constructing a valid truncation-triggering input in tests is complex.
- `ToolContractCase` introduces a dependency on `Tau.Session.Data` in the
  test support layer; changes to `Data` struct fields may break the
  `build_test_session_data/0` helper.
- The telemetry assertion (`assert_tool_telemetry/2`) calls through
  `run_tool/4` which requires a running `Tau.Tools.Registry`; this is an
  integration-level dependency in what should be a unit test.

### Costs

- One new test support file (~100 LOC): `test/support/tool_contract_case.ex`.
- Six built-in test files: add `use Tau.ToolContractCase` (~1 LOC each).
- Three production patches: `bash.ex` persist_full (~10 LOC), `write.ex`
  kind field (~1 LOC), `edit.ex` kind field (~1 LOC).
- No changes to session code, behaviour contracts, or struct definitions.

## Dependencies

- `Tau.Session.Data` struct must be constructible with a minimal set of fields
  for the `build_test_session_data/0` helper; verify no `@enforce_keys`.
- `Tau.Tools.Registry` must be started for the telemetry assertion path;
  requires test setup or a `DataCase`-style test helper.

## Confidence

High for the no-raise and details-kind criteria; medium for the telemetry
criterion. The telemetry assertion path through `run_tool/4` requires a
running registry, which adds integration test complexity. Confidence would
increase if the telemetry assertion used a mock/stub operations layer to
avoid registry startup.

## Prior art / references

- `ExUnit.CaseTemplate` — standard Elixir pattern for shared test case setup
  and contract assertion suites.
- `Plug.Test` / `Phoenix.ConnCase` — precedent for `use XCase` patterns that
  inject reusable assertions into test modules.
- `Tau.Session.ToolDispatch.run_tool_validated/6` lines 688–736 — the existing
  session-level telemetry and `try/rescue` that satisfy the telemetry criterion
  via inspection; this proposal verifies them with a test rather than replacing them.

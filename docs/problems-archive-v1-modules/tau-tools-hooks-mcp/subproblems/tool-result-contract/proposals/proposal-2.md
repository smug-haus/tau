---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Typed `Result.Details` structs with a behaviour callback

## Approach

Replace the untyped `details: map()` field in `Tau.Tool.Result` with a typed
union: define one struct per tool family (e.g. `Tau.Tool.Result.Details.Bash`,
`Tau.Tool.Result.Details.File`, `Tau.Tool.Result.Details.Edit`,
`Tau.Tool.Result.Details.Image`, `Tau.Tool.Result.Details.Delegate`,
`Tau.Tool.Result.Details.Error`) each carrying a mandatory `:kind` atom literal
in their `@enforce_keys`. Add a new optional callback
`details_struct() :: module()` to the `Tau.Tool` behaviour so the dispatcher
can verify at registration time that the module names a known details struct.
Update `Result.t()` so `details` is typed as `Tau.Tool.Result.Details.t()`
(a union type). Fix `Bash.persist_full/3` to use the non-raising `File`
variants and populate `%Details.Bash{}` instead of a bare map. All six built-in
tools are updated to construct their appropriate struct. The existing `details:
map()` in `ToolResult` (the session-side wire type) is left unchanged for now;
the conversion happens in `run_tool_validated` when building `ToolResult` from
`Result`.

## Rationale

The root cause of silent shape drift is that `details` is typed `map()` at both
the definition site and the usage sites; no tool author or Dialyzer check ever
catches a missing `:kind`. Introducing struct types makes the contract visible
at write time (compiler/Dialyzer enforces `@enforce_keys`) and at registration
time (`details_struct()` callback + a guard in `Tau.Tool.register/1`). This
decomplects the details schema from each tool's independent map construction:
every tool must declare its details type, and every struct definition enforces
`:kind`. Telemetry coverage remains a behavioural property, addressed by the
existing `run_tool_validated` wrapper (which already has `[:tau, :tool,
:execute, :start/:stop/:exception]`) rather than being embedded in the struct.

## Sketch

```elixir
# New file: lib/tau/tool/result/details.ex
defmodule Tau.Tool.Result.Details do
  @type t ::
    Details.Bash.t() | Details.File.t() | Details.Edit.t() |
    Details.Image.t() | Details.Delegate.t() | Details.Error.t() | map()

  defmodule Bash do
    @enforce_keys [:kind, :exit_status, :duration_ms, :command]
    defstruct [
      :kind,            # always :bash_result
      :exit_status,
      :duration_ms,
      :command,
      :stderr_bytes,
      truncated?: false,
      full_output_path: nil
    ]
    @type t :: %__MODULE__{kind: :bash_result, exit_status: integer(), duration_ms: integer(),
                            command: String.t(), stderr_bytes: non_neg_integer() | nil,
                            truncated?: boolean(), full_output_path: String.t() | nil}
  end

  defmodule File do
    @enforce_keys [:kind, :path, :bytes]
    defstruct [:kind, :path, :bytes]          # kind: :file_write | :file_error
    @type t :: %__MODULE__{kind: :file_write | :file_error, path: String.t(), bytes: non_neg_integer()}
  end

  defmodule Edit do
    @enforce_keys [:kind, :path, :edit_count]
    defstruct [:kind, :path, :edit_count, :diff, :first_changed_line]
    @type t :: %__MODULE__{kind: :edit_result, path: String.t(), edit_count: non_neg_integer(),
                            diff: String.t() | nil, first_changed_line: non_neg_integer() | nil}
  end

  defmodule Image do
    @enforce_keys [:kind, :bytes, :media_type]
    defstruct [:kind, :bytes, :media_type]
    @type t :: %__MODULE__{kind: :image, bytes: non_neg_integer(), media_type: String.t()}
  end

  defmodule Delegate do
    @enforce_keys [:kind, :agent, :adapter]
    defstruct [:kind, :agent, :adapter, :workspace, :events_count,
               :tool_uses, :tool_results, :file_edits, :cost,
               :exit_status, :final_message]
    @type t :: %__MODULE__{kind: :delegate_result | :delegate_timeout |
                            :delegate_cancelled | :delegate_error | :delegate_nonzero_exit,
                            agent: String.t(), adapter: module()}
  end

  defmodule Error do
    @enforce_keys [:kind]
    defstruct [:kind, :exception, :reason, :command, :timeout_ms, :agent, :depth, :max_depth]
    @type t :: %__MODULE__{kind: :raised_exception | :bash_timeout | :unknown_agent |
                            :depth_exceeded | :workspace_error | :dispatcher_start_failed |
                            :unclassified}
  end
end
```

```elixir
# Updated lib/tau/tool/result.ex
defmodule Tau.Tool.Result do
  alias Tau.Tool.Result.Details

  defstruct content: "", details: %Details.Error{kind: :unclassified},
            terminate?: false, is_error: false

  @type t :: %__MODULE__{
    content: String.t() | [map()],
    details: Details.t(),
    terminate?: boolean(),
    is_error: boolean()
  }
end
```

```elixir
# Updated Tau.Tool behaviour — new optional callback
@callback details_struct() :: module()
@optional_callbacks [execution_mode: 0, streams_updates?: 0, details_struct: 0]

# Updated Tau.Tool.register/1 — warn on missing details_struct
def register(mod) when is_atom(mod) do
  if function_exported?(mod, :details_struct, 0) do
    :ok
  else
    require Logger
    Logger.warning("Tool #{mod} does not implement details_struct/0; details shape unverified")
  end
  Registry.register(Tau.Tools.Registry, mod.name(), mod)
end
```

```elixir
# Example: Updated Bash.execute/2 result construction
{:ok, %Result{
  content: full,
  details: %Details.Bash{
    kind: :bash_result,
    exit_status: status,
    duration_ms: dur,
    command: cmd,
    stderr_bytes: byte_size(err),
    truncated?: truncated?,
    full_output_path: full_path
  },
  is_error: status != 0
}}
```

The `details` field in `Tau.Message.ToolResult` (session wire type) continues
to accept `map()`; `run_tool_validated` converts via `Map.from_struct/1` at the
boundary so downstream consumers need no change.

## Tradeoffs

### Strengths

- Makes the `:kind` contract visible and compile-time-enforced via
  `@enforce_keys`; Dialyzer will flag struct mismatches.
- Decomplects the schema contract from tool implementations by moving it to the
  type system; tools cannot accidentally omit `:kind` without a compile error.
- The `details_struct/0` optional callback enables registration-time auditing
  without breaking existing tools immediately (warning-only mode).
- Self-documenting: callers can pattern-match on struct type rather than
  checking the `:kind` atom, which is more robust.
- Enables Dialyzer coverage across the full pipeline from `execute/2` to
  `ToolResult`.

### Weaknesses

- API-breaking: all six built-in tools must be updated simultaneously; any
  external or extension tool that returns bare maps will generate warnings (or
  errors if the guard is hardened to fail-closed).
- `Map.from_struct/1` at the ToolResult boundary loses the struct type
  information for downstream consumers; they still see plain maps in
  `%ToolResult{details: %{}}`.
- New details struct taxonomy may not cover all future tool shapes; unknown
  structs degrade to `%Details.Error{kind: :unclassified}` requiring ongoing
  taxonomy maintenance.
- Telemetry coverage is not enforced by this proposal — it relies on the
  existing session-level `[:tau, :tool, :execute, ...]` events. Per-tool
  `[:tau, :tool, <name>, ...]` telemetry remains non-uniform.
- The `Details.Delegate` struct is large and duplicates fields already in
  `Tau.CodingAgent.Event` structs; maintenance burden is doubled.

### Costs

- Six new struct modules (~100 LOC for `details.ex`).
- Updates to all six built-in tool `execute/2` return sites (~40 LOC delta).
- `Result.t()` type annotation update.
- `Tau.Tool.register/1` update.
- Tests: update all tool unit tests that assert on `details` map shape (~20
  assertion updates); add Dialyzer as a gate if not already running.
- No downstream session changes required (conversion at `run_tool_validated`).

## Dependencies

- Dialyzer in CI (already present per `mix dialyzer` in the project).
- No library additions.
- Coordination with extensions/MCP tool adapter authors if `details_struct/0`
  is ever hardened to fail-closed.

## Confidence

Medium. The struct taxonomy is straightforward and the `@enforce_keys` mechanism
is idiomatic Elixir. Confidence would be higher after verifying Dialyzer
catches `%Details.Bash{kind: nil}` (i.e., that `@enforce_keys` triggers
a Dialyzer warning rather than just a compile error for omission in `new/1`).

## Prior art / references

- `Tau.Tools.Builtin.Delegate.finalize_result/2` — already uses pattern-matched
  `:kind` values; this proposal formalises what Delegate does informally.
- Elixir `@enforce_keys` — compiler-enforced struct field presence.
- Phoenix `%Socket{}` / `%Conn{}` — typed struct pattern used extensively
  in the Elixir ecosystem to enforce field contracts without runtime overhead.
- `Tau.CodingAgent.Event` structs — precedent for struct-per-event-type in
  the same codebase.

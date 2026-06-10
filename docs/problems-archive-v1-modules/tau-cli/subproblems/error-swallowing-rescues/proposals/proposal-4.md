---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Structured exit-code API — lift error signals to the command boundary, removing private helpers entirely

## Approach

This is an API-breaking, behaviour-correcting refactor at the command-handler
layer. The public functions `Tau.CLI.Extensions.list/1`, `reload/1`,
`Tau.CLI.MCP.list/1`, `status/1`, `reload/1` currently assume the callee always
returns data and hard-code exit code 0 on success. This proposal changes their
contract: public functions always call the supervised GenServer directly (no
shim), wrap the entire body in a `try` at the **command boundary** (not the
callee boundary), and return a structured `{exit_code, output}` tuple that the
CLI dispatcher renders. The private `safe_*` helpers are deleted entirely. Error
output format follows a structured schema: `%{ok: false, error: "...", code: N}`
for `--json` and a consistent `"<command> failed: <reason>"` line to stderr for
plain text.

## Rationale

The complecting hypothesis is that data retrieval is woven with error reporting.
Proposals 1–3 decouple them by adjusting the fetch side. This proposal
decouples from the other direction: the command handlers themselves become the
error boundary, explicitly responsible for mapping any failure to an exit code
and error output, regardless of cause. This is an **interface change** —
changing what the public functions return — rather than a rescue/catch placement
change. The key insight is that a CLI command is already an error boundary
(every shell command is); making that explicit in the Elixir type signature
aligns the module's contract with its actual responsibility. The private
`safe_*` helpers vanish because no intermediate translation layer is needed
when the outer boundary handles all failures uniformly.

## Sketch

**New return type for command handlers:**

```elixir
@type command_result :: {exit_code :: non_neg_integer(), output :: iodata()}
```

**Updated `lib/tau/cli/extensions.ex`:**

```elixir
defmodule Tau.CLI.Extensions do
  @type command_result :: {non_neg_integer(), iodata()}

  @spec list(opts()) :: command_result()
  def list(opts \\ []) do
    try do
      entries = Tau.Extensions.Loader.list()
      {0, format_list(entries, opts)}
    catch
      :exit, reason ->
        msg = format_process_error("extensions list", reason, opts)
        {1, {:stderr, msg}}
    end
  end

  @spec reload(opts()) :: command_result()
  def reload(opts \\ []) do
    try do
      case Tau.Extensions.Loader.reload_all() do
        :ok ->
          {0, format_reload_ok(opts)}
        {:error, reason} ->
          {2, {:stderr, format_error("extensions reload", reason, opts)}}
      end
    catch
      :exit, reason ->
        {1, {:stderr, format_process_error("extensions reload", reason, opts)}}
    end
  end

  defp format_process_error(cmd, {:noproc, _}, _opts),
    do: "#{cmd}: subsystem process is not running\n"
  defp format_process_error(cmd, reason, _opts),
    do: "#{cmd}: process exit: #{inspect(reason)}\n"

  defp format_error(cmd, reason, _opts),
    do: "#{cmd} failed: #{inspect(reason)}\n"

  # No safe_list/0, no safe_reload/0
end
```

**Dispatcher update in `lib/tau/cli.ex`:**

Current call pattern (assumed):
```elixir
Tau.CLI.Extensions.list(opts)   # returns exit code integer
```

Updated call pattern:
```elixir
{code, output} = Tau.CLI.Extensions.list(opts)
emit(output)
code
```

Where `emit/1` dispatches `{:stderr, text}` to `IO.puts(:stderr, text)` and
`iodata` directly to `IO.puts/1`.

**JSON shape on error:**

```elixir
# --json path in format_process_error when opts[:json]
Jason.encode!(%{ok: false, error: "subsystem process is not running", code: 1})
```

**File changes:**
- `lib/tau/cli/extensions.ex`: delete `safe_list/0`, `safe_reload/0`; update
  `list/1`, `reload/1` specs to return `command_result()`; add `format_*`
  private helpers.
- `lib/tau/cli/mcp.ex`: same pattern.
- `lib/tau/cli.ex`: update dispatch call sites to destructure `{code, output}`
  and call `emit/1`.

## Tradeoffs

### Strengths

- Eliminates the private-helper indirection layer entirely: zero `safe_*`
  functions, zero wildcard rescue.
- Command handlers are now explicitly the error boundary, which matches the
  conceptual model (a command either succeeds with output or fails with a
  message and exit code).
- The `try/catch :exit` at the command boundary is narrower than a wildcard
  rescue but broader than proposal 2's per-exit-shape catch — it covers all
  process exits while still leaving non-exit exceptions to propagate.
- Structured `command_result()` type makes it trivially testable: assert `{0,
  _}` or `{1, {:stderr, _}}` without inspecting stdout.
- Satisfies acceptance criterion fully: non-zero exit + stderr diagnostic on
  `:noproc`.

### Weaknesses

- **API-breaking**: the public functions currently return `0 | 2` (integers);
  changing to `{exit_code, output}` requires updating every callsite in
  `lib/tau/cli.ex`. If any external consumer calls these functions directly,
  it breaks them too.
- **`try/catch :exit` at the command boundary** is still a catch across a
  process boundary — arguably still a violation of the spirit of OTP NN #7,
  even if narrowed to `:exit` tuples. The difference from the current code is
  the match shape (`:exit, {:noproc, _}` vs `:exit, _`) and the removal of
  wildcard `rescue _`.
- **`emit/1` coupling**: the output-as-iodata approach ties the format to the
  command boundary, making it harder to test the format independently of the
  exit-code logic.
- **Larger diff** than proposals 1 or 2: command handler signatures change,
  dispatcher changes, output format helpers added.
- Does not eliminate `try/catch` entirely (proposal 1 does); it restructures
  and narrows it.

### Costs

- ~60–70 lines changed/added across `extensions.ex`, `mcp.ex`, `cli.ex`.
- Dispatch call sites in `lib/tau/cli.ex` must be updated (count: 4 handler
  call sites for Extensions and MCP).
- Tests asserting integer return values from `list/1` and `reload/1` must be
  updated to assert `{code, _}` tuples.
- JSON contract for `--json --error` paths changes (new `{ok: false, error:
  ..., code: N}` shape); any integration tests or scripts consuming JSON output
  on error must be updated.

## Dependencies

- `lib/tau/cli.ex` dispatch table must be refactored to consume `command_result()`
  tuples — this is the largest callsite change and must land in the same PR.
- No new library dependencies.

## Confidence

medium — the approach is mechanically clear and the sketch is complete. Confidence
is bounded by the API-breaking nature: the exact shape of the dispatch table in
`lib/tau/cli.ex` must be audited before the cost of callsite changes is known.
If dispatch is centralised (one place), cost is low; if distributed, cost rises.

## Prior art / references

- Elixir Escript and Burrito CLI patterns: command handlers returning `{exit_code,
  output}` tuples with a top-level `emit + halt` dispatcher are a documented
  idiom in the Elixir CLI ecosystem (see `Mix.Task` protocol: `run/1` returns
  `nil` but side-effecting commands can return structured results when composed).
- Haskell `ExitCode + String` pattern from `System.Exit`: separates exit code
  and output into a product type, used in CLI libraries like `optparse-applicative`.
- Tau OTP NN #8: "MUST NOT swallow errors. Use tagged tuples or
  `%Tau.Provider.Event.Error{}` stream items." — this proposal converts the
  command handlers to return tagged result tuples, directly satisfying NN #8 at
  the CLI layer.

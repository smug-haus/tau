---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Introduce a Tau.CLI.ProcessQuery behaviour + pre-flight availability check

## Approach

Introduce a `Tau.CLI.ProcessQuery` behaviour with a single callback
`query(command :: atom()) :: {:ok, term()} | {:error, :unavailable | term()}`.
Both `Tau.CLI.Extensions` and `Tau.CLI.MCP` implement the behaviour. The
pre-call check uses `Process.whereis/1` (or the named GenServer's registered
name) to test availability synchronously before issuing the GenServer call.  If
the process is not registered, the handler returns `{:error, :unavailable}`
immediately — no call, no rescue, no catch. Unknown exceptions from registered
but malfunctioning GenServers propagate freely to the top-level CLI handler.

## Rationale

The complecting hypothesis points to data retrieval and error reporting being
woven in the same function. This proposal decomplects along the
**interface axis**: introducing a shared behaviour enforces the tagged-tuple
contract across both modules and places the availability check in a single,
named, testable step. The check (`Process.whereis/1` → nil guard) is a pure
function that does not cross a process boundary by itself, so it does not
violate OTP NN #7. The GenServer call that follows is uncovered by rescue —
unexpected exceptions still crash and propagate. The behaviour also creates an
explicit seam for testing: mock implementations satisfy the behaviour without
requiring a live supervision tree.

## Sketch

**New behaviour (`lib/tau/cli/process_query.ex`):**

```elixir
defmodule Tau.CLI.ProcessQuery do
  @moduledoc """
  Behaviour for CLI modules that query a supervised GenServer.
  Implementors must check process availability before calling.
  """

  @type result :: {:ok, term()} | {:error, :unavailable | term()}

  @callback list() :: result()
  @callback reload() :: result()

  @doc """
  Guards a GenServer call with a pre-flight availability check.
  Returns `{:error, :unavailable}` if the named process is not registered.
  Does NOT rescue or catch; unexpected exceptions propagate.
  """
  @spec guarded_call(name :: atom(), fun :: (() -> term())) :: result()
  def guarded_call(name, fun) do
    case Process.whereis(name) do
      nil -> {:error, :unavailable}
      _pid -> {:ok, fun.()}
    end
  end
end
```

**Updated `lib/tau/cli/extensions.ex`:**

```elixir
defmodule Tau.CLI.Extensions do
  @behaviour Tau.CLI.ProcessQuery

  @loader Tau.Extensions.Loader

  @impl Tau.CLI.ProcessQuery
  def list do
    Tau.CLI.ProcessQuery.guarded_call(@loader, &@loader.list/0)
  end

  @impl Tau.CLI.ProcessQuery
  def reload do
    case Tau.CLI.ProcessQuery.guarded_call(@loader, &@loader.reload_all/0) do
      {:ok, :ok} -> {:ok, :ok}
      {:ok, {:error, r}} -> {:error, r}
      {:error, _} = err -> err
    end
  end
end
```

**Updated public command handlers (still in `Tau.CLI.Extensions`):**

```elixir
@spec list_cmd(opts()) :: 0 | 1
def list_cmd(opts \\ []) do
  case list() do
    {:ok, entries} ->
      render_list(entries, opts)
      0
    {:error, :unavailable} ->
      IO.puts(:stderr, "extensions list: Extensions.Loader is not running")
      1
    {:error, reason} ->
      IO.puts(:stderr, "extensions list failed: #{inspect(reason)}")
      1
  end
end
```

Identical pattern in `lib/tau/cli/mcp.ex` with `Tau.MCP.Reconciler` as the
guarded name.

**File moves / additions:**
- `lib/tau/cli/process_query.ex` — new (behaviour + `guarded_call/2`)
- `lib/tau/cli/extensions.ex` — `@behaviour Tau.CLI.ProcessQuery`; delete
  `safe_list/0` and `safe_reload/0`; public functions renamed
  `list/0` → `list/0` (callback), `list_cmd/1` (command handler).
- `lib/tau/cli/mcp.ex` — same structural change.

## Tradeoffs

### Strengths

- `Process.whereis/1` check does not cross a process boundary via
  message-passing, so it does not violate OTP NN #7 in the way `rescue :exit`
  does.
- The `guarded_call/2` helper is a single, centralised point that both modules
  share — no duplication of the nil-guard pattern.
- Behaviour enforcement ensures any future CLI module querying a supervised
  GenServer follows the same contract.
- Test surface: `list/0` and `reload/0` can be tested with a mock behaviour
  implementation without a live BEAM supervision tree.
- `:unavailable` is a typed, human-readable distinction from other errors,
  satisfying the acceptance criterion's "diagnostically useful error" requirement.

### Weaknesses

- **TOCTOU race**: `Process.whereis/1` returning a pid does not guarantee the
  GenServer is still alive when `fun.()` is called. On a fast restart cycle the
  pre-flight check passes, then the call exits `:noproc`. This exit propagates
  freely (no catch), which is correct OTP behaviour, but the error message will
  not say "unavailable" — it will be an unhandled exit. The acceptance criterion
  is still met (non-zero exit, stderr output from the top-level handler) but the
  message quality degrades on the race path.
- **Renames the public API**: `list/1` (formerly the command handler) is now
  split into `list/0` (the behaviour callback returning a tagged tuple) and
  `list_cmd/1` (the command handler). If `Tau.CLI.main/1` dispatches to
  `Tau.CLI.Extensions.list/1`, it must be updated.
- **New file and new behaviour** add surface area. For a fix to ~30 lines of
  rescue/catch, introducing a behaviour and a new module is higher structural
  cost than the problem demands.
- **Doesn't cover `reload_all/0` returning `{:error, reason}`** on application-
  level failures without double-wrapping — same awkward `{:ok, {:error, _}}`
  shape as proposal 2.

### Costs

- ~50 lines added (new behaviour module + guarded_call + updated impls).
- ~30 lines deleted (safe_list, safe_reload in both files).
- `lib/tau/cli.ex` dispatch callsite must be updated if public function names change.
- Tests must be added for `guarded_call/2` covering: nil pid → `{:error, :unavailable}`;
  live pid → `{:ok, result}`; TOCTOU race path (harder to test deterministically).

## Dependencies

- `Tau.Extensions.Loader` and `Tau.MCP.Reconciler` must use registered names
  (not anonymous pids) for `Process.whereis/1` to work. Verify both are
  registered under their module name in the supervision tree.
- `lib/tau/cli.ex` dispatch table must be audited for callsite signature changes.

## Confidence

medium — `Process.whereis/1` as an availability guard is a well-known Elixir
idiom but the TOCTOU window is real and the structural cost (new behaviour, new
module) is higher than the problem warrants if the acceptance criterion can be
met with a smaller change. Confidence rises to high if the dispatch table audit
confirms clean rename paths and the TOCTOU path's unhandled exit is acceptable.

## Prior art / references

- Elixir `Process.whereis/1` documentation: standard availability check idiom
  before sending to a registered process.
- OTP design principles: pre-flight availability checks (`whereis/1`) are
  explicitly mentioned as the correct pattern when callers need to handle
  "process not running" without `try/catch`.
- Tau OTP NN #2: "Extensibility seams MUST be behaviours" — the
  `ProcessQuery` behaviour enforces the tagged-tuple contract across CLI
  modules rather than relying on convention.

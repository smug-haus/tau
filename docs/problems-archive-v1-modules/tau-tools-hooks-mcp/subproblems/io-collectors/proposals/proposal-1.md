---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Tau.IO.BoundedCollector — shared behaviour-preserving extraction

## Approach

Extract a new module `Tau.IO.BoundedCollector` containing a single public
function `collect/4` (port, max_bytes, deadline_ms, opts) that implements the
common receive loop with an in-loop byte cap. Replace the bodies of
`collect_port/3` in `local.ex`, `collect/3` in `hooks/shell.ex`, and the
`{:noeol, partial}` accumulation path in `mcp/transport/stdio.ex`'s `recv/2`
with calls to `Tau.IO.BoundedCollector.collect/4`. The module also provides a
`close_port_if_open/1` guard that replaces all three `try/catch` around
`Port.close/1`. The existing call-site functions become thin delegations.

## Rationale

The complecting hypothesis is that "when to stop accumulating" is encoded as
"when the port exits." This proposal decomplects by making the cap a loop
invariant checked on every chunk, not an afterthought. Extracting to a shared
module eliminates the three-way duplication in a single move and puts the cap
enforcement in one place that can be tested and reasoned about independently of
any tool. The `close_port_if_open/1` helper simultaneously removes the
idiomatic smell at all three sites. Because the function signature preserves the
existing caller contract (returning `{:ok, binary, exit_status}` or
`{:error, reason}`), callers need no refactoring beyond their delegation clauses.

## Sketch

```elixir
# lib/tau/io/bounded_collector.ex
defmodule Tau.IO.BoundedCollector do
  @moduledoc """
  Bounded binary accumulation from a Port.

  Collects data messages from `port` until one of:
    - the port sends {:exit_status, n}  →  {:ok, binary, n}
    - byte_size(acc) >= max_bytes       →  {:ok, acc, :cap_reached}
    - deadline_ms elapses               →  {:error, :timeout}

  Callers receive at most `max_bytes` bytes regardless of how much the
  process writes.
  """

  @spec collect(port(), pos_integer(), non_neg_integer() | :infinity, keyword()) ::
          {:ok, binary(), non_neg_integer() | :cap_reached} | {:error, :timeout}
  def collect(port, max_bytes, deadline_ms, _opts \\ []) do
    do_collect(port, <<>>, max_bytes, deadline_ms)
  end

  @doc """
  Closes port only if it is still open. Replaces `try/catch` around
  `Port.close/1` at three call sites.
  """
  @spec close_if_open(port()) :: :ok
  def close_if_open(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp do_collect(port, acc, max_bytes, deadline_ms) do
    timeout = remaining_ms(deadline_ms)

    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        if byte_size(acc) >= max_bytes do
          close_if_open(port)
          {:ok, binary_part(acc, 0, max_bytes), :cap_reached}
        else
          do_collect(port, acc, max_bytes, deadline_ms)
        end

      {^port, {:exit_status, n}} ->
        {:ok, acc, n}
    after
      timeout ->
        close_if_open(port)
        {:error, :timeout}
    end
  end

  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 0)
end
```

Call-site after change in `local.ex`:

```elixir
defp collect_port(port, acc, deadline) do
  Tau.IO.BoundedCollector.collect(port, @max_bytes, deadline)
end
```

Call-site after change in `hooks/shell.ex`:

```elixir
defp collect(port, _acc, timeout_ms) do
  Tau.IO.BoundedCollector.collect(port, @max_output_bytes, System.monotonic_time(:millisecond) + timeout_ms)
end
```

`mcp/transport/stdio.ex` `recv/2` partial path:

```elixir
{^port, {:data, {:noeol, partial}}} ->
  new_partial = state.partial <> partial
  if byte_size(new_partial) >= @max_line_bytes do
    {:error, {:partial_overflow, byte_size(new_partial)}}
  else
    recv(%{state | partial: new_partial}, timeout)
  end
```

The `close/1` implementation in `stdio.ex` becomes:

```elixir
def close(%{port: port}) do
  Tau.IO.BoundedCollector.close_if_open(port)
end
```

## Tradeoffs

### Strengths

- Single source of truth for the byte-cap invariant; a test against
  `BoundedCollector.collect/4` directly covers all three original sites.
- Behaviour-preserving at existing call sites; callers see the same tagged tuple
  shape they already handle.
- `close_if_open/1` removes the non-idiomatic `try/catch` everywhere in one
  atomic change.
- The O(n²) binary concatenation problem is not made worse; it is isolated in
  one place where it can be addressed as a follow-up (e.g. `IO.iodata_to_binary`
  with a list acc).

### Weaknesses

- Introduces a new `Tau.IO` namespace that does not currently exist; adds one
  file and one namespace layer that reviewers must learn.
- `binary_part/3` at cap truncation drops trailing bytes from the last chunk
  silently; callers relying on a clean newline-terminated last line (hooks,
  stdio) may see a mid-UTF-8-codepoint truncation. A mitigation exists
  (truncate at the last `\n` boundary ≤ max_bytes) but adds complexity.
- The `mcp/transport/stdio.ex` partial path is line-framed, not a binary blob;
  wrapping it under the same function signature forces an awkward
  deadline-relative timestamp conversion at the call site.
- Does not address the O(n²) concatenation; that remains a follow-up.

### Costs

- One new module (`lib/tau/io/bounded_collector.ex`), ~60 LOC.
- Three call-site edits (thin delegations), each ≤ 5 lines changed.
- One new test module covering the bounded-stop path and the port-liveness guard.
- No new Mix dependencies.

## Dependencies

- None on other modules; this is a pure extraction.
- The `@max_bytes` constant used by `Bash` already exists at `bash.ex:9`; it
  must be threaded to `local.ex` or defined there, then passed into the shared
  collector.
- `hooks/shell.ex` has no documented cap today; a cap value must be decided
  (adopting `@max_bytes` from Bash is reasonable as a default, or it can be a
  per-site parameter).

## Confidence

medium — the sketch is concrete and the extraction is mechanically obvious.
Confidence would rise to high after: (a) verifying `@max_bytes` threading does
not break the `Bash` tool's existing truncation tests, and (b) confirming there
is no protocol expectation in the MCP stdio path that a `recv/2` call always
returns exactly one complete line.

## Prior art / references

- Elixir `IO.iodata_to_binary/1` accumulation pattern recommended in official
  guides for large binary assembly.
- `Port.info/1` liveness check idiom: Elixir documentation on Port module —
  "returns nil if the port is not open".
- OTP design principle: bounded mailboxes/buffers as loop invariants, not
  post-loop filters (documented in the BEAM book §4.3 "Back-pressure patterns").

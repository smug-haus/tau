---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Tau.IO.Collector behaviour — site-specific implementations sharing a typed contract

## Approach

Define a `Tau.IO.Collector` behaviour with a single callback `collect/3` and a
shared result type `t()`. Provide two concrete implementations:
`Tau.IO.Collector.Binary` (for `local.ex` and `hooks/shell.ex`) and
`Tau.IO.Collector.LineFramed` (for `mcp/transport/stdio.ex`'s partial
accumulation). Each implementation enforces its own byte cap inline but returns
the same typed result. The `try/catch` around `Port.close/1` is replaced by a
single `Tau.IO.Port.close_if_open/1` utility function. This is an API-breaking
change in the sense that `collect_port/3` and `collect/3` become private
delegations to the behaviour implementation, not standalone routines.

## Rationale

The complecting hypothesis identifies two distinct woven concerns: accumulation
strategy and termination policy. This proposal decomplects the *interface* from
the *strategy*: the behaviour defines what a bounded collector contract looks
like (typed result, cap parameter, deadline parameter), while each implementation
encodes the strategy appropriate to its transport framing. `Binary` uses iolist
accumulation with a byte cap; `LineFramed` accumulates partial lines with a
line-length cap. Callers depend on the behaviour type, not the implementation.
This is a stronger decomplecting move than Proposal 1 (shared function) because
the type is enforced by the behaviour compiler check, not by convention. The
`try/catch` duplication is eliminated not by moving code but by naming and
exporting the idiomatic guard once.

## Sketch

```elixir
# lib/tau/io/collector.ex  — behaviour definition + shared types
defmodule Tau.IO.Collector do
  @moduledoc """
  Behaviour for bounded Port I/O collection.

  All implementations enforce a byte cap inside the receive loop,
  closing the Port when the cap is reached, and return a uniform
  result type.
  """

  @type result ::
          {:ok, binary(), non_neg_integer() | :cap_reached}
          | {:error, :timeout | {:overflow, non_neg_integer()}}

  @callback collect(port :: port(), max_bytes :: pos_integer(), deadline :: integer() | :infinity) ::
              result()
end
```

```elixir
# lib/tau/io/collector/binary.ex — blob accumulation (bash, hooks)
defmodule Tau.IO.Collector.Binary do
  @behaviour Tau.IO.Collector

  @impl Tau.IO.Collector
  def collect(port, max_bytes, deadline) do
    loop(port, [], 0, max_bytes, deadline)
  end

  defp loop(port, acc, acc_bytes, max_bytes, deadline) do
    receive do
      {^port, {:data, data}} ->
        new_bytes = acc_bytes + byte_size(data)
        acc = [data | acc]

        if new_bytes >= max_bytes do
          Tau.IO.Port.close_if_open(port)
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary() |> binary_part(0, max_bytes), :cap_reached}
        else
          loop(port, acc, new_bytes, max_bytes, deadline)
        end

      {^port, {:exit_status, n}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), n}
    after
      remaining(deadline) ->
        Tau.IO.Port.close_if_open(port)
        {:error, :timeout}
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
```

```elixir
# lib/tau/io/collector/line_framed.ex — partial-line accumulation (stdio)
defmodule Tau.IO.Collector.LineFramed do
  @behaviour Tau.IO.Collector

  @impl Tau.IO.Collector
  def collect(port, max_bytes, deadline) do
    loop(port, "", max_bytes, deadline)
  end

  defp loop(port, partial, max_bytes, deadline) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {:ok, partial <> line, :eol}

      {^port, {:data, {:noeol, chunk}}} ->
        new_partial = partial <> chunk

        if byte_size(new_partial) >= max_bytes do
          {:error, {:overflow, byte_size(new_partial)}}
        else
          loop(port, new_partial, max_bytes, deadline)
        end

      {^port, {:exit_status, n}} ->
        {:error, {:exit, n}}
    after
      remaining(deadline) ->
        {:error, :timeout}
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
```

```elixir
# lib/tau/io/port.ex — shared port utilities
defmodule Tau.IO.Port do
  @moduledoc "Idiomatic Port utilities."

  @spec close_if_open(port()) :: :ok
  def close_if_open(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end
end
```

Call-site in `local.ex`:

```elixir
@collector Tau.IO.Collector.Binary

defp collect_port(port, _acc, deadline) do
  @collector.collect(port, @max_bytes, deadline)
end
```

Call-site in `hooks/shell.ex`:

```elixir
@collector Tau.IO.Collector.Binary
@max_output_bytes 32_768

defp collect(port, _acc, timeout_ms) do
  deadline = System.monotonic_time(:millisecond) + timeout_ms
  @collector.collect(port, @max_output_bytes, deadline)
end
```

`mcp/transport/stdio.ex` `recv/2` — delegates the partial path:

```elixir
@collector Tau.IO.Collector.LineFramed
@max_partial_bytes 65_536

def recv(%{port: port, partial: partial} = state, timeout) do
  deadline = System.monotonic_time(:millisecond) + timeout
  case @collector.collect(port, @max_partial_bytes, deadline) do
    {:ok, line, :eol}  -> {:ok, [partial <> line], %{state | partial: ""}}
    {:ok, _line, :cap_reached} -> {:error, {:overflow, @max_partial_bytes}}
    {:error, _} = e  -> e
  end
end
```

The `close/1` implementation in `stdio.ex`:

```elixir
def close(%{port: port}), do: Tau.IO.Port.close_if_open(port)
```

## Tradeoffs

### Strengths

- The behaviour definition is a machine-checked contract: any future collector
  implementation must satisfy the `@callback` spec or the compiler warns.
- Two distinct implementations serve genuinely different transport semantics
  (blob vs line-framed), avoiding the awkward unified-function signature of
  Proposal 1.
- The `@collector` module attribute at each call site makes the concrete
  implementation swappable in tests (mock or test-double without monkey-patching).
- Iolist accumulation is used in `Binary`; O(n²) is fixed simultaneously.
- `Tau.IO.Port.close_if_open/1` is a single exported function — one definition,
  three uses — not copy-pasted code.

### Weaknesses

- Three new modules (`Tau.IO.Collector`, `Tau.IO.Collector.Binary`,
  `Tau.IO.Collector.LineFramed`) plus one utility module (`Tau.IO.Port`) — the
  highest module count of the four proposals.
- The `LineFramed` implementation reworks `recv/2` significantly; the
  `mcp/transport/stdio.ex` call-site rewrite is non-trivial because the current
  `recv/2` accumulates partial state in `state.partial` across calls, while the
  collector processes one recv call at a time. Threading the pre-existing partial
  into `collect/3` requires either an additional parameter or a pre-seeded
  accumulator not expressed in the behaviour callback.
- `@collector` module attribute approach for testability is idiomatic but not
  universally familiar; reviewers unfamiliar with BEAM polymorphism-via-behaviour
  may expect a more conventional approach.
- The behaviour adds one level of indirection for what is, at each site, a small
  private function; this may be seen as over-engineering.

### Costs

- Four new modules, ~120 LOC total.
- Three call-site changes (delegation to behaviour impl).
- The `mcp/transport/stdio.ex` rework requires understanding the `state.partial`
  threading across consecutive `recv/2` calls; estimated 1–2 hours of design
  work beyond the mechanical extraction.
- New tests: one per behaviour callback (shared contract test), plus per-
  implementation tests for cap path, exit path, timeout path.

## Dependencies

- The `state.partial` threading design question in `stdio.ex` must be resolved
  before implementing `LineFramed`; this may require adding an optional
  `initial_partial` parameter to the `LineFramed.collect/3` function (diverging
  from the behaviour callback signature, which would then need a default-value
  wrapper).
- No new Mix dependencies; all code is BEAM stdlib.

## Confidence

medium — the `Binary` path is straightforward. The `LineFramed` path has a
pre-existing-partial threading complexity that must be resolved. Confidence
would rise to high after a prototype of `LineFramed` that correctly handles
the `state.partial <> chunk` continuation across calls.

## Prior art / references

- Elixir `@behaviour` + `@callback` as machine-checked interface: Elixir
  documentation "Behaviours" guide.
- `@adapter` module attribute for testable behaviour dispatch: used in Phoenix's
  `Swoosh.Adapters` pattern and Tau's own `Tau.Provider` behaviour.
- Separate blob vs line-framed collector designs: seen in the Erlang `gen_tcp`
  packet option (`raw` vs `line`) — the two accumulation models are genuinely
  distinct and warrant distinct implementations.
- `Port.info/1` liveness guard: Elixir Port documentation.

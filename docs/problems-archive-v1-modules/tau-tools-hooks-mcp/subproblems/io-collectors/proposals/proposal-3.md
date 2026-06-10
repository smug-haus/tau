---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Tau.IO.Collector GenServer — supervised back-pressure collector

## Approach

Replace the three inline receive loops with a supervised `Tau.IO.Collector`
GenServer. The collector is started transiently (`:temporary` restart strategy
under a `DynamicSupervisor`) for the lifetime of each port interaction.
It owns the port, enforces the byte cap via a `handle_info` clause, and sends a
`{:collector_result, ref, result}` reply to the caller when done (exit,
cap-reached, or timeout). The caller passes port and cap parameters at start and
blocks on a `GenServer.call/3` or a receive-on-ref until the result arrives.
The `try/catch` around `Port.close/1` is replaced by the GenServer's
`terminate/2` callback which guards on `Port.info/1` before closing.

## Rationale

The complecting hypothesis is that accumulation strategy and process lifecycle
are woven in the same receive loop. A GenServer collector fully separates these
concerns: the caller owns the *decision* to collect; the collector owns the
*mechanics* of accumulation, bounding, and port teardown. The lifecycle is now
supervisable — if the collector crashes (e.g. an unexpected port message), it
does not take down the calling session process. The byte cap is a GenServer
state field, checked on every `handle_info({port, {:data, data}})` call, making
it structurally impossible to receive data without checking the cap. This is a
data-shape + process-model change that addresses the acceptance criterion with
stronger runtime guarantees than either in-place fix.

## Sketch

```elixir
# lib/tau/io/collector.ex
defmodule Tau.IO.Collector do
  @moduledoc """
  Supervised collector for a single Port interaction.
  Enforces a byte cap inside the OTP message handler.
  Started transiently under Tau.IO.CollectorSupervisor.
  """

  use GenServer

  defstruct [:port, :max_bytes, :caller, :ref, acc: [], acc_bytes: 0]

  @type result ::
          {:ok, binary(), non_neg_integer() | :cap_reached}
          | {:error, :timeout | {:exit, non_neg_integer()}}

  # ── public API ───────────────────────────────────────────────────────────

  @spec collect(port(), pos_integer(), timeout()) :: result()
  def collect(port, max_bytes, timeout_ms) do
    ref = make_ref()
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Tau.IO.CollectorSupervisor,
        {__MODULE__, {port, max_bytes, self(), ref}}
      )

    receive do
      {:collector_result, ^ref, result} -> result
    after
      timeout_ms ->
        GenServer.stop(pid, :timeout)
        {:error, :timeout}
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  def start_link({port, max_bytes, caller, ref}) do
    GenServer.start_link(__MODULE__, {port, max_bytes, caller, ref})
  end

  @impl GenServer
  def init({port, max_bytes, caller, ref}) do
    {:ok, %__MODULE__{port: port, max_bytes: max_bytes, caller: caller, ref: ref}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_acc = [data | state.acc]
    new_bytes = state.acc_bytes + byte_size(data)

    if new_bytes >= state.max_bytes do
      result = {:ok, finalize(new_acc, state.max_bytes), :cap_reached}
      send(state.caller, {:collector_result, state.ref, result})
      {:stop, :normal, %{state | acc: new_acc, acc_bytes: new_bytes}}
    else
      {:noreply, %{state | acc: new_acc, acc_bytes: new_bytes}}
    end
  end

  def handle_info({port, {:exit_status, n}}, %{port: port} = state) do
    result = {:ok, IO.iodata_to_binary(Enum.reverse(state.acc)), n}
    send(state.caller, {:collector_result, state.ref, result})
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if Port.info(state.port) != nil, do: Port.close(state.port)
    :ok
  end

  defp finalize(acc, max_bytes) do
    acc |> Enum.reverse() |> IO.iodata_to_binary() |> binary_part(0, max_bytes)
  end
end
```

```elixir
# lib/tau/io/collector_supervisor.ex
defmodule Tau.IO.CollectorSupervisor do
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl DynamicSupervisor
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```

`lib/tau/application.ex` supervision tree addition:

```elixir
{Tau.IO.CollectorSupervisor, []}
```

Call-site in `local.ex`:

```elixir
defp collect_port(port, _acc, _deadline) do
  Tau.IO.Collector.collect(port, @max_bytes, remaining_or_inf(@deadline))
end
```

## Tradeoffs

### Strengths

- The byte cap is structurally enforced by OTP message dispatch; it is
  impossible for the `handle_info` clause to receive data without checking the
  cap.
- Port teardown is isolated in `terminate/2`, eliminating `try/catch` at all
  three sites with an OTP-idiomatic lifecycle callback.
- Collector crashes are isolated from caller sessions; a bug in accumulation
  does not propagate as a linked process crash.
- Iolist accumulation (`[data | acc]`) is used from the start; O(n²) is
  eliminated alongside the cap fix.
- Supervisable and observable: a future telemetry attachment or back-pressure
  extension has a natural home in `handle_info`.

### Weaknesses

- Highest complexity of the three proposals: adds two new modules plus a
  supervision tree entry.
- The `DynamicSupervisor.start_child/2` call-path adds measurable latency
  (~microseconds) per collection; for short-lived Bash commands this is
  invisible, but it is non-zero.
- The caller blocks in a bare `receive` waiting for `{:collector_result, ref,
  result}` — this is a regression from a direct `GenServer.call/3` (the ref
  approach is used to avoid coupling to the GenServer pid). A selectible receive
  pattern is required; callers already in a GenServer context must handle the
  message in `handle_info`, not inline.
- Timeout handling is split between the caller's receive-after and the
  GenServer's `terminate/2`; the interaction between the two must be carefully
  tested (e.g. double-close if both fire near-simultaneously).
- Overkill for what is essentially a bounded buffer: the OTP overhead is
  justified by isolation guarantees, but the same invariant can be achieved
  with in-place fixes (Proposal 2) at far lower cost.
- `mcp/transport/stdio.ex`'s `recv/2` is already designed as a synchronous
  call-per-line; wrapping it in a GenServer collector changes the protocol
  semantics and may not be straightforward.

### Costs

- Two new modules, ~80 LOC total.
- One supervision tree entry in `application.ex`.
- Three call-site changes.
- New test coverage needed for: cap-reached path, exit path, double-close race,
  timeout-vs-terminate race.
- All existing `collect_port` tests must be adapted to the new call shape.

## Dependencies

- `Tau.IO.CollectorSupervisor` must be started before any tool that uses Bash.
  It must be placed in the supervision tree before `Tau.Tools` (if that is a
  supervised entity).
- The `mcp/transport/stdio.ex` integration requires design work on how
  `recv/2` interacts with a GenServer collector given its line-framing protocol;
  a variant or a separate lightweight path may be needed there.

## Confidence

medium — the GenServer skeleton is well-understood OTP. Confidence would rise
to high after: (a) resolving the caller-in-GenServer-context problem for
`hooks/shell.ex` (which is called from within the hook dispatcher, itself
likely a GenServer), and (b) confirming `mcp/transport/stdio.ex` can adopt the
collector without changing the `Tau.MCP.Transport` behaviour contract.

## Prior art / references

- OTP `DynamicSupervisor` for transient workers: OTP documentation §5.4.
- "Isolate side-effecting workers with transient supervisors" — Erlang/OTP in
  Action, Hebert, ch. 9.
- `GenServer.terminate/2` for resource cleanup: OTP documentation recommends
  using `terminate` for port/socket teardown when process exit is the teardown
  signal.
- Phoenix's `Plug.Conn` body-reader uses a ref-based reply pattern for
  back-pressure collection from an async process — similar to the
  `{:collector_result, ref, result}` shape here.

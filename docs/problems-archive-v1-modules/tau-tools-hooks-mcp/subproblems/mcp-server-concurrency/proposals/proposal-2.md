---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Async transport contract — redefine the Transport behaviour so send/2 is always non-blocking and recv is message-driven

## Approach

Redefine the `Tau.MCP.Transport` behaviour so that `send/2` MUST be
non-blocking: it initiates the outbound request and returns `{:ok,
transport_state}` immediately, with the guarantee that when a response arrives
the transport will send `{:mcp_line, ref, line}` to the process that called
`connect/1`. Remove `recv/2` from the behaviour entirely (it has no role once
message delivery is the contract). Update `Http` to use `Finch.async_request/3`
(which delivers `{ref, %Finch.Response{}}` to the caller), `Sse` already sends
messages so its `send/2` is already non-blocking — only the `recv/2` call in the
catch-all is removed. The Server's `handle_info({:mcp_line, ref, line}, state)`
becomes the sole inbound path; the `handle_info(_msg)` catch-all stops calling
recv. Pending-map pruning is handled by a `Process.send_after/3` per entry
delivering `{:invoke_timeout, id}` when no response has arrived within
`@timeout`.

## Rationale

The complecting seam is the mismatch between what the Server *assumes* (async
delivery of response messages) and what transports *implement* (synchronous I/O
inside `send/2`). Rather than patching each transport individually, this proposal
enforces the async contract at the behaviour level: any future transport
implementor is told "send must not block; deliver lines as messages". The Stdio
transport already satisfies a message-based contract (the linked Task does this);
Http and Sse are brought into alignment. The `recv/2` callback is the
architectural mistake — it implies a pull model that was never intended — so it
is removed rather than left dormant.

## Sketch

New behaviour (`lib/tau/mcp/transport.ex`):

```elixir
@doc """
Connect to the MCP server. Returns {:ok, transport_state}.
Lines from the server are delivered as {ref, {:line, line}} to `self()`,
where ref is the value embedded in transport_state.
"""
@callback connect(config :: map()) :: {:ok, transport_state()} | {:error, term()}

@doc """
Initiate sending `payload` to the MCP server. MUST NOT block for the
network round-trip. Returns {:ok, transport_state} when the send is
enqueued/initiated, {:error, reason} if the request cannot be started.
Response (when it arrives) is delivered as {ref, {:line, line}} to the
process that called connect/1.
"""
@callback send(transport_state(), payload :: binary()) ::
  {:ok, transport_state()} | {:error, term()}

@callback close(transport_state()) :: :ok

# recv/2 is removed from the behaviour.
```

`Http` rewritten to use `Finch.async_request/3`:

```elixir
defmodule Tau.MCP.Transport.Http do
  @behaviour Tau.MCP.Transport

  @impl Tau.MCP.Transport
  def connect(%{} = config) do
    url = config["url"] || config[:url]
    headers = Map.get(config, "headers", %{}) |> Enum.to_list()
    ref = make_ref()
    {:ok, %{url: url, headers: headers, ref: ref}}
  end

  @impl Tau.MCP.Transport
  def send(%{url: url, headers: headers, ref: ref} = state, payload) do
    headers = [{"content-type", "application/json"} | headers]
    body = IO.iodata_to_binary(payload)
    request = Finch.build(:post, url, headers, body)
    # Finch.async_request/3 delivers {finch_ref, result} to calling process
    {:ok, _finch_ref} = Finch.async_request(request, Tau.Providers.Finch)
    # We bridge: a Task waits for the Finch async response and re-sends
    # as {ref, {:line, body}} to the Server.
    parent = self()
    Task.start(fn ->
      receive do
        {_finch_ref, {:ok, %Finch.Response{status: s, body: body}}} when s in 200..299 ->
          Process.send(parent, {ref, {:line, body}}, [])
        {_finch_ref, {:ok, %Finch.Response{status: s}}} ->
          Process.send(parent, {ref, {:error, {:http_status, s}}}, [])
        {_finch_ref, {:error, e}} ->
          Process.send(parent, {ref, {:error, e}}, [])
      after
        30_000 -> Process.send(parent, {ref, {:error, :timeout}}, [])
      end
    end)
    {:ok, state}
  end

  @impl Tau.MCP.Transport
  def close(_state), do: :ok
end
```

`Sse.send/2` already does a non-blocking POST (the GET stream task sends messages).
Remove its `recv/2`; the task already sends `{ref, {:line, data}}`.

`Server.handle_info` becomes:

```elixir
# Unified inbound path — all transports deliver here
def handle_info({ref, {:line, line}}, %{transport_state: %{ref: ref}} = state) do
  handle_message(line, state)
end

def handle_info({ref, {:error, reason}}, %{transport_state: %{ref: ref}} = state) do
  # find pending entry by scanning (or: store ref → id index)
  {:noreply, state}
end

# Timeout prune — sent by Process.send_after in handle_call
def handle_info({:invoke_timeout, id}, state) do
  case Map.pop(state.pending, id) do
    {nil, _} -> {:noreply, state}
    {from, pending} ->
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{state | pending: pending}}
  end
end

# Catch-all — no transport.recv, no side effects
def handle_info(_msg, state), do: {:noreply, state}
```

Pending pruning via `Process.send_after(self(), {:invoke_timeout, id}, @timeout)` in `handle_call`.

## Tradeoffs

### Strengths

- The behaviour contract is now correct by construction: a transport that blocks
  in `send/2` is a compile-time violation (incorrect return type detected at
  runtime) and a design-time violation (documented in the callback doc).
- `recv/2` is removed rather than left as dead code; the pull model disappears.
- The catch-all drain is gone because there is no `recv/2` to call.
- Pending pruning via `send_after` is explicit and auditable; no monitor needed.
- All three transports now share the same inbound path (`{ref, {:line, line}}`),
  making the Server's `handle_info` uniform.

### Weaknesses

- `Finch.async_request/3` delivers `{finch_ref, result}` to the calling process;
  bridging it to the Server's canonical `{ref, {:line, line}}` message still
  requires a short-lived Task, so the unsupervised-process concern from Proposal
  1 remains. The bridge Task is simpler (one `receive` with timeout) but still
  unsupervised.
- The Http transport now has two levels of async indirection (Finch async +
  bridge Task), making it harder to trace a failing request in production logs.
- The `ref` field in `transport_state` is used as a pattern-match key in
  `handle_info`; if a transport needs multiple concurrent refs (e.g., parallel
  streams), this scheme requires extension.
- Removing `recv/2` is an API-breaking change if any code outside `server.ex`
  calls `transport.recv/2` directly (currently none, but requires confirmation).
- The `send_after` timer fires even if the response arrived promptly, generating
  a harmless but noisy `{:invoke_timeout, id}` after the entry is already
  removed — requires a `cancel_timer` on successful response, or a guard in the
  timeout clause.

### Costs

- Behaviour contract change: all three transport modules must be updated.
- Any mock or test transport must remove `recv/2` and add message delivery.
- ~100–120 LOC change total (`transport.ex`, `http.ex`, `sse.ex`, `server.ex`).
- Documentation for implementors of custom transports needs updating.

## Dependencies

- `Finch.async_request/3` requires Finch ≥ 1.13 (available in the current
  `mix.exs`; verify with `mix deps`).
- No new dependencies.

## Confidence

Medium. The async-behaviour contract is the right long-term design. Confidence
would rise to high after confirming `Finch.async_request/3`'s message shape and
verifying the Sse task already uses the `ref`-keyed message format needed here.

## Prior art / references

- `Finch.async_request/3` — Finch's native async API delivering
  `{ref, result}` to the caller process: https://hexdocs.pm/finch/Finch.html#async_request/3
- OTP `gen_tcp` / `ssl` socket ownership and message-based async: same pattern
  at the BEAM transport layer.
- `Tau.MCP.Transport.Stdio` — the Stdio transport already delivers lines as
  `{ref, {:line, line}}` messages; this proposal makes Http and Sse conform to
  the same idiom.

defmodule Tau.MCP.Transport do
  @moduledoc """
  Behaviour for MCP transports.

  Implementations:

    * `Tau.MCP.Transport.Stdio` — spawns a subprocess, JSON-RPC over
      stdin/stdout (newline-delimited).
    * `Tau.MCP.Transport.Http`  — request/response per RPC against an
      HTTP endpoint.
    * `Tau.MCP.Transport.Sse`   — server-pushed events plus
      request/response. Streams notifications via the SSE shared parser.

  All transports use a GenServer-callback-style API: `connect/1` returns
  state; `send/2` and `recv/2` mutate it; `close/1` releases resources.
  Implementations must never raise — failures are tagged tuples.
  """

  @callback connect(config :: map()) :: {:ok, state :: term()} | {:error, term()}
  @callback send(state :: term(), iodata()) :: {:ok, state :: term()} | {:error, term()}
  @callback recv(state :: term(), timeout()) ::
              {:ok, [binary()], state :: term()} | {:error, term()}
  @callback close(state :: term()) :: :ok
end

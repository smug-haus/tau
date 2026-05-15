defmodule Tau.CodingAgent.TauContext.Auth do
  @moduledoc """
  Per-run bearer-token auth for the `tau-context` MCP server
  (SPEC-CODING-AGENT §4 B4).

  Each `Tau.CodingAgent.TauContext` GenServer mints one
  cryptographically random token at `start_link/1`. The token is
  passed to the coding-agent subprocess via the `mcp_servers`
  field of the task struct; downstream the adapter is expected
  to plumb it into the agent's `--mcp-config` so the agent can
  present it back as either:

    * `Authorization: Bearer <token>` header, or
    * `?token=<token>` query string parameter.

  The token is **never** logged, never persisted, and lives only
  in the running TauContext process and its child Cowboy listener.

  ## Rationale

  127.0.0.1-only binding stops remote attackers, but on a shared
  host any local process could speak to the listener if the URL
  is known. The token closes that gap. It MUST be a
  high-entropy random value (256 bits here — `:crypto.strong_rand_bytes(32)`)
  to defeat brute-force scanning of `/etc/hosts`-style port
  guessing.

  ## D-035 (no raise on bad input)

  `extract_token/1` returns `nil` when the request carries no
  recognisable credentials. Callers MUST emit a JSON-RPC error
  response rather than raising.
  """

  @typedoc "Opaque token value. Treat as a secret."
  @type token :: String.t()

  @doc """
  Mint a fresh per-run token.

  256 bits, URL-safe Base64 encoded so it survives unmodified
  through query strings and header values.
  """
  @spec mint() :: token()
  def mint do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Constant-time comparison.

  Avoids leaking the expected token's prefix through timing
  side-channels. Both arguments are coerced to binaries; `nil`
  on the presented side returns `false` without dereferencing.
  """
  @spec verify(token() | nil, token()) :: boolean()
  def verify(nil, _expected), do: false

  def verify(presented, expected)
      when is_binary(presented) and is_binary(expected) do
    :crypto.hash_equals(presented, expected)
  rescue
    _ -> false
  end

  def verify(_presented, _expected), do: false

  @doc """
  Pull a candidate token from a `Plug.Conn`.

  Order of precedence: Authorization header first, then `token`
  query parameter. Returns `nil` if neither is present.
  """
  @spec extract_token(Plug.Conn.t()) :: token() | nil
  def extract_token(%Plug.Conn{} = conn) do
    header_token(conn) || query_token(conn)
  end

  defp header_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> tok | _] -> tok
      ["bearer " <> tok | _] -> tok
      _ -> nil
    end
  end

  defp query_token(%Plug.Conn{query_params: %Plug.Conn.Unfetched{}} = conn) do
    conn |> Plug.Conn.fetch_query_params() |> query_token()
  end

  defp query_token(%Plug.Conn{query_params: params}) when is_map(params) do
    case Map.get(params, "token") do
      tok when is_binary(tok) and byte_size(tok) > 0 -> tok
      _ -> nil
    end
  end
end

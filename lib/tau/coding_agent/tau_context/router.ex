defmodule Tau.CodingAgent.TauContext.Router do
  @moduledoc """
  Plug handler for the per-run `tau-context` MCP server.

  Implements the subset of MCP (JSON-RPC 2.0 over HTTP) that
  a coding-agent subprocess needs:

    * `initialize`  → server capabilities + serverInfo
    * `tools/list`  → `Tools.catalog/0`
    * `tools/call`  → `Tools.call/3`
    * `ping`        → empty result (heartbeat)
    * `notifications/*` → 204, no response body

  All other endpoints / methods return JSON-RPC errors. The Plug
  itself never raises on bad input (D-035): malformed JSON, bad
  method names, missing fields all surface as structured
  `{"error": {...}}` responses.

  ## Auth

  Every request is checked against the per-run token. Missing or
  wrong token → `401 Unauthorized`, JSON-RPC error code -32_001.

  ## Routing

  * `GET  /healthz`  → 200, plain text (no auth — used by the
    GenServer to confirm the listener is up before the dispatcher
    advances). Bound to 127.0.0.1 only so this is not a remote
    information leak.
  * `POST /mcp`      → JSON-RPC dispatch.
  * everything else  → 404.

  ## How `state` arrives

  `Plug.Cowboy.child_spec/1` accepts `init_options` (Plug "opts").
  The TauContext GenServer passes a `%{state_ref: ref}` map at
  startup. The `state_ref` is a `:persistent_term` key the
  router reads to obtain the live state map. Using a
  persistent_term (rather than a closure or genserver call)
  keeps the request handler lock-free and survives GenServer
  message-box backpressure.
  """

  @behaviour Plug

  alias Plug.Conn
  alias Tau.CodingAgent.TauContext.{Auth, Tools}

  @rpc_version "2.0"

  @impl Plug
  def init(opts) when is_map(opts), do: opts
  def init(opts) when is_list(opts), do: Map.new(opts)

  @impl Plug
  def call(%Conn{} = conn, opts) do
    case {conn.method, conn.path_info} do
      {"GET", ["healthz"]} ->
        send_text(conn, 200, "ok")

      {"POST", ["mcp"]} ->
        handle_mcp(conn, opts)

      {"GET", ["mcp"]} ->
        # MCP HTTP transport SSE-style GETs are not implemented;
        # return a structured 405 so the client gets a useful
        # signal rather than 404.
        send_json(conn, 405, %{
          "jsonrpc" => @rpc_version,
          "error" => %{"code" => -32_601, "message" => "GET not supported; use POST"}
        })

      _ ->
        send_text(conn, 404, "not found")
    end
  rescue
    # D-035 hard guard. Should be unreachable given the per-handler
    # try/catches below, but a Plug crash here would take down the
    # whole listener and cascade into the dispatcher. Surface a
    # JSON-RPC error instead.
    e ->
      send_json(conn, 500, %{
        "jsonrpc" => @rpc_version,
        "error" => %{
          "code" => -32_603,
          "message" => "router exception: " <> Exception.message(e)
        }
      })
  end

  # ── MCP POST handler ──────────────────────────────────────────

  defp handle_mcp(conn, opts) do
    state = load_state(opts)

    with :ok <- authorize(conn, state),
         {:ok, body, conn} <- read_request_body(conn),
         {:ok, decoded} <- decode_json(body) do
      respond_rpc(conn, decoded, state)
    else
      {:error, :unauthorized} ->
        send_json(conn, 401, %{
          "jsonrpc" => @rpc_version,
          "error" => %{"code" => -32_001, "message" => "unauthorized"}
        })

      {:error, :body_too_large} ->
        send_json(conn, 413, %{
          "jsonrpc" => @rpc_version,
          "error" => %{"code" => -32_600, "message" => "request body too large"}
        })

      {:error, {:parse_error, reason}} ->
        send_json(conn, 400, %{
          "jsonrpc" => @rpc_version,
          "id" => nil,
          "error" => %{
            "code" => -32_700,
            "message" => "parse error: " <> inspect(reason)
          }
        })

      {:error, reason} ->
        send_json(conn, 400, %{
          "jsonrpc" => @rpc_version,
          "id" => nil,
          "error" => %{"code" => -32_600, "message" => "bad request: " <> inspect(reason)}
        })
    end
  end

  defp authorize(conn, state) do
    expected = state[:token]

    cond do
      not is_binary(expected) or expected == "" ->
        # No token configured — refuse rather than fall open.
        {:error, :unauthorized}

      Auth.verify(Auth.extract_token(conn), expected) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp read_request_body(conn, acc \\ "") do
    case Conn.read_body(conn, length: 1_048_576, read_length: 1_048_576) do
      {:ok, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > 4 * 1_048_576 do
          {:error, :body_too_large}
        else
          {:ok, body, conn}
        end

      {:more, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > 4 * 1_048_576 do
          {:error, :body_too_large}
        else
          read_request_body(conn, body)
        end

      {:error, reason} ->
        {:error, {:read_body_error, reason}}
    end
  end

  defp decode_json(""), do: {:ok, %{}}

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, e} -> {:error, {:parse_error, Exception.message(e)}}
    end
  end

  # ── JSON-RPC dispatch ─────────────────────────────────────────

  # Single request.
  defp respond_rpc(conn, %{"jsonrpc" => "2.0"} = req, state) do
    case dispatch(req, state) do
      :no_response ->
        # Notification — JSON-RPC says respond with empty body.
        Conn.send_resp(conn, 204, "")

      response ->
        send_json(conn, 200, response)
    end
  end

  # Batch request (rare for MCP but spec-allowed).
  defp respond_rpc(conn, requests, state) when is_list(requests) do
    responses =
      requests
      |> Enum.map(&dispatch(&1, state))
      |> Enum.reject(&(&1 == :no_response))

    if responses == [] do
      Conn.send_resp(conn, 204, "")
    else
      send_json(conn, 200, responses)
    end
  end

  defp respond_rpc(conn, _other, _state) do
    send_json(conn, 400, %{
      "jsonrpc" => @rpc_version,
      "id" => nil,
      "error" => %{"code" => -32_600, "message" => "not a JSON-RPC 2.0 envelope"}
    })
  end

  defp dispatch(%{"method" => method, "id" => id} = req, state) do
    handle_method(method, Map.get(req, "params", %{}), id, state)
  rescue
    e ->
      rpc_error(id, -32_603, "internal error: " <> Exception.message(e))
  catch
    kind, reason ->
      rpc_error(id, -32_603, "internal throw: #{inspect({kind, reason})}")
  end

  defp dispatch(%{"method" => method} = req, state) do
    # No id → notification. Side-effect tools are forbidden via
    # notifications because we can't surface their result; only
    # known no-op notifications are accepted.
    _ = handle_notification(method, Map.get(req, "params", %{}), state)
    :no_response
  end

  defp dispatch(_other, _state) do
    rpc_error(nil, -32_600, "missing 'method'")
  end

  defp handle_method("initialize", params, id, _state) do
    client_proto = (is_map(params) and params["protocolVersion"]) || "2024-11-05"

    rpc_result(id, %{
      "protocolVersion" => client_proto,
      "capabilities" => %{
        "tools" => %{"listChanged" => false}
      },
      "serverInfo" => %{
        "name" => "tau-context",
        "version" => tau_version()
      }
    })
  end

  defp handle_method("tools/list", _params, id, _state) do
    rpc_result(id, %{"tools" => Tools.catalog()})
  end

  defp handle_method("tools/call", params, id, state) when is_map(params) do
    name = params["name"]
    args = params["arguments"] || %{}

    cond do
      not is_binary(name) ->
        rpc_error(id, -32_602, "missing or invalid 'name'")

      not is_map(args) ->
        rpc_error(id, -32_602, "'arguments' must be an object")

      true ->
        case Tools.call(name, args, state) do
          {:ok, text} when is_binary(text) ->
            rpc_result(id, %{
              "content" => [%{"type" => "text", "text" => text}],
              "isError" => false
            })

          {:error, %{code: code, message: msg}} ->
            rpc_error(id, code, msg)

          other ->
            rpc_error(id, -32_603, "unexpected tool return: " <> inspect(other))
        end
    end
  end

  defp handle_method("tools/call", _params, id, _state),
    do: rpc_error(id, -32_602, "'params' must be an object")

  defp handle_method("ping", _params, id, _state), do: rpc_result(id, %{})

  defp handle_method(method, _params, id, _state),
    do: rpc_error(id, -32_601, "method not found: " <> method)

  defp handle_notification(_method, _params, _state), do: :ok

  # ── JSON-RPC envelopes ────────────────────────────────────────

  defp rpc_result(id, result) do
    %{"jsonrpc" => @rpc_version, "id" => id, "result" => result}
  end

  defp rpc_error(id, code, message) do
    %{
      "jsonrpc" => @rpc_version,
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  # ── plug helpers ──────────────────────────────────────────────

  defp send_text(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("text/plain")
    |> Conn.send_resp(status, body)
  end

  defp send_json(conn, status, payload) do
    body =
      case Jason.encode(payload) do
        {:ok, b} -> b
        _ -> ~s({"error":"json encode failed"})
      end

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
  end

  defp load_state(opts) do
    case opts[:state_ref] do
      nil ->
        # No state registered — return an empty state so dispatch
        # can still produce a JSON-RPC error.
        %{token: nil, session_id: nil, cwd: nil, max_depth: 2}

      key ->
        :persistent_term.get(key, %{token: nil, session_id: nil, cwd: nil, max_depth: 2})
    end
  end

  defp tau_version do
    case Application.spec(:tau, :vsn) do
      nil -> "0.0.0"
      v -> to_string(v)
    end
  end
end

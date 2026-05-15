defmodule Tau.CodingAgent.TauContext.Tools do
  @moduledoc """
  The four tau-side tools exposed to a coding-agent subprocess
  over the per-run MCP server (SPEC-CODING-AGENT §4 B4).

  Each tool function returns one of:

    * `{:ok, content}` — `content` is the string returned to the
      agent under the MCP `tools/call` result shape
      `%{"content" => [%{"type" => "text", "text" => content}]}`.
    * `{:error, reason}` — surfaced to the agent as a JSON-RPC
      error response.

  Tools that depend on optional tau capabilities (memory,
  recursive delegation) gracefully degrade to a structured
  `{"available": false, "reason": "..."}` JSON body wrapped in
  `{:ok, _}` so the agent gets a structured signal rather than
  a hard error. The exception is `tau_session_status/1`, which
  is backed by `Tau.Session.snapshot/1` and is always available
  when the session id is valid.

  ## Why a plain module not a behaviour

  The MCP server itself sits at the boundary; the tools are
  pure (or near-pure) computation against in-BEAM data. Wrapping
  each one in a `Tau.Tool` impl would duplicate the JSON-Schema
  declaration and force a registry round-trip. The agent never
  sees these tools through `Tau.Tools.Registry` — they are
  exposed exclusively over the per-run MCP listener.

  ## D-035 (no raise)

  Every public function in this module catches its own errors
  and returns a tagged tuple. Callers in `Router` rely on this
  invariant.
  """

  alias Tau.Memory.Loader, as: MemoryLoader

  @typedoc """
  Snapshot of the live `TauContext` state passed in on every
  call. The router reads this out of `:persistent_term` (so it
  is lock-free and immutable for the duration of one request).
  Keys:

    * `:token`      — the per-run secret (handled by the router;
      tools never touch it directly).
    * `:session_id` — bound tau session id, or `nil`.
    * `:cwd`        — workspace path, used as the default
      memory-cascade root.
    * `:max_depth`  — recursive-delegation cap.
  """
  @type state :: %{
          optional(:token) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:cwd) => String.t() | nil,
          optional(:max_depth) => non_neg_integer()
        }

  @default_max_depth 2

  # ── tool catalog ──────────────────────────────────────────────

  @doc """
  Static JSON-RPC `tools/list` payload.

  The shape mirrors the MCP `tools/list` result: each entry has
  `name`, `description`, and an `inputSchema` (a JSON Schema
  object). Centralised here so `Router` doesn't drift from the
  dispatch table.
  """
  @spec catalog() :: [map()]
  def catalog do
    [
      %{
        "name" => "tau_session_status",
        "description" =>
          "Return the current tau session's id, message count, and FSM state. " <>
            "Use to confirm the parent session is alive before issuing further " <>
            "delegated work.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      },
      %{
        "name" => "tau_memory_query",
        "description" =>
          "Read from tau's memory cascade (TAU.md / CLAUDE.md hierarchy). " <>
            "Returns an availability flag plus matching entries when memory " <>
            "is configured for the running session.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Free-text query."}
          },
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      %{
        "name" => "tau_memory_write",
        "description" =>
          "Best-effort write to tau memory. May report unavailable if no " <>
            "writable memory layer is configured (current default).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string"},
            "key" => %{"type" => "string"},
            "body" => %{"type" => "string"}
          },
          "required" => ["kind", "key", "body"],
          "additionalProperties" => false
        }
      },
      %{
        "name" => "tau_delegate",
        "description" =>
          "Enqueue a recursive coding-agent delegation. Subject to a " <>
            "max-depth limit (default 2) measured from the originating " <>
            "session to defend against runaway recursion.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "prompt" => %{"type" => "string"},
            "agent" => %{
              "type" => "string",
              "description" => "Adapter name, e.g. \"claude_code\"."
            },
            "depth" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Current depth; 0 if unknown."
            }
          },
          "required" => ["prompt"],
          "additionalProperties" => true
        }
      }
    ]
  end

  # ── dispatch ──────────────────────────────────────────────────

  @doc """
  Dispatch a parsed `tools/call` payload.

  `state` is the `TauContext`'s state snapshot (carries
  `session_id`, `cwd`, `max_depth`). Returns the same
  `{:ok, content} | {:error, reason}` shape as the individual
  tool functions.
  """
  @spec call(String.t(), map(), state()) ::
          {:ok, String.t()} | {:error, %{code: integer(), message: String.t()}}
  def call("tau_session_status", _args, state), do: tau_session_status(state)

  def call("tau_memory_query", %{"query" => q}, state) when is_binary(q),
    do: tau_memory_query(q, state)

  def call("tau_memory_query", _args, _state),
    do: {:error, %{code: -32_602, message: "missing or invalid 'query'"}}

  def call("tau_memory_write", %{"kind" => k, "key" => key, "body" => body}, state)
      when is_binary(k) and is_binary(key) and is_binary(body),
      do: tau_memory_write(k, key, body, state)

  def call("tau_memory_write", _args, _state),
    do: {:error, %{code: -32_602, message: "missing or invalid memory_write args"}}

  def call("tau_delegate", args, state) when is_map(args),
    do: tau_delegate(args, state)

  def call(name, _args, _state) when is_binary(name),
    do: {:error, %{code: -32_601, message: "unknown tool: #{name}"}}

  def call(_name, _args, _state),
    do: {:error, %{code: -32_602, message: "invalid tool name"}}

  # ── tool: tau_session_status ──────────────────────────────────

  @doc false
  @spec tau_session_status(state()) :: {:ok, String.t()}
  def tau_session_status(%{session_id: nil}) do
    {:ok,
     encode(%{
       "available" => false,
       "reason" => "no session bound to this tau-context server"
     })}
  end

  def tau_session_status(%{session_id: id}) when is_binary(id) do
    case Tau.Session.snapshot(id) do
      {:ok, snap} ->
        {:ok,
         encode(%{
           "available" => true,
           "session_id" => snap.id,
           "state" => Atom.to_string(snap.state),
           "message_count" => snap.message_count,
           "provider" => safe_inspect(snap.provider),
           "model" => snap.model,
           "cwd" => snap.cwd
         })}

      {:error, :not_found} ->
        {:ok,
         encode(%{
           "available" => false,
           "reason" => "session #{id} not registered (already stopped?)",
           "session_id" => id
         })}
    end
  rescue
    e ->
      {:ok,
       encode(%{
         "available" => false,
         "reason" => "snapshot error: " <> Exception.message(e)
       })}
  catch
    kind, reason ->
      {:ok,
       encode(%{
         "available" => false,
         "reason" => "snapshot threw: #{inspect({kind, reason})}"
       })}
  end

  def tau_session_status(_state),
    do: {:ok, encode(%{"available" => false, "reason" => "invalid state"})}

  # ── tool: tau_memory_query ────────────────────────────────────

  @doc false
  @spec tau_memory_query(String.t(), state()) :: {:ok, String.t()}
  def tau_memory_query(query, state) when is_binary(query) do
    cwd =
      Map.get(state, :cwd) ||
        (Map.get(state, :session_id) && session_cwd(Map.get(state, :session_id))) ||
        File.cwd!()

    case safe_memory_load(cwd) do
      {:ok, []} ->
        {:ok,
         encode(%{
           "available" => true,
           "query" => query,
           "results" => [],
           "reason" => "no memory files in cascade"
         })}

      {:ok, entries} ->
        matches = filter_memory(entries, query)

        {:ok,
         encode(%{
           "available" => true,
           "query" => query,
           "results" => matches
         })}

      {:error, reason} ->
        {:ok, encode(%{"available" => false, "reason" => reason, "query" => query})}
    end
  end

  defp safe_memory_load(cwd) do
    if Code.ensure_loaded?(MemoryLoader) and
         function_exported?(MemoryLoader, :load, 1) do
      try do
        entries = MemoryLoader.load(cwd)
        normalised = Enum.map(entries, fn {path, body} -> %{path: path, body: body} end)
        {:ok, normalised}
      rescue
        e -> {:error, "memory loader failed: " <> Exception.message(e)}
      catch
        kind, reason -> {:error, "memory loader threw: #{inspect({kind, reason})}"}
      end
    else
      {:error, "Tau.Memory.Loader not available"}
    end
  end

  defp filter_memory(entries, query) do
    needle = String.downcase(query)

    entries
    |> Enum.flat_map(fn %{path: path, body: body} ->
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _i} ->
        String.contains?(String.downcase(line), needle)
      end)
      |> Enum.map(fn {line, i} ->
        %{"path" => to_string(path), "line" => i, "text" => line}
      end)
    end)
    |> Enum.take(50)
  end

  # ── tool: tau_memory_write ────────────────────────────────────

  @doc false
  @spec tau_memory_write(String.t(), String.t(), String.t(), state()) :: {:ok, String.t()}
  def tau_memory_write(kind, key, body, _state)
      when is_binary(kind) and is_binary(key) and is_binary(body) do
    # No writable memory layer ships in tau today — the loader is
    # read-only and ADR-0006 removed the cache. Surface this as a
    # structured "available: false" rather than fail loudly: a
    # future Phase 2 task may wire a `Tau.Memory.Writer` here
    # without changing the MCP surface.
    {:ok,
     encode(%{
       "available" => false,
       "reason" => "no writable memory layer configured (ADR-0006)",
       "kind" => kind,
       "key" => key,
       "body_size" => byte_size(body)
     })}
  end

  # ── tool: tau_delegate ────────────────────────────────────────

  @doc false
  @spec tau_delegate(map(), state()) ::
          {:ok, String.t()} | {:error, %{code: integer(), message: String.t()}}
  def tau_delegate(args, state) do
    prompt = Map.get(args, "prompt")
    agent = Map.get(args, "agent", "claude_code")
    depth = args |> Map.get("depth", 0) |> coerce_int(0)
    max_depth = Map.get(state, :max_depth, @default_max_depth) |> coerce_int(@default_max_depth)

    cond do
      not is_binary(prompt) or byte_size(prompt) == 0 ->
        {:error, %{code: -32_602, message: "missing or empty 'prompt'"}}

      depth >= max_depth ->
        {:ok,
         encode(%{
           "available" => false,
           "reason" => "max delegation depth reached",
           "depth" => depth,
           "max_depth" => max_depth
         })}

      true ->
        # Recursive delegation is gated on Phase 2 (Delegate tool
        # surface). For Phase 1B Team C we record intent and
        # return a structured "queued: false" so the agent can
        # plan without crashing.
        {:ok,
         encode(%{
           "available" => false,
           "reason" => "recursive delegation not wired (Phase 2)",
           "would_delegate" => %{
             "agent" => agent,
             "depth" => depth + 1,
             "max_depth" => max_depth,
             "prompt_size" => byte_size(prompt)
           }
         })}
    end
  end

  # ── helpers ───────────────────────────────────────────────────

  defp session_cwd(session_id) do
    case Tau.Session.snapshot(session_id) do
      {:ok, %{cwd: cwd}} when is_binary(cwd) -> cwd
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp coerce_int(n, _default) when is_integer(n) and n >= 0, do: n

  defp coerce_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp coerce_int(_, default), do: default

  defp encode(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      _ -> ~s({"available":false,"reason":"json encode failed"})
    end
  end

  # `snap.provider` is `module() | nil` per `Tau.Session.snapshot/1`.
  # Narrow clauses match dialyzer's inference; broader fallthroughs
  # (binaries, arbitrary terms) were unreachable per the spec.
  defp safe_inspect(nil), do: nil
  defp safe_inspect(v) when is_atom(v), do: Atom.to_string(v)
end

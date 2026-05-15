defmodule Tau.CodingAgent do
  @moduledoc """
  Behaviour for external coding-agent backends (Claude Code, Aider,
  Codex CLI, Gemini CLI, …).

  This is the parallel surface to `Tau.Provider`. Providers stream
  raw assistant tokens + tool-use events from an LLM API. Coding
  agents are CLI-driven *sub-agents* that take an end-to-end task
  (prompt + workspace) and run it themselves — including their own
  tool calls, edits, and (often) cost reporting.

  See `docs/spec/SPEC-CODING-AGENT.md` for the design rationale and
  the D-031..D-038 runtime invariants.

  ## Contract

  `start/2` returns `{:ok, Enumerable.t()}` whose elements are
  `Tau.CodingAgent.Event` structs. **It MUST NOT raise** for
  transport, auth, or parse errors — failures arrive in-stream as
  `%Tau.CodingAgent.Event.Error{}`. Hard configuration errors
  (executable not on PATH, malformed argv) may be returned
  synchronously as `{:error, reason}` from `start/2` (D-035).

  ## Cancellation

  `cancel/1` is honored by the dispatcher: for subprocess-backed
  adapters the dispatcher writes nothing further to stdin, sends
  SIGTERM, waits 250ms, then SIGKILL (D-032). For in-BEAM adapters
  (Replay) cancel halts emission cooperatively.

  ## Workspace

  `task.workspace` MUST be an explicit absolute path. The
  dispatcher MUST NOT silently inherit tau's cwd (D-033). Worktree
  creation, when requested, is handled by the caller (Phase 1B
  Team B); this behaviour only enforces the API contract.

  ## Implementations (current and planned)

    * `Tau.CodingAgents.Replay` — test fixture adapter (in-tree).
    * `Tau.CodingAgents.ClaudeCode` — first real adapter (Phase 1B).
  """

  @typedoc """
  A coding-agent task. The workspace path is mandatory and explicit
  (D-033) — adapters MUST refuse to spawn if the path does not
  exist or is not a directory.
  """
  @type task :: %{
          :prompt => String.t(),
          :workspace => Path.t(),
          optional(:session_id) => String.t(),
          optional(:resume_id) => String.t() | nil,
          optional(:allowed_tools) => [String.t()] | :all,
          optional(:mcp_servers) => [map()],
          optional(:timeout) => pos_integer() | :infinity
        }

  @typedoc """
  Per-run context. Mirrors `Tau.Provider`'s ctx in spirit: a place
  to thread the cancel flag and any per-run knobs an adapter
  understands.
  """
  @type ctx :: %{
          optional(:cancel_flag) => :counters.counters_ref(),
          optional(:request_id) => String.t(),
          optional(:session_id) => String.t(),
          optional(:inactivity_timeout_ms) => pos_integer() | :infinity,
          optional(atom()) => term()
        }

  @typedoc """
  Static capability snapshot. Used by the dispatcher and TUI to
  decide whether to expose features that require backend support
  (cost line items, resume, etc.).
  """
  @type capabilities :: %{
          streaming: boolean(),
          tool_restriction: boolean(),
          mcp_client: boolean(),
          session_resume: boolean(),
          cost_reporting: boolean(),
          workspace_isolation: :cwd | :worktree | :either
        }

  @callback start(task(), ctx()) :: {:ok, Enumerable.t()} | {:error, term()}

  @callback cancel(handle :: term()) :: :ok

  @callback capabilities() :: capabilities()

  @callback configure(map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks [configure: 1]

  @doc """
  Convenience entry-point analogous to `Tau.Provider.chat/4`. Drains
  the adapter's stream and returns the final `%Done{}` event plus
  the list of intermediate events.

  Errors:

    * Synchronous `{:error, reason}` from `start/2` surfaces
      unchanged — configuration errors (no executable, bad argv)
      the caller should fix.
    * An in-stream `%Tau.CodingAgent.Event.Error{recoverable: false}`
      produces `{:error, reason}` carrying the original event's
      reason. Recoverable errors are folded into the event list.
  """
  @spec run(module(), task(), ctx(), keyword()) ::
          {:ok, %{events: [Tau.CodingAgent.Event.t()], done: Tau.CodingAgent.Event.Done.t()}}
          | {:error, term()}
  def run(adapter, task, ctx \\ %{}, _opts \\ []) do
    with {:ok, stream} <- adapter.start(task, ctx) do
      drain(stream)
    end
  end

  defp drain(stream) do
    {events, terminal} =
      Enum.reduce_while(stream, {[], nil}, fn ev, {acc, _} ->
        case ev do
          %Tau.CodingAgent.Event.Error{recoverable: false} = err ->
            {:halt, {Enum.reverse([err | acc]), {:error, err.reason}}}

          %Tau.CodingAgent.Event.Done{} = done ->
            {:halt, {Enum.reverse([done | acc]), {:done, done}}}

          other ->
            {:cont, {[other | acc], nil}}
        end
      end)

    case terminal do
      {:done, done} -> {:ok, %{events: events, done: done}}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :stream_exhausted_without_done}
    end
  end
end

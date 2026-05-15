defmodule Tau.CodingAgent.Event do
  @moduledoc """
  Normalized event types yielded by `Tau.CodingAgent.start/2`.

  Adapters translate each backend's native event format (Claude
  Code stream-json, Aider's structured output, …) into this union.
  Consumers — session FSM, TUI, audit — pattern-match on the
  struct module and MUST NOT switch on agent type (D-031).

  Adapters MUST NOT raise across this boundary (D-035). Errors
  flow as `%Error{}` items.

  ## Why a parallel union to `Tau.Provider.Event`

  Provider events are token-level (`TextStart` / `TextDelta` /
  `ToolCallStart` / `ToolCallEnd`). Coding agents emit larger,
  higher-level events: an assistant turn, a tool use, a file edit
  that already happened. Folding the two into a single union
  would either over-fit the agent shape onto the provider's
  fine-grained model, or vice-versa. See SPEC §0 and Appendix B.
  """

  defmodule Start do
    @moduledoc "Coding-agent process has started. Identifies the adapter and the OS pid."
    @enforce_keys [:agent]
    defstruct [:agent, :version, :pid]

    @type t :: %__MODULE__{
            agent: atom(),
            version: String.t() | nil,
            pid: pid() | non_neg_integer() | nil
          }
  end

  defmodule AssistantText do
    @moduledoc "A chunk of assistant-visible text from the coding agent."
    @enforce_keys [:text]
    defstruct [:text, turn: 0]
    @type t :: %__MODULE__{text: String.t(), turn: integer()}
  end

  defmodule ToolUse do
    @moduledoc "The agent invoked a tool. `input` is the parsed JSON arguments map."
    @enforce_keys [:id, :name]
    defstruct [:id, :name, input: %{}]
    @type t :: %__MODULE__{id: String.t(), name: String.t(), input: map()}
  end

  defmodule ToolResult do
    @moduledoc "Result of a tool invocation. `is_error` is true when the tool reported failure."
    @enforce_keys [:tool_use_id]
    defstruct [:tool_use_id, content: "", is_error: false]

    @type t :: %__MODULE__{
            tool_use_id: String.t(),
            content: String.t(),
            is_error: boolean()
          }
  end

  defmodule FileEdit do
    @moduledoc """
    The coding agent edited (created/modified/deleted) a file. Emitted
    when the adapter can derive this from its event stream; not every
    backend produces it. Audit-only — the dispatcher does NOT apply
    the edit (the agent already did).
    """
    @enforce_keys [:path, :kind]
    defstruct [:path, :kind]

    @type kind :: :create | :modify | :delete
    @type t :: %__MODULE__{path: String.t(), kind: kind()}
  end

  defmodule Cost do
    @moduledoc """
    Adapter-reported cost. `tokens` is a free-form map so adapters
    can pass through their native shape (input/output/cache_read/
    cache_creation, etc.) without lossy normalisation. `usd` is
    nil when the adapter cannot compute it (e.g. Aider).
    """
    defstruct tokens: %{}, usd: nil, duration_ms: 0

    @type t :: %__MODULE__{
            tokens: map(),
            usd: float() | nil,
            duration_ms: non_neg_integer()
          }
  end

  defmodule Error do
    @moduledoc """
    Stream-level error. `recoverable` is true when emission may
    continue afterwards (a parse error on a single event, say);
    false for terminal failures (subprocess died, auth rejected,
    transport closed).
    """
    @enforce_keys [:reason]
    defstruct [:reason, recoverable: false]
    @type t :: %__MODULE__{reason: term(), recoverable: boolean()}
  end

  defmodule Done do
    @moduledoc """
    Terminal event. `exit_status` is the subprocess's exit code
    (or a synthetic sentinel: -1 for unexpected death, -2 for
    cancellation). `final_message` is the agent's wrap-up text
    when available.
    """
    @enforce_keys [:exit_status]
    defstruct [:exit_status, :final_message]

    @type t :: %__MODULE__{
            exit_status: integer(),
            final_message: String.t() | nil
          }
  end

  @type t ::
          Start.t()
          | AssistantText.t()
          | ToolUse.t()
          | ToolResult.t()
          | FileEdit.t()
          | Cost.t()
          | Error.t()
          | Done.t()
end

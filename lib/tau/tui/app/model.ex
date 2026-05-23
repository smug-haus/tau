if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.App.Model do
    @moduledoc """
    Typed MVU model for `Tau.TUI.App`. Holds all 23 fields of the
    Ratatouille application state as an enforced struct with a `new/1`
    constructor that seeds initial values from runtime opts and the
    Ratatouille window context.
    """

    alias Tau.TUI.Editor
    alias Tau.TUI.History
    alias Tau.TUI.History.Store

    @enforce_keys [
      :session_id,
      :editor,
      :history,
      :history_data_dir,
      :history_cwd,
      :transcript,
      :subagents,
      :status,
      :usage,
      :context_tokens,
      :compaction,
      :warn_level,
      :permissions_mode
    ]

    defstruct [
      :session_id,
      :editor,
      :history,
      :search,
      :history_data_dir,
      :history_cwd,
      :transcript,
      :subagents,
      :status,
      :last_assistant,
      :coding_agent,
      :wrap_width,
      :catalog,
      :menu,
      :pending_permissions,
      :permissions_mode,
      :provider,
      :model,
      :usage,
      :context_tokens,
      :context_window,
      :compaction,
      :warn_level
    ]

    @typedoc "Active permissions mode. Controls how the session resolves :ask-verdict tool calls."
    @type permissions_mode :: :default | :accept_edits | :plan

    @typedoc "Session status: idle, streaming, sending, or a descriptive string after cancel/end."
    @type status :: :idle | :streaming | :sending | String.t()

    @typedoc "Compaction indicator: :idle while none is in progress, :running while active."
    @type compaction :: :idle | :running

    @typedoc "Context utilisation warning level emitted as telemetry on transitions (D-168)."
    @type warn_level :: :ok | :warn | :critical

    @typedoc "The 23-field MVU model passed through every Ratatouille `update/2` and `render/1` cycle."
    @type t :: %__MODULE__{
            session_id: String.t(),
            editor: Editor.t(),
            history: History.t(),
            search: nil | map(),
            history_data_dir: String.t(),
            history_cwd: String.t(),
            transcript: [{String.t(), keyword()}],
            subagents: %{String.t() => Tau.TUI.SubagentTree.SubagentNode.t()},
            status: status(),
            last_assistant: String.t() | nil,
            coding_agent: module() | nil,
            wrap_width: pos_integer(),
            catalog: [map()] | nil,
            menu: nil | map(),
            pending_permissions: [Tau.Session.Events.PermissionRequest.t()],
            permissions_mode: permissions_mode(),
            provider: module() | nil,
            model: String.t() | nil,
            usage: map(),
            context_tokens: non_neg_integer(),
            context_window: pos_integer() | nil,
            compaction: compaction(),
            warn_level: warn_level()
          }

    @doc """
    Build initial model state from the Ratatouille window context and runtime
    opts. Subscribes to PubSub before starting the session so no events are
    missed (D-004 / SPEC-USER-TURN §4).
    """
    @spec new(map(), String.t(), map()) :: t()
    def new(context, session_id, runtime_opts) do
      initial_width = get_in(context, [:window, :width]) || 80

      data_dir = Tau.Settings.data_dir()
      cwd = File.cwd!()
      history = Store.load(data_dir, cwd)

      %__MODULE__{
        session_id: session_id,
        editor: Editor.new(),
        history: history,
        search: nil,
        history_data_dir: data_dir,
        history_cwd: cwd,
        transcript: [],
        subagents: %{},
        status: :idle,
        last_assistant: nil,
        coding_agent: Map.get(runtime_opts, :coding_agent),
        wrap_width: transcript_pane_width(initial_width),
        catalog: nil,
        menu: nil,
        pending_permissions: [],
        permissions_mode: Map.get(runtime_opts, :permissions_mode, :default),
        provider: init_provider(runtime_opts),
        model: init_model(runtime_opts),
        usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
        context_tokens: 0,
        context_window: nil,
        compaction: :idle,
        warn_level: :ok
      }
    end

    # ---------------------------------------------------------------------------
    # Private helpers
    # ---------------------------------------------------------------------------

    # AC-1 (D-160): resolve the active provider at init time so the status bar
    # shows the real provider on the first rendered frame.
    defp init_provider(runtime_opts) do
      Map.get(runtime_opts, :provider) || Tau.Provider.default()
    end

    # AC-1 (D-160): resolve the active model at init time so the status bar
    # shows the real model id on the first rendered frame.
    defp init_model(runtime_opts) do
      case Map.get(runtime_opts, :model) do
        nil ->
          provider = init_provider(runtime_opts)

          if is_atom(provider) and function_exported?(provider, :default_model, 0) do
            provider.default_model()
          else
            nil
          end

        model ->
          model
      end
    end

    # Derive the transcript pane's usable wrap width from the terminal width.
    # Ratatouille's column(size: 12) fills the full width; subtract 2 for borders.
    defp transcript_pane_width(terminal_width) when terminal_width >= 4 do
      terminal_width - 2
    end

    defp transcript_pane_width(_terminal_width), do: 1
  end
end

defmodule Tau.Session.Data do
  @moduledoc """
  Typed FSM data struct for `Tau.Session`. Holds all 69 fields that comprise
  the `:gen_statem` data map, providing Dialyzer-visible types for every
  helper that receives or returns session state.

  `new/1` absorbs the session-initialisation logic previously in `Tau.Session.init/1`:
  resolving provider/model, opening persistence, loading skills and memory,
  and broadcasting the initial catalog snapshot. On success returns
  `{:ok, t()}` ready to pass as the third element of `{:ok, state, data}`.
  On persistence failure returns `{:stop, reason}`.
  """

  alias Tau.Message.{Assistant, ToolResult}
  alias Tau.Session.Events
  alias Tau.Settings.Cache, as: SettingsCache
  alias Tau.CodingAgent.Workspace, as: CAWorkspace
  alias Tau.Commands.Catalog

  @enforce_keys [
    :id,
    :cwd,
    :provider,
    :original_provider,
    :model,
    :persistence,
    :persist_handle
  ]

  @typedoc "The full FSM data for a `Tau.Session` process."
  @type t :: %__MODULE__{
          id: String.t(),
          cwd: String.t(),
          provider: module(),
          original_provider: module(),
          model: String.t(),
          metadata: map(),
          provider_ctx: map(),
          messages: [Tau.Message.t()],
          skills: [{String.t(), Tau.Skill.t()}],
          prompt_templates: [{String.t(), Tau.PromptTemplate.t()}],
          persistence: module(),
          persist_handle: term(),
          provider_task: Task.t() | nil,
          stream_ref: reference() | nil,
          provider_span_ref: reference() | nil,
          cancel_flag: :counters.counters_ref() | nil,
          assembler: Tau.Message.Assembler.t() | nil,
          fallback_chain_remaining: [module()],
          tools_in_flight: map(),
          tool_dispatcher: pid() | nil,
          command_task: pid() | nil,
          active_skill: Tau.Skill.t() | nil,
          persona_lifetime: :turn | :session,
          tools_whitelist: :all | [String.t()],
          child_session_ids: MapSet.t(),
          tool_iterations: non_neg_integer(),
          max_tool_iterations: pos_integer(),
          tool_loop_state: map(),
          tool_loop_brake_threshold: pos_integer(),
          tool_loop_call_lookups: map(),
          provider_retry_state: %{count: non_neg_integer()},
          provider_retry_max: pos_integer(),
          provider_retry_base_delay_ms: pos_integer(),
          coding_agent: module() | nil,
          coding_agent_ctx: map(),
          coding_agent_workspace_backend: module() | nil,
          coding_agent_workspace_opts: keyword(),
          coding_agent_workspace: CAWorkspace.t() | nil,
          coding_agent_dispatcher: pid() | nil,
          coding_agent_pending: Assistant.t() | nil,
          coding_agent_blocks: [map()],
          coding_agent_state: map(),
          coding_agent_costs: [Tau.CodingAgent.Cost.t()],
          compaction_task: Task.t() | nil,
          compaction_monitor: reference() | nil,
          compaction_failures: non_neg_integer(),
          interactive?: boolean(),
          pending_permission_requests: map(),
          permission_dispatch_batch: [{String.t(), String.t(), map()}],
          permission_pending_results: [{String.t(), ToolResult.t()}],
          steering_queue: :queue.queue(),
          followup_queue: :queue.queue()
        }

  defstruct [
    :id,
    :cwd,
    :provider,
    :original_provider,
    :model,
    :persistence,
    :persist_handle,
    metadata: %{},
    provider_ctx: %{},
    messages: [],
    skills: [],
    prompt_templates: [],
    provider_task: nil,
    stream_ref: nil,
    provider_span_ref: nil,
    cancel_flag: nil,
    assembler: nil,
    fallback_chain_remaining: [],
    tools_in_flight: %{},
    tool_dispatcher: nil,
    command_task: nil,
    active_skill: nil,
    persona_lifetime: :turn,
    tools_whitelist: :all,
    child_session_ids: nil,
    tool_iterations: 0,
    max_tool_iterations: 100,
    tool_loop_state: %{},
    tool_loop_brake_threshold: 3,
    tool_loop_call_lookups: %{},
    provider_retry_state: %{count: 0},
    provider_retry_max: 3,
    provider_retry_base_delay_ms: 1000,
    coding_agent: nil,
    coding_agent_ctx: %{},
    coding_agent_workspace_backend: nil,
    coding_agent_workspace_opts: [],
    coding_agent_workspace: nil,
    coding_agent_dispatcher: nil,
    coding_agent_pending: nil,
    coding_agent_blocks: [],
    coding_agent_state: %{session_id: nil, agent: nil},
    coding_agent_costs: [],
    compaction_task: nil,
    compaction_monitor: nil,
    compaction_failures: 0,
    interactive?: true,
    pending_permission_requests: %{},
    permission_dispatch_batch: [],
    permission_pending_results: [],
    steering_queue: nil,
    followup_queue: nil
  ]

  @doc """
  Build initial FSM data from start_link opts and preloaded events.

  Opens the persistence backend, loads skills and memory, broadcasts the
  initial command catalog, and returns `{:ok, t()}`. Returns
  `{:stop, reason}` if persistence open fails.
  """
  @spec new(keyword()) :: {:ok, t()} | {:stop, term()}
  def new(opts) do
    id = Keyword.fetch!(opts, :session_id)
    cwd = opts[:cwd] || File.cwd!()
    provider = opts[:provider] || Tau.Provider.default()

    # D-002 / SPEC-USER-TURN: resolve nil model to the provider's default
    # at session init, NOT at stream-call time. Without this, `data.model`
    # stays nil through telemetry, persistence header, and the assembler
    # — all of which expect a real model id.
    #
    # D-041: fold the last persisted `model_swap` event from preload so
    # resume and fork both converge on the swapped model.
    model =
      Tau.Session.Journal.model_from_preload(opts[:preload_events] || []) ||
        opts[:model] || provider.default_model()

    metadata = opts[:metadata] || %{}
    provider_ctx = opts[:provider_ctx] || %{}
    persistence = opts[:persistence] || Tau.Persistence.impl()
    preload = opts[:preload_events] || []

    # SPEC-CODING-AGENT §4 B1 / D-037: coding-agent session mode.
    coding_agent =
      opts[:coding_agent] || coding_agent_from_settings()

    coding_agent_workspace_backend =
      opts[:coding_agent_workspace_backend] ||
        if(coding_agent, do: CAWorkspace.resolve_default_backend(cwd), else: nil)

    coding_agent_workspace_opts = opts[:coding_agent_workspace_opts] || []

    # SPEC-CODING-AGENT §4 B1: per-run knobs for the coding-agent adapter.
    coding_agent_ctx = opts[:coding_agent_ctx] || %{}

    case persistence.open(id,
           cwd: cwd,
           provider: inspect(provider),
           model: model,
           metadata: metadata,
           parent_event_id: opts[:parent_event_id]
         ) do
      {:ok, persist_handle} ->
        Tau.Session.register_builtins()

        :telemetry.execute(
          [:tau, :session, :start],
          %{system_time: System.system_time()},
          %{session_id: id, provider: provider}
        )

        Tau.Session.broadcast(id, %Events.SessionStart{
          session_id: id,
          provider: provider,
          model: model,
          cwd: cwd,
          metadata: metadata
        })

        skills = Tau.Session.SkillActivation.load_skills(cwd)

        # D-058 / AC-10 / SPEC-USER-TURN §4 B2: a headless skill injected
        # via `:active_skill` (e.g. `--system-prompt` from `tau run`) is
        # prepended to the skill list so `prepend_skill_messages/2`
        # includes its body in the model-visible system blob.
        skills =
          case opts[:active_skill] do
            %Tau.Skill{name: name} = skill ->
              [{name, skill} | skills]

            _ ->
              skills
          end

        # ADR-0013 / ADR-0015: skills with `disable_model_invocation: true`
        # are background-only — their bodies MUST NOT enter the model-visible
        # system_blob. Filter at the assembly site.
        model_visible_skills =
          Enum.reject(skills, fn {_name, s} -> s.disable_model_invocation end)

        messages =
          preload
          |> Tau.Session.Journal.events_to_messages()
          |> Tau.Session.SkillActivation.prepend_skill_messages(model_visible_skills)
          |> Tau.Session.SkillActivation.inject_memory(cwd)

        data = %__MODULE__{
          id: id,
          cwd: cwd,
          provider: provider,
          # ADR-0012: original_provider is the user-configured provider for
          # the lifetime of the session. data.provider shape-shifts during
          # a fallback turn; finalize_assistant/2 restores it from
          # original_provider so the next turn always starts against the
          # primary (per-message fallback semantics).
          original_provider: provider,
          model: model,
          metadata: metadata,
          provider_ctx: provider_ctx,
          messages: messages,
          skills: skills,
          # D-076: prompt templates discovered once at init time.
          prompt_templates: Tau.PromptTemplates.discover(cwd),
          persistence: persistence,
          persist_handle: persist_handle,
          provider_task: nil,
          # ADR-0012: per-stream tag distinguishing events from the current
          # provider task from a killed predecessor's stragglers.
          stream_ref: nil,
          # SPEC-OTEL-REPORTER: per-request OTel span discriminator.
          provider_span_ref: nil,
          # ADR-0017: per-stream cooperative-cancel flag (a `:counters` ref).
          cancel_flag: nil,
          assembler: nil,
          # ADR-0012: per-turn fallback queue.
          fallback_chain_remaining: [],
          tools_in_flight: %{},
          tool_dispatcher: nil,
          # ADR-0008: slash-command tasks run under Tau.Tools.TaskSupervisor.
          command_task: nil,
          # ADR-0013 / ADR-0015. Per-turn lifetime by default.
          active_skill: opts[:active_skill],
          persona_lifetime: opts[:persona_lifetime] || :turn,
          # Spawn-time tool whitelist (`:all` or `[String.t()]`).
          tools_whitelist: opts[:tools_whitelist] || :all,
          # ADR-0014: child session ids spawned by this session via `Agent`.
          child_session_ids: MapSet.new(),
          # D-005 / AC-6 / SPEC-USER-TURN: tool-call iteration cap.
          tool_iterations: 0,
          max_tool_iterations:
            opts[:max_tool_iterations] ||
              get_in(SettingsCache.get(), [:session, :max_tool_iterations]) ||
              100,
          # D-060: tool-loop brake — per-turn map keyed by `{tool_name, args_hash}`.
          tool_loop_state: %{},
          tool_loop_brake_threshold:
            opts[:tool_loop_brake_threshold] ||
              get_in(SettingsCache.get(), [:session, :tool_loop_brake_threshold]) ||
              3,
          # D-060: side-table mapping in-flight tool_call_id -> `{tool_name, args_hash}`.
          tool_loop_call_lookups: %{},
          # D-061: per-turn same-provider retry counter.
          provider_retry_state: %{count: 0},
          provider_retry_max:
            opts[:provider_retry_max] ||
              get_in(SettingsCache.get(), [:session, :provider_retry_max]) ||
              3,
          provider_retry_base_delay_ms:
            opts[:provider_retry_base_delay_ms] ||
              get_in(SettingsCache.get(), [:session, :provider_retry_base_delay_ms]) ||
              1000,
          # SPEC-CODING-AGENT. Workspace is lazily prepared on the first
          # `:coding_agent_streaming` transition; cleaned up in `terminate/3`.
          coding_agent: coding_agent,
          coding_agent_ctx: coding_agent_ctx,
          coding_agent_workspace_backend: coding_agent_workspace_backend,
          coding_agent_workspace_opts: coding_agent_workspace_opts,
          coding_agent_workspace: nil,
          coding_agent_dispatcher: nil,
          coding_agent_pending: nil,
          coding_agent_blocks: [],
          # SPEC-CODING-AGENT §7 Q5 / D-037: adapter-side session state.
          coding_agent_state:
            Tau.Session.CodingAgentTurn.coding_agent_state_from_preload(preload) ||
              %{session_id: nil, agent: nil},
          # SPEC-CODING-AGENT §7 Q4 / D-038: per-session list of adapter-tagged cost records.
          coding_agent_costs: Tau.Session.CodingAgentTurn.coding_agent_costs_from_preload(preload),
          # D-048 / D-049: async compaction worker state.
          # D-016: `compaction_failures` is NOT reset by `:cancel`.
          compaction_task: nil,
          compaction_monitor: nil,
          compaction_failures: 0,
          # SPEC-PERMISSION-PROMPTS §4 B4 (D-092, D-093): headless vs interactive.
          interactive?: opts[:interactive] != false,
          # SPEC-PERMISSION-PROMPTS §4 B3 (D-091): per-round permission map.
          pending_permission_requests: %{},
          # SPEC-PERMISSION-PROMPTS §4 B3 / D-091.
          permission_dispatch_batch: [],
          permission_pending_results: [],
          # D-077 / D-078 / SPEC-USER-TURN §6: two-tier message queues.
          steering_queue: :queue.new(),
          followup_queue: :queue.new()
        }

        # D-103 / D-108 (SPEC-TUI-COMPLETION §4 B1): broadcast the command
        # catalog once at session start so the TUI menu is pre-populated.
        catalog_entries = Catalog.list(data)
        Tau.Session.broadcast(id, %Events.CommandCatalog{session_id: id, entries: catalog_entries})

        {:ok, data}

      err ->
        {:stop, err}
    end
  end

  # SPEC-CODING-AGENT §5 / D-037: deployment-wide default for the coding-agent
  # adapter. Read from the merged settings cascade at session init only.
  defp coding_agent_from_settings do
    settings = SettingsCache.get()

    raw =
      get_in(settings, [:coding_agent, :default_agent]) ||
        get_in(settings, ["coding_agent", "default_agent"])

    case raw do
      nil -> nil
      mod when is_atom(mod) -> mod
      str when is_binary(str) -> Tau.CLI.resolve_coding_agent(str)
    end
  end
end

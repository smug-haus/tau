defmodule Tau.Hook do
  @moduledoc """
  Behaviour for blocking lifecycle hooks.

  Events:

    * `:session_start`        — session FSM has just registered
    * `:user_prompt_submit`   — user message about to be appended
    * `:pre_tool_use`         — tool dispatch about to begin
    * `:post_tool_use`        — tool returned successfully
    * `:post_tool_use_failure` — tool returned `is_error: true` (or crashed)
    * `:stop`                 — session is about to terminate
    * `:pre_compact`          — compactor is about to run
    * `:subagent_start`       — a sub-agent (Task) is about to be spawned
    * `:file_changed`         — extension/settings file watcher fired
    * `:notification`         — generic event, used by the TUI

  ## Payload contract

  Every payload carries the canonical Phase-10 fields (set by
  `Tau.Session.hook_payload/3`):

    * `:session_id` — the owning session id (binary)
    * `:cwd` — working directory the session operates from (binary)
    * `:permission_mode` — atom (`:default | :accept_edits | …`)
    * `:hook_event_name` — string form of the event name
    * `:transcript_path` — non-nil binary identifying where the
      transcript can be retrieved. For file backends this is an
      absolute path; for others, a backend-specific pseudo-URI
      (see `Tau.Persistence.path_for/2`). Hooks reading the path
      while the session is still appending may see partially-flushed
      JSONL — treat parse failures on the trailing line as
      "in-flight, retry later" rather than fatal.
    * `:metadata` — the session's user-supplied metadata map

  Plus event-specific extras (`:message`, `:tool_name`,
  `:tool_call_id`, `:tool_input`, `:result`, …).

  Hook return values:

    * `:cont`             — proceed normally
    * `{:cont, payload}`  — proceed with the rewritten payload
    * `{:halt, reason}`   — abort the action; reason becomes the user-facing error
    * `{:deny, msg}`      — same as `:halt` but specifically for permissions
  """

  @type event ::
          :session_start
          | :user_prompt_submit
          | :pre_tool_use
          | :post_tool_use
          | :post_tool_use_failure
          | :stop
          | :pre_compact
          | :subagent_start
          | :file_changed
          | :notification

  @type result ::
          :cont
          | {:cont, map()}
          | {:halt, term()}
          | {:deny, String.t()}

  @callback events() :: [event()]
  @callback handle(event(), payload :: map()) :: result()
end

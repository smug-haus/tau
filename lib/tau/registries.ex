defmodule Tau.Registries do
  @moduledoc """
  Top-level container for the harness's `Registry` processes.

  Registries are a concurrency primitive (not a state container) — they map
  keys (atoms or strings) to process pids and metadata, with auto-cleanup on
  process death. We use them everywhere a "lookup table" might be tempting
  in an OO codebase.

    * `Tau.Tools.Registry` — `:duplicate`, partitioned by scheduler count.
      Built-in tools, MCP-derived tools, and extension tools all register
      here under their public name. MCP-derived tools register under
      `mcp__<server_name>__<tool_name>` (double-underscore separator;
      both segments are dynamic — see `Tau.MCP.Server`).

      The registry is `:duplicate` (not `:unique`) because built-in tools
      are registered *per session* by `Tau.Session.init/1`
      (`register_builtins/0`): `Registry.register/3` makes the *calling*
      process the entry owner. Under a `:unique` registry only the first
      session to boot owned a tool; every later session's registration was
      silently rejected as `{:already_registered, _}`. When that first
      session terminated, the tool was deregistered out from under every
      other still-live session, so concurrent sessions lost tool access
      (issue #250). Under a `:duplicate` registry each session holds its
      own claim, so a tool stays registered as long as *any* session that
      registered it is alive. All registrants for a given tool name carry
      the same module value, so `Tau.Tool.lookup/1` resolves against the
      first entry.

    * `Tau.Hooks.Registry` — `:duplicate`, keyed by event atom. Multiple
      hooks may listen on the same event; dispatch is deterministic by
      registration source priority.

    * `Tau.Commands.Registry` — `:unique`, keyed by slash-command name
      (e.g. `"/deploy"`).

    * `Tau.Skills.Registry` — `:unique`, keyed by skill name.

    * `Tau.Sessions.Registry` — `:unique`, keyed by `session_id`. Session
      FSMs register themselves here on init so callers can address them
      by id without holding pid references.

    * `Tau.Providers.RateLimiter.Registry` — `:unique`, keyed by provider
      module. One `Tau.Providers.RateLimiter` GenServer registers per
      configured provider (ADR-0011).
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry,
       keys: :duplicate, name: Tau.Tools.Registry, partitions: System.schedulers_online()},
      {Registry, keys: :duplicate, name: Tau.Hooks.Registry},
      {Registry, keys: :unique, name: Tau.Commands.Registry},
      {Registry, keys: :unique, name: Tau.Skills.Registry},
      {Registry, keys: :unique, name: Tau.Sessions.Registry},
      {Registry, keys: :unique, name: Tau.MCP.Registry},
      {Registry, keys: :unique, name: Tau.Providers.RateLimiter.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

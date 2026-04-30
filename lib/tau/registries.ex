defmodule Tau.Registries do
  @moduledoc """
  Top-level container for the harness's `Registry` processes.

  Registries are a concurrency primitive (not a state container) — they map
  keys (atoms or strings) to process pids and metadata, with auto-cleanup on
  process death. We use them everywhere a "lookup table" might be tempting
  in an OO codebase.

    * `Tau.Tools.Registry` — `:unique`, partitioned by scheduler count.
      Built-in tools, MCP-derived tools, and extension tools all register
      here under their public name. MCP tools use `mcp__server__name`.

    * `Tau.Hooks.Registry` — `:duplicate`, keyed by event atom. Multiple
      hooks may listen on the same event; dispatch is deterministic by
      registration source priority.

    * `Tau.Commands.Registry` — `:unique`, keyed by slash-command name
      (e.g. `"/deploy"`).

    * `Tau.Skills.Registry` — `:unique`, keyed by skill name.

    * `Tau.Sessions.Registry` — `:unique`, keyed by `session_id`. Session
      FSMs register themselves here on init so callers can address them
      by id without holding pid references.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry,
       keys: :unique,
       name: Tau.Tools.Registry,
       partitions: System.schedulers_online()},
      {Registry, keys: :duplicate, name: Tau.Hooks.Registry},
      {Registry, keys: :unique, name: Tau.Commands.Registry},
      {Registry, keys: :unique, name: Tau.Skills.Registry},
      {Registry, keys: :unique, name: Tau.Sessions.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

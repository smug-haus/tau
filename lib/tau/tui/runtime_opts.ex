defmodule Tau.TUI.RuntimeOpts do
  @moduledoc """
  Per-invocation runtime opts for the TUI's session start.

  The TUI is launched via `Tau.TUI.start/1`, which sets these opts
  immediately before calling `Tau.TUI.App.run/0`. `Tau.TUI.App.init/1`
  reads them when it calls `Tau.start_session/1`. This is the seam for
  CLI-supplied flags like `--provider` and `--model` that must reach
  the session FSM but cannot pass through Ratatouille's fixed-arity
  `App.init/1` callback.

  Storage is `:persistent_term` (lock-free reads, atomic publish)
  matching the pattern used by `Tau.Permissions.RuleSet` and
  `Tau.Settings.Cache` (ADR-0002, ADR-0004). Cleared on session end so
  a subsequent TUI launch in the same BEAM does not inherit stale opts.

  Recognised keys:

    * `:provider` — provider module atom (e.g. `Tau.Providers.Replay`)
    * `:model` — model id string
    * `:provider_ctx` — provider-scoped runtime context map (ADR-0002)
  """

  @key {Tau.TUI, :runtime_opts}

  @spec set(keyword() | map()) :: :ok
  def set(opts) when is_list(opts), do: set(Map.new(opts))

  def set(opts) when is_map(opts) do
    :persistent_term.put(@key, opts)
  end

  @spec get() :: map()
  def get, do: :persistent_term.get(@key, %{})

  @spec clear() :: boolean()
  def clear, do: :persistent_term.erase(@key)
end

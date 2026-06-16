defmodule Tau.Factory.AgentBin do
  @moduledoc """
  Config-gated `agent_bin` selector (D-376, SPEC-FACTORY-FLEET §4 B4-A1).

  `resolve/1` reads the `:agent_mode` key from the supplied keyword list
  (typically `Application.get_env(:tau, :factory, [])` merged with
  call-site overrides) and returns `{agent_bin_path, spawn_opts}`.

  ## Modes

    - `:claude_code` — writes a `Tau.Factory.CodingAgentShim` executable
      with `Tau.CodingAgents.ClaudeCode` baked in as the adapter. Returns
      `spawn_opts` containing `[agent_mode: :claude_code]` so the Worker's
      `open_port_and_finish/1` path fires the D-374 metered-API preflight
      and credential scrub.

    - `:scripted` / `:replay` / absent — resolves to the existing
      `Tau.Factory.Dogfood.Agent` scripted binary. Returns
      `spawn_opts = []` (no `:claude_code` threading). Behaviour is
      unchanged from today and the existing dogfood gates are unaffected.

  ## D-357 gate

  The default (absent `agent_mode`) MUST NOT activate `:claude_code`.
  Real-agent mode is **off** by default; it is activated only when the
  caller explicitly supplies `agent_mode: :claude_code`.

  ## Pure function — no process state

  `resolve/1` is a pure function. It writes a shim file to a temp path
  when `:claude_code` is requested (a required side-effect for producing
  the executable), but holds no process state.
  """

  alias Tau.Factory.CodingAgentShim
  alias Tau.Factory.Dogfood.Agent, as: DogfoodAgent

  @doc """
  Resolve the `agent_bin` for the given factory opts.

  Accepts a keyword list — typically the merged result of
  `Application.get_env(:tau, :factory, [])` and any call-site overrides.

  Returns `{agent_bin_path :: String.t(), spawn_opts :: keyword()}`.

  When `opts[:agent_mode]` is `:claude_code`:
    - Writes a `CodingAgentShim` executable (adapter: `Tau.CodingAgents.ClaudeCode`,
      branch: `opts[:branch]`) to a unique temp path.
    - Returns `spawn_opts = [agent_mode: :claude_code]` so the Worker fires the
      D-374 preflight + credential scrub.

  For any other `agent_mode` value (`:scripted`, `:replay`, or absent):
    - Writes the `Tau.Factory.Dogfood.Agent` scripted binary to a temp path.
    - Returns `spawn_opts = []`.
  """
  @spec resolve(keyword()) :: {String.t(), keyword()}
  def resolve(opts) do
    case Keyword.get(opts, :agent_mode) do
      :claude_code ->
        resolve_claude_code(opts)

      _other ->
        resolve_scripted()
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_claude_code(opts) do
    dest_path = unique_tmp_path("tau_agentbin_claude_code")

    branch = Keyword.get(opts, :branch, "main")

    # D-389: do NOT thread skip_permissions from factory opts into the shim config.
    # The factory path MUST NOT bake skip_permissions: true unconditionally.
    # The escape hatch for --dangerously-skip-permissions is retained at the
    # Argv.build/2 level via task.skip_permissions (set on the task, not the shim
    # config). The CodingAgentShim.write default of skip_permissions: false is correct.
    CodingAgentShim.write(dest_path,
      adapter: Tau.CodingAgents.ClaudeCode,
      branch: branch
    )

    {dest_path, [agent_mode: :claude_code]}
  end

  defp resolve_scripted do
    dest_path = unique_tmp_path("tau_agentbin_scripted")
    DogfoodAgent.write(dest_path)
    {dest_path, []}
  end

  defp unique_tmp_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:erlang.unique_integer([:positive])}")
  end
end

defmodule Tau.Factory.AgentBinTest do
  @moduledoc """
  Gating tests for PR #512 (issue #511 — AgentBin selector, D-376).

  Written BEFORE production code exists (oracle-separation, factory-loop §4b).
  All tests MUST FAIL against the current branch because:
    - `Tau.Factory.AgentBin` does not exist yet.
    - Calling `Tau.Factory.AgentBin.resolve/1` raises `UndefinedFunctionError`.

  ## Contract under test (D-376)

  `Tau.Factory.AgentBin.resolve/1` reads `config :tau, :factory, agent_mode`
  and returns `{agent_bin_path, spawn_opts}`:

    - `:claude_code` → the written shim's baked config names
      `Tau.CodingAgents.ClaudeCode` as the adapter, AND the returned
      spawn_opts carry `agent_mode: :claude_code`.

    - `:scripted` / `:replay` / absent → resolves to the prior agent_bin shape
      (Replay shim / scripted binary), and the returned spawn_opts do NOT
      contain `agent_mode: :claude_code`.

  `resolve/1` accepts a keyword list of options (typically forwarding
  `Application.get_env(:tau, :factory, [])`) so tests can inject the
  config without mutating persistent application state.

  ## Pinned interface (oracle-declared; implementer MUST conform)

      Tau.Factory.AgentBin.resolve(opts :: keyword()) ::
        {agent_bin_path :: String.t(), spawn_opts :: keyword()}

    where `opts` may carry:
      - `:agent_mode` — atom; selects the agent bin variant. When absent
                        (or any non-`:claude_code` atom) the prior behaviour
                        is used. `:claude_code` activates real-agent mode.
      - `:branch`     — String; required; forwarded to the shim (branch to
                        commit to). SPEC gap: if the implementer requires
                        additional options, they MUST be documented in
                        SPEC-FACTORY-FLEET §4 B4-A1 before landing.

  ## AC / D-NNN linkage

  All tests carry `@tag :d_376`.
  """

  use ExUnit.Case, async: false

  alias Tau.CodingAgents.ClaudeCode
  alias Tau.Factory.AgentBin

  @tag :d_376
  test "D-376: :claude_code mode — resolve/1 returns a shim whose adapter is Tau.CodingAgents.ClaudeCode" do
    tmp_dir = System.tmp_dir!()
    opts = [agent_mode: :claude_code, branch: "feat/test-d-376"]

    {agent_bin_path, _spawn_opts} = AgentBin.resolve(opts)

    assert is_binary(agent_bin_path),
           "D-376: resolve/1 must return a {String.t(), keyword()} tuple; got agent_bin_path=#{inspect(agent_bin_path)}"

    assert File.exists?(agent_bin_path),
           "D-376: agent_bin_path #{agent_bin_path} must exist on disk"

    script = File.read!(agent_bin_path)

    # Extract the base64-encoded config baked into the shim script.
    # Tau.Factory.CodingAgentShim.write/2 embeds the config as:
    # encoded = %{...} |> :erlang.term_to_binary() |> Base.encode64(padding: false)
    # and writes it into the script as:   encoded = "<base64_string>"
    assert [_, encoded_config] = Regex.run(~r/encoded = \\"([A-Za-z0-9+\/]+=*)\\"/, script),
           "D-376: script must contain a baked base64-encoded config; script head=#{String.slice(script, 0, 200)}"

    decoded_config =
      encoded_config
      |> Base.decode64!(padding: false)
      |> :erlang.binary_to_term()

    assert decoded_config.adapter == ClaudeCode,
           "D-376: :claude_code shim adapter must be Tau.CodingAgents.ClaudeCode, got #{inspect(decoded_config.adapter)}"

    # Cleanup
    File.rm(agent_bin_path)
    _ = tmp_dir
  end

  @tag :d_376
  test "D-376: :claude_code mode — resolve/1 spawn_opts carry agent_mode: :claude_code" do
    opts = [agent_mode: :claude_code, branch: "feat/test-d-376-spawn-opts"]

    {agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    assert Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: spawn_opts must include agent_mode: :claude_code for :claude_code mode; got #{inspect(spawn_opts)}"

    # Cleanup
    File.rm(agent_bin_path)
  end

  @tag :d_376
  test "D-376: :scripted mode — resolve/1 does not set agent_mode: :claude_code in spawn_opts" do
    opts = [agent_mode: :scripted]

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: :scripted mode must NOT produce agent_mode: :claude_code in spawn_opts; got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: :replay mode — resolve/1 does not set agent_mode: :claude_code in spawn_opts" do
    opts = [agent_mode: :replay]

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: :replay mode must NOT produce agent_mode: :claude_code in spawn_opts; got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: absent agent_mode (default) — resolve/1 does not activate :claude_code (D-357 gated OFF)" do
    opts = []

    {_agent_bin_path, spawn_opts} = AgentBin.resolve(opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: absent agent_mode must NOT produce agent_mode: :claude_code (D-357 gated OFF); got #{inspect(spawn_opts)}"
  end

  @tag :d_376
  test "D-376: absent agent_mode reads from Application.get_env(:tau, :factory) when no opts provided" do
    # Verify resolve/0 (or resolve([]) reading app env) does not default to :claude_code
    # when app env does not contain agent_mode: :claude_code.
    prior = Application.get_env(:tau, :factory, [])

    on_exit(fn ->
      Application.put_env(:tau, :factory, prior)
    end)

    Application.put_env(:tau, :factory, Keyword.delete(prior, :agent_mode))

    factory_opts = Application.get_env(:tau, :factory, [])
    {_agent_bin_path, spawn_opts} = AgentBin.resolve(factory_opts)

    refute Keyword.get(spawn_opts, :agent_mode) == :claude_code,
           "D-376: when factory config has no agent_mode, resolve/1 must not activate :claude_code; got #{inspect(spawn_opts)}"
  end
end

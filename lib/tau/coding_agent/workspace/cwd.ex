defmodule Tau.CodingAgent.Workspace.Cwd do
  @moduledoc """
  Passthrough workspace — the coding agent operates directly in the
  session's cwd (SPEC-CODING-AGENT §4 B3, opt-in surface).

  Selected automatically when the user invoked tau outside a git
  repository (so `Workspace.Git` would refuse) and explicitly when the
  caller passes `backend: Tau.CodingAgent.Workspace.Cwd`. Replay-based
  tests use this backend so they don't need a real git repo.

  No state is allocated: `prepare/1` simply validates that `:cwd` is an
  absolute path to an existing directory and wraps it in a
  `%Workspace{}`. `cleanup/1` is a no-op — the user's cwd is sacred.
  """

  @behaviour Tau.CodingAgent.Workspace

  alias Tau.CodingAgent.Workspace

  @impl Tau.CodingAgent.Workspace
  def prepare(opts) do
    cwd = Keyword.fetch!(opts, :cwd)

    cond do
      not is_binary(cwd) ->
        {:error, {:workspace_invalid, :cwd_not_binary}}

      not File.dir?(cwd) ->
        {:error, {:workspace_invalid, {:cwd_not_a_directory, cwd}}}

      true ->
        ws = %Workspace{backend: __MODULE__, path: Path.expand(cwd)}

        :telemetry.execute(
          [:tau, :coding_agent, :workspace, :prepared],
          %{system_time: System.system_time()},
          %{backend: __MODULE__, path: ws.path}
        )

        {:ok, ws}
    end
  end

  @impl Tau.CodingAgent.Workspace
  def cleanup(%Workspace{backend: __MODULE__}) do
    # No-op: never delete the user's working tree.
    :ok
  end
end

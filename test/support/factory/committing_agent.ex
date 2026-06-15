defmodule Tau.Factory.TestAdapters.CommittingAgent do
  @moduledoc """
  Test-only `Tau.CodingAgent` adapter for D-386 gating tests.

  Simulates a real coding agent (e.g. ClaudeCode) that actually `git commit`s
  its work product before emitting `%Done{exit_status: 0}`, leaving the
  worktree with HEAD advanced and a CLEAN working tree.

  This is the adapter case D-386 calls "agent commits, clean tree": HEAD ≠ base
  at the point the shim inspects `git status --porcelain`, so the current shim's
  dirty-tree-only detection (`git status --porcelain` → `:empty`) incorrectly
  routes to `:no_work_product`.

  NOT for use outside `test/`. No production code path reaches this module.
  """

  @behaviour Tau.CodingAgent

  alias Tau.CodingAgent.Event

  @impl Tau.CodingAgent
  def capabilities do
    %{
      streaming: true,
      tool_restriction: false,
      mcp_client: false,
      session_resume: false,
      cost_reporting: false,
      workspace_isolation: :cwd
    }
  end

  @impl Tau.CodingAgent
  def configure(opts) when is_map(opts), do: {:ok, opts}

  @doc """
  Start the committing agent stream.

  Accepts `task.workspace` as the git repo root. When streamed:
    1. Writes `agent_work.txt` into `task.workspace`.
    2. Runs `git add -A && git commit` inside the workspace, simulating the
       real claude subprocess committing its own work.
    3. Emits `%Done{exit_status: 0}` — leaving HEAD advanced and tree CLEAN.

  The committed SHA is NOT communicated via the event stream (real agents don't
  do this either). The shim must detect the HEAD advance itself (D-386 contract).
  """
  @impl Tau.CodingAgent
  def start(task, _ctx) when is_map(task) do
    workspace = Map.fetch!(task, :workspace)

    stream =
      Stream.resource(
        fn -> :pending end,
        fn
          :pending ->
            # Write a file into the workspace and commit it — simulating a real
            # coding agent that commits its own work product inside the worktree.
            file_path = Path.join(workspace, "agent_work.txt")
            File.write!(file_path, "work product written by CommittingAgent\n")

            # git add -A
            {_, 0} =
              System.cmd("git", ["add", "-A"],
                cd: workspace,
                stderr_to_stdout: true
              )

            # git commit
            {_, 0} =
              System.cmd(
                "git",
                ["commit", "-m", "agent work product (CommittingAgent test adapter, D-386)"],
                cd: workspace,
                stderr_to_stdout: true
              )

            events = [
              %Event.Start{agent: :committing_agent, version: "0.0.0-test", pid: nil},
              %Event.AssistantText{text: "I committed my work directly.", turn: 0},
              %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
              %Event.Done{exit_status: 0, final_message: "committed"}
            ]

            {events, :done}

          :done ->
            {:halt, :done}
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  @impl Tau.CodingAgent
  def cancel(_handle), do: :ok
end

defmodule Tau.Factory.Test.CommittingAgent do
  @moduledoc """
  Test-only `Tau.CodingAgent` adapter that self-commits its own work product
  to the git repo before yielding `%Done{exit_status: 0}`.

  Purpose: simulate a boundary BREACH for the D-388 diagnostic gate. The shim
  must detect the self-commit (git log HEAD diverged from base_ref), emit
  `[:tau, :factory, :agent, :unexpected_commit]` telemetry, and surface
  `:no_work_product` — it MUST NOT rescue the commit as a valid work product.

  Accepted task fields:
    - `:prompt`      — required (ignored)
    - `:workspace`   — required; absolute path to the git repo
    - `:base_ref`    — the SHA that was HEAD before the agent ran; the runner
                       compares HEAD after the agent returns to detect self-commit
  """

  @behaviour Tau.CodingAgent

  alias Tau.CodingAgent.Event

  @impl Tau.CodingAgent
  def capabilities,
    do: %{
      streaming: true,
      tool_restriction: false,
      mcp_client: false,
      session_resume: false,
      cost_reporting: false,
      workspace_isolation: :cwd
    }

  @impl Tau.CodingAgent
  def configure(opts) when is_map(opts), do: {:ok, opts}

  @impl Tau.CodingAgent
  def start(task, _ctx) when is_map(task) do
    ws = Map.fetch!(task, :workspace)

    if File.dir?(ws) do
      stream =
        Stream.resource(
          fn -> :init end,
          fn :init ->
            # Write a file and self-commit — simulating a boundary breach.
            breach_file = Path.join(ws, "breach_#{System.unique_integer([:positive])}.txt")
            File.write!(breach_file, "self-committed by CommittingAgent\n")

            System.cmd("git", ["add", "-A"], cd: ws, stderr_to_stdout: true)

            System.cmd(
              "git",
              ["commit", "-m", "CommittingAgent self-commit (D-388 boundary breach)"],
              cd: ws,
              stderr_to_stdout: true
            )

            events = [
              %Event.Start{agent: :committing_test, version: "0.0.0", pid: nil},
              %Event.AssistantText{text: "I committed my own work", turn: 0},
              %Event.Cost{tokens: %{}, usd: 0.0, duration_ms: 0},
              %Event.Done{exit_status: 0, final_message: "done with self-commit"}
            ]

            {events, :done}
          end,
          fn _ -> :ok end
        )

      {:ok, stream}
    else
      {:error, {:workspace_invalid, ws}}
    end
  end

  @impl Tau.CodingAgent
  def cancel(_handle), do: :ok
end

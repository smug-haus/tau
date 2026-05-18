defmodule Tau.CodingAgents.ClaudeCodeSyncTest do
  @moduledoc """
  Non-async tests for Tau.CodingAgents.ClaudeCode that mutate node-global
  state (PATH). async: false to avoid racing concurrent System.find_executable/1.
  """
  use ExUnit.Case, async: false
  alias Tau.CodingAgents.ClaudeCode

  describe "spawn path — D-036, AC-6 surface" do
    test "returns :claude_not_found synchronously when claude is not on PATH" do
      # Hide PATH so System.find_executable("claude") returns nil. This
      # also exercises D-036: we never read ~/.claude/credentials.json
      # because we short-circuit on the executable check.
      old_path = System.get_env("PATH")

      on_exit(fn ->
        if old_path,
          do: System.put_env("PATH", old_path),
          else: System.delete_env("PATH")
      end)

      System.put_env("PATH", "/no/such/dir")
      result = ClaudeCode.start(default_task(), %{})
      assert result == {:error, :claude_not_found}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────

  defp default_task do
    # Use a real, existing directory so D-033 validation passes.
    # The fixture (or :lines list) is what actually drives event
    # emission via the `:claude_code_source` ctx injection.
    %{prompt: "test prompt", workspace: System.tmp_dir!()}
  end
end

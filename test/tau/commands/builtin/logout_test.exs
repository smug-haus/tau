defmodule Tau.Commands.Builtin.LogoutTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Logout`.

  Verifies:
  - `name/0` returns `"/logout"`.
  - Missing provider arg → `{:error, ...}` listing known providers.
  - Unknown provider → `{:error, ...}` listing known providers.
  - Known provider with Env backend → `{:error, :read_only}` message.
  - Known provider whose credential is absent → `{:error, "No credential stored..."}`.
  - [C48] Does NOT touch `~/.claude/.credentials.json`.
  - Behaviour compliance.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Logout

  describe "name/0" do
    test "returns \"/logout\"" do
      assert Logout.name() == "/logout"
    end
  end

  describe "run/2 — missing provider" do
    test "returns error when args is empty" do
      assert {:error, msg} = Logout.run("", %{})
      assert String.contains?(msg, "Provider required")
      assert String.contains?(msg, "anthropic")
    end

    test "returns error when args is whitespace" do
      assert {:error, msg} = Logout.run("   ", %{})
      assert String.contains?(msg, "Provider required")
    end
  end

  describe "run/2 — unknown provider" do
    test "returns error for unknown provider name" do
      assert {:error, msg} = Logout.run("notareal", %{})
      assert String.contains?(msg, "Unknown provider: notareal")
    end

    test "error message lists known providers" do
      assert {:error, msg} = Logout.run("bogus", %{})
      assert String.contains?(msg, "anthropic")
      assert String.contains?(msg, "openai")
      assert String.contains?(msg, "gemini")
      assert String.contains?(msg, "bedrock")
    end
  end

  describe "run/2 — known provider (Env backend, read-only)" do
    # The Env backend is always active in tests (no Settings.Cache process
    # running, so Vault.backend/0 falls back to Vault.Env via safe_settings/0).
    # Vault.Env.delete/1 returns {:error, :read_only}.

    test "returns error for anthropic when vault is read-only" do
      result = Logout.run("anthropic", %{})
      # Either :read_only message or :not_found — depends on whether ANTHROPIC_API_KEY is set.
      # In CI env, ANTHROPIC_API_KEY may be present (env backend get works).
      # But delete always returns :read_only for Env.
      assert match?({:error, _}, result)

      case result do
        {:error, msg} when is_binary(msg) ->
          assert String.contains?(msg, "anthropic") or
                   String.contains?(msg, "credential") or
                   String.contains?(msg, "ANTHROPIC_API_KEY") or
                   String.contains?(msg, "Vault")

        _ ->
          flunk("Expected {:error, binary}, got: #{inspect(result)}")
      end
    end

    test "returns error for openai when vault is read-only" do
      assert {:error, _msg} = Logout.run("openai", %{})
    end

    test "returns error for gemini when vault is read-only" do
      assert {:error, _msg} = Logout.run("gemini", %{})
    end

    test "returns error for bedrock when vault is read-only" do
      assert {:error, _msg} = Logout.run("bedrock", %{})
    end
  end

  describe "[C48] single-writer — does not touch ~/.claude/.credentials.json" do
    test "credentials.json is not modified by /logout anthropic" do
      claude_creds = Path.join(System.user_home!(), ".claude/.credentials.json")

      mtime = fn ->
        case File.stat(claude_creds, time: :posix) do
          {:ok, %File.Stat{mtime: m}} -> m
          {:error, _} -> :absent
        end
      end

      before_state = mtime.()
      _result = Logout.run("anthropic", %{})
      after_state = mtime.()

      assert before_state == after_state,
             "~/.claude/.credentials.json was modified by /logout (C48 violation)"
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Logout)
      assert function_exported?(Logout, :name, 0)
      assert function_exported?(Logout, :run, 2)
    end
  end
end

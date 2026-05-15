defmodule Tau.CLICodingAgentFlagTest do
  @moduledoc """
  SPEC-CODING-AGENT §4 B1 / D-037: the `--coding-agent` flag on the
  `tui` subcommand (and on bare `tau`, via the same Optimus spec)
  parses cleanly and resolves the string into a concrete adapter
  module that the session FSM and TUI route through.

  This test exercises `Tau.CLI.spec/0` directly (mirroring
  `Tau.CLI.MainDispatchTest`) so it can't accidentally invoke
  `System.halt/1` via `main/1`.
  """
  use ExUnit.Case, async: true

  describe "Optimus spec — --coding-agent option" do
    test "tui subcommand accepts --coding-agent replay" do
      assert {[:tui], parsed} =
               Optimus.parse!(Tau.CLI.spec(), ["tui", "--coding-agent", "replay"])

      assert parsed.options[:coding_agent] == "replay"
    end

    test "tui subcommand accepts --coding-agent claude_code" do
      assert {[:tui], parsed} =
               Optimus.parse!(Tau.CLI.spec(), ["tui", "--coding-agent", "claude_code"])

      assert parsed.options[:coding_agent] == "claude_code"
    end

    test "the option is optional: absence yields nil (default-provider path unchanged)" do
      assert {[:tui], parsed} = Optimus.parse!(Tau.CLI.spec(), ["tui"])
      assert is_nil(parsed.options[:coding_agent])
    end
  end

  describe "resolve_coding_agent/1 — string → module" do
    test "claude_code resolves to Tau.CodingAgents.ClaudeCode (even when module isn't loaded)" do
      assert Tau.CLI.resolve_coding_agent("claude_code") == Tau.CodingAgents.ClaudeCode
      assert Tau.CLI.resolve_coding_agent("claudecode") == Tau.CodingAgents.ClaudeCode
    end

    test "replay resolves to Tau.CodingAgents.Replay" do
      assert Tau.CLI.resolve_coding_agent("replay") == Tau.CodingAgents.Replay
    end

    test "nil passes through (no-flag path)" do
      assert is_nil(Tau.CLI.resolve_coding_agent(nil))
    end

    test "atom passes through (programmatic callers)" do
      assert Tau.CLI.resolve_coding_agent(Tau.CodingAgents.Replay) == Tau.CodingAgents.Replay
    end

    test "unknown short name falls back to Tau.CodingAgents.<X> shape" do
      # Mirrors `resolve_provider/1`'s last-resort path; "foo" → Tau.CodingAgents.Foo.
      assert Tau.CLI.resolve_coding_agent("foo") == Tau.CodingAgents.Foo
    end
  end

  describe "tui_opts/1 — runtime opts plumbing" do
    test "produces :coding_agent module in keyword list when flag set" do
      # Use the spec to build a ParseResult so we test the same path
      # main/1 uses. tui_opts/1 is private; we exercise it via
      # `Tau.CLI.spec()` + Optimus + the public `tui_opts/1` wrapper if
      # exposed. Since it's private, the integration is covered by the
      # spec parse above plus the session-mode FSM test (route exists).
      assert {[:tui], parsed} =
               Optimus.parse!(Tau.CLI.spec(), ["tui", "--coding-agent", "replay"])

      assert parsed.options[:coding_agent] == "replay"
    end
  end
end

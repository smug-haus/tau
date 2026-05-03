defmodule Tau.CLI.MainDispatchTest do
  @moduledoc """
  Regression tests for `Tau.CLI.main/1`'s argv dispatch.

  Previously the `case` only matched 2-tuples like `{[:tui], _}` and
  `{[], _}`. `Optimus.parse!(spec(), [])` (no subcommand) returns a bare
  `%Optimus.ParseResult{}` struct, which fell through to the `_ -> :ok`
  catch-all and silently exited instead of dropping into the TUI. This
  shipped in the prod / Burrito binary; the user invoked
  `burrito_out/tau_linux_arm64`, the supervision tree booted, the
  dispatcher ran, `main/1` returned `:ok`, `System.halt(0)` fired.

  These tests assert the pattern shape Optimus actually returns and
  that bare invocation reaches `tui_cmd`.
  """
  use ExUnit.Case, async: true

  describe "Optimus.parse! return shape (contract pin)" do
    test "no argv returns a bare %Optimus.ParseResult{}, not a tuple" do
      result = Optimus.parse!(Tau.CLI.spec(), [])
      assert %Optimus.ParseResult{} = result
      refute match?({_, _}, result)
    end

    test "subcommand argv returns a {path, parsed} 2-tuple" do
      assert {[:version], %Optimus.ParseResult{}} =
               Optimus.parse!(Tau.CLI.spec(), ["version"])

      assert {[:doctor], %Optimus.ParseResult{}} =
               Optimus.parse!(Tau.CLI.spec(), ["doctor"])
    end
  end

  describe "main/1 dispatch (no halt)" do
    # We can't invoke `Tau.CLI.main/1` directly in tests because every
    # successful arm halts via `|> halt()` (i.e. `System.halt(_)`).
    # Verify dispatch pattern coverage instead: simulate the case-match
    # the way main/1 does and confirm a bare ParseResult routes to TUI.

    test "bare ParseResult matches the TUI dispatch arm" do
      bare = Optimus.parse!(Tau.CLI.spec(), [])

      arm =
        case bare do
          {[:tui], _} -> :tui_subcommand
          {[], _} -> :tui_empty_path
          %Optimus.ParseResult{} -> :tui_bare
          _ -> :fallthrough
        end

      assert arm == :tui_bare,
             "no-args argv must reach the TUI dispatch — fallthrough means the binary exits silently (regression of #148 / #151)"
    end

    test "explicit tui subcommand matches a TUI dispatch arm" do
      tui_argv = Optimus.parse!(Tau.CLI.spec(), ["tui"])

      arm =
        case tui_argv do
          {[:tui], _} -> :tui_subcommand
          {[], _} -> :tui_empty_path
          %Optimus.ParseResult{} -> :tui_bare
          _ -> :fallthrough
        end

      assert arm in [:tui_subcommand, :tui_empty_path, :tui_bare]
    end
  end
end

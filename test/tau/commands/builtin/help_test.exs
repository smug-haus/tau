defmodule Tau.Commands.Builtin.HelpTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Help`.

  SPEC-TUI-COMPLETION AC-1 (D-100): `/help` renders a `{:notice, lines}`
  listing every builtin in `table/0` with a description. No provider turn
  starts (D-042, D-100).
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin
  alias Tau.Commands.Builtin.Help

  defp minimal_data do
    %{skills: [], prompt_templates: []}
  end

  describe "Help.name/0" do
    test "returns /help" do
      assert Help.name() == "/help"
    end
  end

  describe "Help.description/0" do
    test "returns a non-empty string" do
      assert is_binary(Help.description())
      assert Help.description() != ""
    end
  end

  describe "Help.run/2 (AC-1 / D-100)" do
    test "returns {:notice, lines} where lines is a list" do
      result = Help.run("", minimal_data())
      assert {:notice, lines} = result
      assert is_list(lines)
    end

    test "first line is a header" do
      {:notice, [header | _]} = Help.run("", minimal_data())
      assert is_binary(header)
      assert header != ""
    end

    test "contains an entry for every builtin in Builtin.table/0" do
      {:notice, lines} = Help.run("", minimal_data())
      all_text = Enum.join(lines, "\n")

      Builtin.table()
      |> Map.keys()
      |> Enum.each(fn name ->
        assert String.contains?(all_text, name),
               "Expected /help output to contain #{name}"
      end)
    end

    test "contains /help itself" do
      {:notice, lines} = Help.run("", minimal_data())
      assert Enum.any?(lines, &String.contains?(&1, "/help"))
    end

    test "does NOT return :passthrough (no provider turn)" do
      result = Help.run("", minimal_data())
      refute result == :passthrough
      refute match?({:sync, _}, result)
    end

    test "origin tags appear in output" do
      {:notice, lines} = Help.run("", minimal_data())
      # At least one builtin tag should appear
      assert Enum.any?(lines, &String.contains?(&1, "[builtin]"))
    end

    test "is registered in Builtin.table/0" do
      assert Map.has_key?(Builtin.table(), "/help")
      assert Builtin.table()["/help"] == Help
    end
  end
end

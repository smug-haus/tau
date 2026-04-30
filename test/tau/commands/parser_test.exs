defmodule Tau.Commands.ParserTest do
  use ExUnit.Case, async: true

  alias Tau.Commands.Parser

  test "no slash → :passthrough" do
    assert Parser.parse("hello") == :passthrough
  end

  test "empty string → :empty" do
    assert Parser.parse("") == :empty
  end

  test "bare command" do
    assert Parser.parse("/foo") == {:command, "/foo", ""}
  end

  test "command with args" do
    assert Parser.parse("/deploy production now") == {:command, "/deploy", "production now"}
  end
end

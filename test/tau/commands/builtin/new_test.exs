defmodule Tau.Commands.Builtin.NewTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.New`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.New

  describe "name/0" do
    test "returns \"/new\"" do
      assert New.name() == "/new"
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(New)
      assert function_exported?(New, :name, 0)
      assert function_exported?(New, :run, 2)
    end
  end
end

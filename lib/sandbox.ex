defmodule Sandbox do
  @moduledoc "Sandbox production module seeded by the dogfood harness."

  @doc "Returns 42. Seeded by the dogfood scripted agent (P5c-7/AC-12)."
  @spec answer() :: integer()
  def answer, do: 42
end

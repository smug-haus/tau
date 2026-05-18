defmodule Tau.Commands.Builtin.CloneTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Clone`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Clone

  describe "name/0" do
    test "returns \"/clone\"" do
      assert Clone.name() == "/clone"
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Clone)
      assert function_exported?(Clone, :name, 0)
      assert function_exported?(Clone, :run, 2)
    end
  end

  describe "run/2 — no persistence events" do
    test "returns {:error, ...} when there are no events to clone from" do
      persistence = build_persistence([])

      data = %{
        id: "sess-clone-empty",
        persistence: persistence,
        messages: []
      }

      assert {:error, msg} = Clone.run("", data)
      assert String.contains?(msg, "No events")
    end
  end

  describe "run/2 — args are ignored" do
    test "ignores any args passed to it" do
      # With no events the clone still fails gracefully regardless of args
      persistence = build_persistence([])

      data = %{
        id: "sess-clone-args",
        persistence: persistence,
        messages: []
      }

      assert {:error, _} = Clone.run("ignored arg", data)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp build_persistence(event_ids) do
    events =
      Enum.map(event_ids, fn id ->
        %{"id" => id, "kind" => "user_message", "data" => %{}}
      end)

    %{
      stream: fn _session_id ->
        Stream.map(events, & &1)
      end
    }
  end
end

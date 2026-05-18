defmodule Tau.Commands.Builtin.ForkTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Fork`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Fork

  describe "name/0" do
    test "returns \"/fork\"" do
      assert Fork.name() == "/fork"
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Fork)
      assert function_exported?(Fork, :name, 0)
      assert function_exported?(Fork, :run, 2)
    end
  end

  describe "run/2 — no persistence events" do
    test "returns {:error, ...} when there are no events to fork from" do
      persistence = build_persistence([])

      data = %{
        id: "sess-fork-empty",
        persistence: persistence,
        messages: []
      }

      assert {:error, msg} = Fork.run("", data)
      assert String.contains?(msg, "No events")
    end
  end

  describe "run/2 — with only header events" do
    test "returns {:error, ...} when only a session_header event exists" do
      # session_header events are skipped when resolving last event id
      persistence = build_persistence_with_header()

      data = %{
        id: "sess-fork-header-only",
        persistence: persistence,
        messages: []
      }

      assert {:error, msg} = Fork.run("", data)
      assert String.contains?(msg, "No events")
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

  defp build_persistence_with_header do
    events = [
      %{"id" => "header_sess", "kind" => "session_header", "data" => %{}}
    ]

    %{
      stream: fn _session_id ->
        Stream.map(events, & &1)
      end
    }
  end
end

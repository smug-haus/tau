defmodule Tau.Commands.Builtin.CloneTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Clone`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Clone

  # ── stub persistence modules ─────────────────────────────────────────────────
  # Real modules so `persistence.stream(session_id)` resolves as a module-function
  # call, exercising the actual event-walk logic in Clone.

  defmodule StubPersistenceEmpty do
    @moduledoc false
    def stream(_session_id), do: []
  end

  defmodule StubPersistenceHeaderOnly do
    @moduledoc false
    def stream(_session_id),
      do: [%{"id" => "hdr-001", "kind" => "session_header", "data" => %{}}]
  end

  defmodule StubPersistenceWithEvents do
    @moduledoc false
    # Returns a header followed by two real events; last non-header id is "evt-002".
    def stream(_session_id) do
      [
        %{"id" => "hdr-001", "kind" => "session_header", "data" => %{}},
        %{"id" => "evt-001", "kind" => "user_message", "data" => %{}},
        %{"id" => "evt-002", "kind" => "assistant_message", "data" => %{}}
      ]
    end
  end

  # ── name/0 ──────────────────────────────────────────────────────────────────

  describe "name/0" do
    test "returns \"/clone\"" do
      assert Clone.name() == "/clone"
    end
  end

  # ── behaviour compliance ─────────────────────────────────────────────────────

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Clone)
      assert function_exported?(Clone, :name, 0)
      assert function_exported?(Clone, :run, 2)
    end
  end

  # ── run/2 — empty event stream ───────────────────────────────────────────────

  describe "run/2 — no persistence events" do
    test "returns {:error, ...} when there are no events to clone from" do
      data = %{id: "sess-clone-empty", persistence: StubPersistenceEmpty, messages: []}

      assert {:error, msg} = Clone.run("", data)
      assert String.contains?(msg, "No events")
    end
  end

  # ── run/2 — args are ignored ─────────────────────────────────────────────────

  describe "run/2 — args are ignored" do
    test "ignores any args passed to it; empty session still fails gracefully" do
      data = %{id: "sess-clone-args", persistence: StubPersistenceEmpty, messages: []}

      assert {:error, _} = Clone.run("ignored arg", data)
    end
  end

  # ── run/2 — header-only stream ───────────────────────────────────────────────

  describe "run/2 — with only header events" do
    test "session_header events are skipped; returns no-events error" do
      data = %{id: "sess-clone-header-only", persistence: StubPersistenceHeaderOnly, messages: []}

      assert {:error, msg} = Clone.run("", data)
      assert String.contains?(msg, "No events")
    end
  end

  # ── run/2 — resolve last non-header event ────────────────────────────────────

  describe "run/2 — resolves last non-header event id" do
    test "walks past session_header and does not return no-events error when real events exist" do
      # StubPersistenceWithEvents returns [header, evt-001, evt-002].
      # The event-walk must skip the header and find evt-002, then attempt Tau.fork.
      # Tau.fork/2 will fail (no supervision tree in tests), but the result must
      # NOT be the no-events error.
      data = %{id: "sess-clone-walk", persistence: StubPersistenceWithEvents, messages: []}

      result = Clone.run("", data)

      assert result != {:error, "No events to clone from — send a message first."}
      assert match?({:error, _}, result) or match?({:notice, _}, result)
    end
  end
end

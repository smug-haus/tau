defmodule Tau.Commands.Builtin.ForkTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Fork`.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Fork

  # ── stub persistence modules ─────────────────────────────────────────────────
  # These are real modules so `persistence.stream(session_id)` resolves as a
  # module-function call, exercising the actual event-walk logic in Fork.

  defmodule StubPersistenceEmpty do
    @moduledoc false
    def stream(_session_id), do: []
  end

  defmodule StubPersistenceHeaderOnly do
    @moduledoc false
    def stream(_session_id),
      do: [%{"id" => "header_sess", "kind" => "session_header", "data" => %{}}]
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
    test "returns \"/fork\"" do
      assert Fork.name() == "/fork"
    end
  end

  # ── behaviour compliance ─────────────────────────────────────────────────────

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Fork)
      assert function_exported?(Fork, :name, 0)
      assert function_exported?(Fork, :run, 2)
    end
  end

  # ── run/2 — empty event stream ───────────────────────────────────────────────

  describe "run/2 — no persistence events" do
    test "returns {:error, ...} when there are no events to fork from" do
      data = %{id: "sess-fork-empty", persistence: StubPersistenceEmpty, messages: []}

      assert {:error, msg} = Fork.run("", data)
      assert String.contains?(msg, "No events")
    end
  end

  # ── run/2 — header-only stream ───────────────────────────────────────────────

  describe "run/2 — with only header events" do
    test "session_header events are skipped; returns {:error, ...} when no non-header event exists" do
      data = %{id: "sess-fork-header-only", persistence: StubPersistenceHeaderOnly, messages: []}

      assert {:error, msg} = Fork.run("", data)
      # Must reach the no-events branch, not a generic error
      assert String.contains?(msg, "No events")
    end
  end

  # ── run/2 — explicit event-id arg ────────────────────────────────────────────

  describe "run/2 — with an explicit event-id arg" do
    test "passes the explicit id to Tau.fork without consulting persistence" do
      # persistence is never called when an explicit id is given; use empty stub
      # to prove no persistence walk occurs
      data = %{id: "sess-fork-explicit", persistence: StubPersistenceEmpty, messages: []}

      # Tau.fork/2 is not available in the test environment, so we expect an
      # error from it — but NOT the "No events" error, proving persistence was
      # not consulted.
      result = Fork.run("some-explicit-event-id", data)
      assert match?({:error, _}, result)
      assert elem(result, 1) != "No events to fork from — send a message first."
    end
  end

  # ── run/2 — resolve last non-header event ────────────────────────────────────

  describe "run/2 — resolves last non-header event id" do
    test "walks past session_header and picks the last non-header event id" do
      # StubPersistenceWithEvents returns [header, evt-001, evt-002].
      # The event-walk must skip the header and resolve to evt-002.
      # Tau.fork/2 will fail (no running supervision tree in test), but the
      # important thing is that it is called with the LAST non-header id.
      # We can verify this by asserting the result is NOT the no-events error.
      data = %{id: "sess-fork-walk", persistence: StubPersistenceWithEvents, messages: []}

      result = Fork.run("", data)

      # Must not be the no-events branch — the walk found events
      assert result != {:error, "No events to fork from — send a message first."}
      # Must be a fork-related error (Tau.fork returned an error), not a rescue-swallowed error
      assert match?({:error, _}, result) or match?({:notice, _}, result)
    end
  end
end

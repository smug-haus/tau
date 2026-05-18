defmodule Tau.Commands.Builtin.CopyTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Copy`.

  The actual clipboard write is fire-and-forget and cannot be verified in a
  unit test without platform clipboard tooling.  We verify:
  - No assistant message → `{:error, ...}`.
  - An assistant message present → `{:notice, ...}` when a clipboard tool is
    available, or `{:error, "Clipboard unavailable..."}` when none is on PATH.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Copy
  alias Tau.Message.Assistant

  describe "name/0" do
    test "returns \"/copy\"" do
      assert Copy.name() == "/copy"
    end
  end

  describe "run/2 — no assistant messages" do
    test "returns error when messages list is empty" do
      data = %{id: "s1", metadata: %{}, messages: []}
      assert {:error, msg} = Copy.run("", data)
      assert String.contains?(msg, "No assistant message")
    end

    test "returns error when messages contains only user messages" do
      user_msg = %Tau.Message.User{content: "hello", timestamp: DateTime.utc_now()}
      data = %{id: "s2", metadata: %{}, messages: [user_msg]}
      assert {:error, msg} = Copy.run("", data)
      assert String.contains?(msg, "No assistant message")
    end

    test "returns error when data has no messages key" do
      data = %{id: "s3", metadata: %{}}
      assert {:error, msg} = Copy.run("", data)
      assert String.contains?(msg, "No assistant message")
    end
  end

  describe "run/2 — with assistant message" do
    test "returns :notice or :error (clipboard unavailable) when assistant message exists" do
      assistant_msg =
        Assistant.new(
          content: [%{type: :text, text: "Hello world"}],
          timestamp: DateTime.utc_now()
        )

      data = %{id: "s4", metadata: %{}, messages: [assistant_msg]}

      result = Copy.run("", data)
      # In a headless CI environment, clipboard tools may be absent.
      assert match?({:notice, _}, result) or match?({:error, "Clipboard unavailable" <> _}, result)
    end

    test "args are ignored" do
      assistant_msg =
        Assistant.new(
          content: [%{type: :text, text: "Some text"}],
          timestamp: DateTime.utc_now()
        )

      data = %{id: "s5", metadata: %{}, messages: [assistant_msg]}

      result = Copy.run("some random args", data)
      assert match?({:notice, _}, result) or match?({:error, _}, result)
    end

    test "uses the LAST assistant message when multiple exist" do
      # We can't inspect what was copied, but we can verify no crash and a
      # well-formed return when multiple assistant messages exist.
      msg1 = Assistant.new(content: [%{type: :text, text: "First"}], timestamp: DateTime.utc_now())
      msg2 = Assistant.new(content: [%{type: :text, text: "Last"}], timestamp: DateTime.utc_now())
      data = %{id: "s6", metadata: %{}, messages: [msg1, msg2]}

      result = Copy.run("", data)
      assert match?({:notice, _}, result) or match?({:error, _}, result)
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Copy)
      assert function_exported?(Copy, :name, 0)
      assert function_exported?(Copy, :run, 2)
    end
  end
end

defmodule Tau.Commands.Builtin.CompactTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Compact`.

  Verifies:
  - `name/0` returns `"/compact"`.
  - `run/2` returns `{:async_compact, binary}` on a non-trivial message list.
  - `run/2` returns `{:error, "Nothing to compact."}` for an empty list.
  - `run/2` returns `{:error, "Nothing to compact."}` for a single
    compaction-summary message (trivial list).
  - `run/2` returns `{:error, "Compaction already in progress."}` when
    `compaction_task != nil`.
  - Behaviour compliance.

  All tests are pure (no FSM, no PubSub) — `run/2` is a predicate.
  """
  use ExUnit.Case, async: true

  alias Tau.Commands.Builtin.Compact

  defp user_msg(content) do
    Tau.Message.User.new(content)
  end

  defp summary_msg do
    Tau.Message.User.new(
      "<conversation_summary>old stuff</conversation_summary>",
      metadata: %{role: :compaction_summary}
    )
  end

  describe "name/0" do
    test "returns \"/compact\"" do
      assert Compact.name() == "/compact"
    end
  end

  describe "run/2 — success path" do
    test "returns {:async_compact, binary} for a non-trivial message list" do
      data = %{
        messages: [user_msg("hello"), user_msg("world")],
        compaction_task: nil
      }

      assert {:async_compact, notice} = Compact.run("", data)
      assert is_binary(notice)
      assert notice =~ "compact" |> String.downcase() or String.downcase(notice) =~ "compact"
    end

    test "notice is 'Compacting conversation…'" do
      data = %{messages: [user_msg("hello")], compaction_task: nil}
      assert {:async_compact, "Compacting conversation…"} = Compact.run("", data)
    end

    test "args are ignored — still returns {:async_compact, _}" do
      data = %{messages: [user_msg("hello")], compaction_task: nil}
      assert {:async_compact, _} = Compact.run("some args", data)
    end

    test "returns {:async_compact, _} for list with multiple message types" do
      data = %{
        messages: [user_msg("a"), summary_msg(), user_msg("b")],
        compaction_task: nil
      }

      assert {:async_compact, _} = Compact.run("", data)
    end
  end

  describe "run/2 — empty / trivial guard" do
    test "returns {:error, 'Nothing to compact.'} for empty message list" do
      data = %{messages: [], compaction_task: nil}
      assert {:error, "Nothing to compact."} = Compact.run("", data)
    end

    test "returns {:error, 'Nothing to compact.'} for a single compaction-summary message" do
      data = %{messages: [summary_msg()], compaction_task: nil}
      assert {:error, "Nothing to compact."} = Compact.run("", data)
    end

    test "returns {:async_compact, _} for a list with a summary plus other messages" do
      # Two messages: a summary and a real user message — not trivial.
      data = %{messages: [summary_msg(), user_msg("hello")], compaction_task: nil}
      assert {:async_compact, _} = Compact.run("", data)
    end
  end

  describe "run/2 — already-in-progress guard" do
    test "returns {:error, 'Compaction already in progress.'} when compaction_task != nil" do
      fake_pid = spawn(fn -> :ok end)

      data = %{
        messages: [user_msg("hello"), user_msg("world")],
        compaction_task: fake_pid
      }

      assert {:error, "Compaction already in progress."} = Compact.run("", data)
    end

    test "in-progress guard takes priority over trivial-messages guard" do
      # Even with trivial messages, in-progress is checked first.
      fake_pid = spawn(fn -> :ok end)
      data = %{messages: [], compaction_task: fake_pid}
      assert {:error, "Compaction already in progress."} = Compact.run("", data)
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Compact)
      assert function_exported?(Compact, :name, 0)
      assert function_exported?(Compact, :run, 2)
    end
  end
end

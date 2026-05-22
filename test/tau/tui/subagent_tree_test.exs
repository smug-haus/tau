defmodule Tau.TUI.SubagentTreeTest do
  @moduledoc """
  Tests for `Tau.TUI.SubagentTree` — the pure fold module for the sub-agent
  tree maintained in the TUI MVU model.

  Covers D-150..D-154 invariants from SPEC-TUI-HEADLESS §5c:
  - Property tests: monotone state transitions, additive cost, unknown
    subagent_id / unknown kind ignored (not crashed).
  - Unit tests: fold round-trips, format_start_marker/1, format_end_marker/1,
    tool_call_owned?/2, and B1 de-dup logic.
  - AC-8 telemetry assertions are in a separate integration test file.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Session.Events
  alias Tau.TUI.SubagentTree
  alias Tau.TUI.SubagentTree.SubagentNode

  # --- Generators -----------------------------------------------------------

  defp gen_subagent_id, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
  defp gen_kind, do: StreamData.member_of([:builtin_agent, :coding_agent])
  defp gen_label, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)

  defp gen_start_event do
    ExUnitProperties.gen all(
                           id <- gen_subagent_id(),
                           kind <- gen_kind(),
                           label <- gen_label()
                         ) do
      %Events.SubagentStart{
        session_id: "sess-1",
        subagent_id: id,
        kind: kind,
        label: label,
        parent_tool_call_id: nil,
        child_session_id: nil
      }
    end
  end

  defp gen_end_state do
    StreamData.member_of([:done, :failed, :cancelled])
  end

  # --- Property tests (D-152, D-154) ----------------------------------------

  property "unknown kind in SubagentStart is ignored — tree unchanged (D-152)" do
    check all(
            id <- gen_subagent_id(),
            label <- gen_label()
          ) do
      tree = %{}

      # :unknown_kind is not in the valid set
      event = %Events.SubagentStart{
        session_id: "sess",
        subagent_id: id,
        kind: :unknown_kind,
        label: label,
        parent_tool_call_id: nil,
        child_session_id: nil
      }

      result = SubagentTree.fold(tree, event)
      assert result == %{}, "unknown kind must leave tree unchanged (D-152)"
    end
  end

  property "unknown subagent_id in SubagentProgress is ignored (D-152)" do
    check all(id <- gen_subagent_id()) do
      tree = %{}

      event = %Events.SubagentProgress{
        session_id: "sess",
        subagent_id: id,
        activity: {:tool_call, "Bash"},
        child_tool_call_id: nil
      }

      result = SubagentTree.fold(tree, event)
      assert result == %{}, "unknown subagent_id in Progress must leave tree unchanged (D-152)"
    end
  end

  property "unknown subagent_id in SubagentCost is ignored (D-152)" do
    check all(id <- gen_subagent_id()) do
      tree = %{}

      event = %Events.SubagentCost{
        session_id: "sess",
        subagent_id: id,
        tokens: %{input: 10},
        usd: 0.001,
        duration_ms: 1000
      }

      result = SubagentTree.fold(tree, event)
      assert result == %{}, "unknown subagent_id in Cost must leave tree unchanged (D-152)"
    end
  end

  property "unknown subagent_id in SubagentEnd is ignored (D-152)" do
    check all(
            id <- gen_subagent_id(),
            state <- gen_end_state()
          ) do
      tree = %{}

      event = %Events.SubagentEnd{
        session_id: "sess",
        subagent_id: id,
        state: state,
        summary: "done"
      }

      result = SubagentTree.fold(tree, event)
      assert result == %{}, "unknown subagent_id in End must leave tree unchanged (D-152)"
    end
  end

  property "state transitions are monotone — terminal state cannot revert (D-154)" do
    check all(
            start <- gen_start_event(),
            terminal_state <- gen_end_state(),
            next_activity <- StreamData.member_of([:tool_call, :assistant_text])
          ) do
      id = start.subagent_id
      tree = SubagentTree.fold(%{}, start)

      end_event = %Events.SubagentEnd{
        session_id: "sess",
        subagent_id: id,
        state: terminal_state,
        summary: "finished"
      }

      tree = SubagentTree.fold(tree, end_event)
      assert Map.get(tree, id).state == terminal_state, "state should be #{terminal_state}"

      # Now try to send a progress event — state must not revert to :running
      progress = %Events.SubagentProgress{
        session_id: "sess",
        subagent_id: id,
        activity: {next_activity, "test"},
        child_tool_call_id: nil
      }

      tree_after = SubagentTree.fold(tree, progress)

      assert Map.get(tree_after, id).state == terminal_state,
             "terminal state #{terminal_state} must not revert after Progress (D-154)"
    end
  end

  property "cost is additive — later SubagentCost overwrites the cost fields (D-153)" do
    check all(
            start <- gen_start_event(),
            usd1 <- StreamData.float(min: 0.0, max: 1.0),
            usd2 <- StreamData.float(min: 0.0, max: 1.0)
          ) do
      id = start.subagent_id
      tree = SubagentTree.fold(%{}, start)

      tree =
        SubagentTree.fold(tree, %Events.SubagentCost{
          session_id: "sess",
          subagent_id: id,
          tokens: %{input: 10},
          usd: usd1,
          duration_ms: 1000
        })

      tree =
        SubagentTree.fold(tree, %Events.SubagentCost{
          session_id: "sess",
          subagent_id: id,
          tokens: %{input: 20},
          usd: usd2,
          duration_ms: 2000
        })

      node = Map.get(tree, id)
      assert node.usd == usd2, "cost should be updated to latest value"
      assert node.duration_ms == 2000
    end
  end

  property "SubagentStart with valid kind creates a node in :running state" do
    check all(start <- gen_start_event()) do
      tree = SubagentTree.fold(%{}, start)
      node = Map.get(tree, start.subagent_id)
      assert node != nil
      assert node.state == :running
      assert node.kind == start.kind
      assert node.label == start.label
      assert node.tool_calls == 0
    end
  end

  # --- Unit tests -----------------------------------------------------------

  describe "fold/2 — SubagentStart" do
    test "creates node with :running state for :builtin_agent" do
      tree =
        SubagentTree.fold(%{}, %Events.SubagentStart{
          session_id: "sess",
          subagent_id: "child-1",
          kind: :builtin_agent,
          label: "general-purpose",
          parent_tool_call_id: "tc-parent",
          child_session_id: "child-session-1"
        })

      node = tree["child-1"]
      assert node.state == :running
      assert node.kind == :builtin_agent
      assert node.label == "general-purpose"
      assert node.parent_tool_call_id == "tc-parent"
      assert node.child_session_id == "child-session-1"
      assert node.tool_calls == 0
    end

    test "creates node with :running state for :coding_agent" do
      tree =
        SubagentTree.fold(%{}, %Events.SubagentStart{
          session_id: "sess",
          subagent_id: "sess:ca",
          kind: :coding_agent,
          label: "claude-code",
          parent_tool_call_id: nil,
          child_session_id: nil
        })

      node = tree["sess:ca"]
      assert node.state == :running
      assert node.kind == :coding_agent
    end

    test "ignores unknown kind atom without crashing (D-152)" do
      tree =
        SubagentTree.fold(%{}, %Events.SubagentStart{
          session_id: "sess",
          subagent_id: "x",
          kind: :some_future_kind,
          label: "future",
          parent_tool_call_id: nil,
          child_session_id: nil
        })

      assert tree == %{}
    end
  end

  describe "fold/2 — SubagentProgress" do
    test "increments tool_calls and tracks last_activity on :tool_call activity" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "child-1",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "child-1",
          activity: {:tool_call, "Bash"},
          child_tool_call_id: "tc-child-1"
        })

      node = tree["child-1"]
      assert node.tool_calls == 1
      assert node.last_activity == {:tool_call, "Bash"}
    end

    test "tracks owned tool_call_ids for B1 de-dup" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "child-1",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "child-1",
          activity: {:tool_call, "Bash"},
          child_tool_call_id: "tc-child-1"
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "child-1",
          activity: {:tool_call, "Read"},
          child_tool_call_id: "tc-child-2"
        })

      assert SubagentTree.tool_call_owned?(tree, "tc-child-1")
      assert SubagentTree.tool_call_owned?(tree, "tc-child-2")
      refute SubagentTree.tool_call_owned?(tree, "tc-parent-unrelated")
    end

    test "nil child_tool_call_id does not crash (D-152)" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "child-1",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "child-1",
          activity: {:assistant_text, "hello"},
          child_tool_call_id: nil
        })

      node = tree["child-1"]
      assert node.state == :running
      assert node.last_activity == {:assistant_text, "hello"}
      assert node.tool_calls == 0
    end

    test "does not increment tool_calls for non-tool_call activity" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "c",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "c",
          activity: {:assistant_text, "thinking..."},
          child_tool_call_id: nil
        })

      assert tree["c"].tool_calls == 0
    end
  end

  describe "fold/2 — SubagentCost" do
    test "updates cost fields in the node" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "c",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentCost{
          session_id: "sess",
          subagent_id: "c",
          tokens: %{input: 100, output: 50},
          usd: 0.005,
          duration_ms: 3000
        })

      node = tree["c"]
      assert node.usd == 0.005
      assert node.duration_ms == 3000
      assert node.tokens == %{input: 100, output: 50}
    end
  end

  describe "fold/2 — SubagentEnd" do
    test "transitions node to :done state" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "c",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentEnd{
          session_id: "sess",
          subagent_id: "c",
          state: :done,
          summary: "completed"
        })

      assert tree["c"].state == :done
      assert tree["c"].summary == "completed"
    end

    test "transitions node to :failed state" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "c",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentEnd{
          session_id: "sess",
          subagent_id: "c",
          state: :failed,
          summary: "crashed"
        })

      assert tree["c"].state == :failed
    end

    test "transitions node to :cancelled state" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "c",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentEnd{
          session_id: "sess",
          subagent_id: "c",
          state: :cancelled,
          summary: "parent died"
        })

      assert tree["c"].state == :cancelled
    end
  end

  describe "tool_call_owned?/2" do
    test "returns false for nil tool_call_id" do
      assert SubagentTree.tool_call_owned?(%{}, nil) == false
    end

    test "returns false for empty tree" do
      assert SubagentTree.tool_call_owned?(%{}, "tc-1") == false
    end

    test "returns true for an owned tool_call_id" do
      tree =
        %{}
        |> SubagentTree.fold(%Events.SubagentStart{
          session_id: "sess",
          subagent_id: "child-1",
          kind: :builtin_agent,
          label: "test",
          parent_tool_call_id: nil,
          child_session_id: nil
        })
        |> SubagentTree.fold(%Events.SubagentProgress{
          session_id: "sess",
          subagent_id: "child-1",
          activity: {:tool_call, "Bash"},
          child_tool_call_id: "tc-owned"
        })

      assert SubagentTree.tool_call_owned?(tree, "tc-owned")
    end
  end

  describe "format_start_marker/1" do
    test "returns boxed start marker with [running]" do
      node = %SubagentNode{
        subagent_id: "c",
        kind: :builtin_agent,
        label: "my-agent"
      }

      marker = SubagentTree.format_start_marker(node)
      assert marker == "┌─ sub-agent: my-agent [running]"
    end
  end

  describe "format_end_marker/1" do
    test "done with tool calls and duration" do
      node = %SubagentNode{
        subagent_id: "c",
        kind: :builtin_agent,
        label: "my-agent",
        state: :done,
        tool_calls: 5,
        duration_ms: 64_000,
        usd: 0.03
      }

      marker = SubagentTree.format_end_marker(node)
      assert String.starts_with?(marker, "└─ sub-agent: my-agent [done")
      assert String.contains?(marker, "5 tool calls")
      assert String.contains?(marker, "1m04s")
      assert String.contains?(marker, "$")
    end

    test "failed state" do
      node = %SubagentNode{
        subagent_id: "c",
        kind: :builtin_agent,
        label: "crashy",
        state: :failed,
        tool_calls: 2,
        duration_ms: 1000,
        usd: nil
      }

      marker = SubagentTree.format_end_marker(node)
      assert String.contains?(marker, "failed")
      refute String.contains?(marker, "$")
    end

    test "cancelled state" do
      node = %SubagentNode{
        subagent_id: "c",
        kind: :coding_agent,
        label: "claude-code",
        state: :cancelled,
        tool_calls: 0,
        duration_ms: nil,
        usd: nil
      }

      marker = SubagentTree.format_end_marker(node)
      assert String.contains?(marker, "cancelled")
    end
  end
end

defmodule Tau.Session.SessionTreeBuiltinDispatchTest do
  @moduledoc """
  D-042 dispatch tests for the session-tree built-ins: `/fork`, `/clone`, `/new`.

  Each test asserts:
  - The command dispatches via `handle_builtin_command/4`.
  - The FSM produces a SystemNotice (or error-notice) without starting a
    provider turn (no MessageStart, no `stream/3` call).
  - The FSM stays alive in `:awaiting_user` (snapshot/1 succeeds after).
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-tree-cmds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # Minimal recording provider — identical pattern to existing dispatch tests.
  defmodule RecordingProvider do
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "recording-model"

    @impl Tau.Provider
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(_messages, _opts, ctx) do
      owner = ctx[:stream_owner]
      if owner, do: send(owner, {:stream_called, self()})

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "recording-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "recording"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          & &1
        )

      {:ok, stream}
    end
  end

  defp start_session(sid, owner) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: RecordingProvider,
        model: "recording-model",
        session_id: sid,
        provider_ctx: %{stream_owner: owner}
      )
  end

  # ── /fork ──────────────────────────────────────────────────────────────────

  test "D-042: /fork with no events produces error SystemNotice, zero provider stream calls, FSM alive" do
    sid = "builtin-fork-noevents-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/fork")

    # A fresh session has no persisted non-header events, so expect an error notice.
    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: ")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  test "D-042: /fork with explicit nonexistent event-id produces error SystemNotice, no provider turn" do
    sid = "builtin-fork-badid-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/fork nonexistent-event-id-xyz")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: ")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, _snap} = Tau.snapshot(sid)
  end

  # ── /clone ──────────────────────────────────────────────────────────────────

  test "D-042: /clone with no events produces error SystemNotice, zero provider stream calls, FSM alive" do
    sid = "builtin-clone-noevents-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/clone")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: ")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  # ── /new ────────────────────────────────────────────────────────────────────

  test "D-042: /new produces SystemNotice, zero provider stream calls, FSM alive" do
    sid = "builtin-new-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/new")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Started new session")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  test "D-042: /new creates a distinct new session id" do
    sid = "builtin-new-distinct-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/new")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    new_id = extract_session_id(text)
    refute is_nil(new_id), "Expected a session id in notice: #{inspect(text)}"
    refute new_id == sid

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300
  end

  # ── Acyclicity: A→B→C chain terminates and never revisits ──────────────────

  test "fork A→B→C produces distinct session ids; chain walk terminates without revisiting any id" do
    sid_a = "fork-acyclic-a-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid_a, owner)

    # Produce at least one persisted event in A by completing a provider turn.
    Tau.send(sid_a, "hello")
    assert_receive %SE.MessageEnd{session_id: ^sid_a}, 3_000

    last_a = last_persisted_event_id(sid_a)
    refute is_nil(last_a)

    # Fork A → B
    {:ok, sid_b} = Tau.fork(sid_a, last_a)
    refute sid_b == sid_a
    ExUnit.Callbacks.on_exit(fn -> Tau.stop(sid_b) end)

    # Drive a full turn in B so it has its own persisted events.
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid_b}")
    Tau.send(sid_b, "second")
    assert_receive %SE.MessageEnd{session_id: ^sid_b}, 3_000

    last_b = last_persisted_event_id(sid_b)
    refute is_nil(last_b)

    # Fork B → C
    {:ok, sid_c} = Tau.fork(sid_b, last_b)
    refute sid_c == sid_b
    refute sid_c == sid_a
    ExUnit.Callbacks.on_exit(fn -> Tau.stop(sid_c) end)

    # Walk the chain from C upward via :forked_from metadata in headers.
    chain = walk_fork_chain(sid_c, MapSet.new())

    # No :cycle sentinel in the chain
    refute :cycle in chain

    # All ids are distinct (invariant: Tau.fork/2 always generates a fresh id)
    assert Enum.uniq(chain) == chain

    # C, B are both reachable in the chain
    assert sid_c in chain
    assert sid_b in chain
    assert length(chain) >= 3
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp last_persisted_event_id(session_id) do
    persistence = Tau.Persistence.impl()

    persistence.stream(session_id)
    |> Enum.reduce(nil, fn
      %{"kind" => "session_header"}, acc -> acc
      %{"id" => id}, _acc -> id
    end)
  end

  # Walk the fork chain from `session_id` upward, following :forked_from metadata
  # in persisted session headers.  Returns an ordered list of session ids
  # (innermost first).  Returns [:cycle | rest] if a session id is revisited.
  defp walk_fork_chain(session_id, visited, depth \\ 0)

  defp walk_fork_chain(_session_id, _visited, depth) when depth > 50, do: []

  defp walk_fork_chain(session_id, visited, depth) do
    if MapSet.member?(visited, session_id) do
      [:cycle]
    else
      visited = MapSet.put(visited, session_id)
      persistence = Tau.Persistence.impl()

      parent_id =
        persistence.stream(session_id)
        |> Enum.find_value(nil, fn
          %{
            "kind" => "session_header",
            "data" => %{"metadata" => %{"forked_from" => %{"session" => pid}}}
          } ->
            pid

          _ ->
            nil
        end)

      case parent_id do
        nil -> [session_id]
        pid -> [session_id | walk_fork_chain(pid, visited, depth + 1)]
      end
    end
  end

  # Pull the session id from a notice string of the form "... session <id>".
  defp extract_session_id(text) do
    case Regex.run(~r/session (\S+)$/, text) do
      [_, id] -> id
      _ -> nil
    end
  end
end

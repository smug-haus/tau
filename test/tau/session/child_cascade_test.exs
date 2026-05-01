defmodule Tau.Session.ChildCascadeTest do
  @moduledoc """
  Coverage for issue #92 / ADR-0014: the parent session FSM tracks its
  spawned subagent ids in `data.child_session_ids` and cascades
  `Tau.cancel/1` and `Tau.stop/1` across that set so children get a
  clean shutdown path (flush JSONL, broadcast `%SessionEnd{}`) before
  the parent tears down its own work.

  Cases:

    1. `Tau.register_child/2` from each child puts ids in the parent's
       set; `Tau.snapshot/1` surfaces it.
    2. `Tau.cancel(parent)` results in a `%SessionEnd{}` on every
       descendant's PubSub topic plus one on the parent's.
    3. `Tau.unregister_child/2` shrinks the set when a child finishes
       naturally — a subsequent cancel does not try to cancel a
       phantom id.
    4. `Tau.stop(parent)` cascades `:stop` the same way.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  # Minimal provider stub — sessions never start a turn in these tests
  # (no `Tau.send/2`), so `stream/3` would be unused even if called. We
  # still need a behaviour-conforming module so `Tau.start_session/1`
  # accepts it and the FSM's init path runs cleanly.
  defmodule InertProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, _ctx), do: {:ok, []}

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "inert"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-child-cascade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp start_node(opts \\ []) do
    sid =
      "cc-#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)}"

    {:ok, ^sid} =
      start_session_for_test(
        Keyword.merge(
          [session_id: sid, provider: InertProvider, model: "inert"],
          opts
        )
      )

    sid
  end

  defp child_set(sid) do
    {:ok, snap} = Tau.snapshot(sid)
    snap.child_session_ids
  end

  defp await_session_end(sid, timeout \\ 1_000) do
    receive do
      %SE.SessionEnd{session_id: ^sid} = e -> e
    after
      timeout -> flunk("Did not receive SessionEnd for #{sid} within #{timeout}ms")
    end
  end

  test "register_child + snapshot reflect the cascade set" do
    parent = start_node()
    a = start_node()
    b = start_node()

    assert MapSet.size(child_set(parent)) == 0

    :ok = Tau.register_child(parent, a)
    :ok = Tau.register_child(parent, b)

    # Snapshot is read via :sys.get_state under the hood, which
    # synchronises against the cast — the prior casts are guaranteed
    # to have been processed by the time the snapshot returns.
    set = child_set(parent)
    assert MapSet.size(set) == 2
    assert MapSet.member?(set, a)
    assert MapSet.member?(set, b)
  end

  test "cancel(parent) cascades to all registered children" do
    parent = start_node()
    a = start_node()
    b = start_node()

    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent}")
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{a}")
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{b}")

    :ok = Tau.register_child(parent, a)
    :ok = Tau.register_child(parent, b)
    # Force the casts to drain.
    _ = child_set(parent)

    :ok = Tau.cancel(parent)

    # `:cancel` does not terminate the FSM — it returns the session to
    # `:awaiting_user`. Each cancelled FSM broadcasts `%Cancelled{}`
    # on its topic; the cascade hits parent + children + (recursively)
    # any descendant.
    assert_receive %SE.Cancelled{session_id: ^parent, reason: :user}, 1_000
    assert_receive %SE.Cancelled{session_id: ^a, reason: :user}, 1_000
    assert_receive %SE.Cancelled{session_id: ^b, reason: :user}, 1_000
  end

  test "unregister_child shrinks the set so cancel skips finished children" do
    parent = start_node()
    a = start_node()
    b = start_node()

    :ok = Tau.register_child(parent, a)
    :ok = Tau.register_child(parent, b)
    assert MapSet.size(child_set(parent)) == 2

    :ok = Tau.unregister_child(parent, a)
    set = child_set(parent)
    assert MapSet.size(set) == 1
    refute MapSet.member?(set, a)
    assert MapSet.member?(set, b)
  end

  test "stop(parent) cascades :stop to children — every node emits SessionEnd" do
    parent = start_node()
    a = start_node()
    b = start_node()

    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{parent}")
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{a}")
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{b}")

    :ok = Tau.register_child(parent, a)
    :ok = Tau.register_child(parent, b)
    _ = child_set(parent)

    :ok = Tau.stop(parent)

    # Every node — including the parent — broadcasts %SessionEnd{} via
    # its terminate/3 callback.
    _ = await_session_end(parent)
    _ = await_session_end(a)
    _ = await_session_end(b)
  end
end

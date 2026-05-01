defmodule Tau.Session.ChildCascadePropertyTest do
  @moduledoc """
  Property suite for issue #92 / ADR-0014.

  Property: for any tree of sessions wired together via
  `Tau.register_child/2`, calling `Tau.stop/1` on any node terminates
  every descendant (each emits `%SessionEnd{}` on its own PubSub topic).

  Trees are sized small (depth ≤ 3, fan-out ≤ 3) — the property exercises
  the cascade *shape* rather than throughput. A larger bound would just
  multiply session FSMs without changing the invariant under test, and
  the per-node startup is dominated by `Tau.Persistence.Jsonl.open/2`'s
  filesystem work.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

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
    tmp =
      Path.join(System.tmp_dir!(), "tau-child-cascade-prop-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # Tree: %{id: String.t(), children: [tree]}. Depth bound matches the
  # acceptance criteria in #92 (depth ≤ 3).
  defp tree_gen(depth) when depth <= 0 do
    StreamData.constant([])
  end

  defp tree_gen(depth) do
    StreamData.bind(StreamData.integer(0..3), fn n ->
      StreamData.bind(StreamData.list_of(tree_gen(depth - 1), length: n), fn subs ->
        StreamData.constant(subs)
      end)
    end)
  end

  defp build(tree_children) do
    sid = start_node()
    children = Enum.map(tree_children, &build/1)

    Enum.each(children, fn %{id: child_id} ->
      :ok = Tau.register_child(sid, child_id)
    end)

    %{id: sid, children: children}
  end

  defp start_node do
    sid =
      "ccp-#{System.unique_integer([:positive])}-#{:crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false)}"

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: InertProvider,
        model: "inert"
      )

    sid
  end

  defp flatten(%{id: id, children: children}) do
    [id | Enum.flat_map(children, &flatten/1)]
  end

  property "Tau.stop/1 on any node terminates every descendant" do
    check all(tree_children <- tree_gen(3), max_runs: 8) do
      tree = build(tree_children)
      ids = flatten(tree)

      Enum.each(ids, fn id ->
        Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{id}")
      end)

      :ok = Tau.stop(tree.id)

      Enum.each(ids, fn id ->
        assert_receive %SE.SessionEnd{session_id: ^id}, 2_000
      end)
    end
  end
end

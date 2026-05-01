defmodule Tau.Session.UpdateProviderTest do
  @moduledoc """
  Verifies #38: `Tau.update_provider/2` updates a live session's
  provider/model/provider_ctx without restart and persists the
  change as a `"reconfigure"` event.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-reconf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defmodule AltReplay do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_msgs, _opts, _ctx) do
      {:ok,
       [
         %Event.Start{request_id: "r", model: "alt"},
         %Event.TextStart{block_id: "b"},
         %Event.TextDelta{block_id: "b", text: "from-alt"},
         %Event.TextEnd{block_id: "b"},
         %Event.Done{stop_reason: :stop, usage: %{}}
       ]}
    end

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
    def default_model, do: "alt"
  end

  test "update_provider swaps provider/model and the next turn uses the new one" do
    fixture = [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.TextStart{block_id: "b"},
      %Event.TextDelta{block_id: "b", text: "from-replay"},
      %Event.TextEnd{block_id: "b"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]

    sid = "reconf-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture}
      )

    Tau.send(sid, "first")
    assert_receive %SE.MessageEnd{message: %{content: [%{text: "from-replay"}]}}, 5_000

    :ok = Tau.update_provider(sid, provider: AltReplay, model: "alt-model")

    # The snapshot picks up the new fields immediately — the cast is
    # processed before the next user message because it's cast in
    # mailbox order.
    Tau.send(sid, "second")
    assert_receive %SE.MessageEnd{message: msg}, 5_000

    # The second turn used AltReplay — its content is "from-alt".
    assert [%{text: "from-alt"}] = msg.content

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.provider == AltReplay
    assert snap.model == "alt-model"
  end

  test "reconfigure event is persisted to JSONL" do
    fixture = [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]

    sid = "reconf-jsonl-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture}
      )

    :ok = Tau.update_provider(sid, model: "new-model")

    # Give the cast a moment to land + persist.
    Process.sleep(50)

    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    kinds =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["kind"])

    assert "reconfigure" in kinds

    reconf =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["kind"] == "reconfigure"))

    assert reconf["data"]["model"] == "new-model"
  end

  test "update_provider returns {:error, :not_found} for unknown session id" do
    assert {:error, :not_found} = Tau.update_provider("does-not-exist", model: "x")
  end

  test "provider_ctx is merged, not replaced" do
    fixture = [
      %Event.Start{request_id: "r", model: "replay"},
      %Event.Done{stop_reason: :stop, usage: %{}}
    ]

    sid = "reconf-merge-#{System.unique_integer([:positive])}"

    {:ok, ^sid} =
      start_session_for_test(
        provider: Tau.Providers.Replay,
        model: "replay",
        session_id: sid,
        provider_ctx: %{replay_fixture: fixture, custom_tag: "keep"}
      )

    :ok = Tau.update_provider(sid, provider_ctx: %{another_tag: "added"})

    Process.sleep(50)

    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
    {_state, data} = :sys.get_state(pid)

    assert data.provider_ctx[:custom_tag] == "keep"
    assert data.provider_ctx[:another_tag] == "added"
    assert data.provider_ctx[:replay_fixture] == fixture
  end
end

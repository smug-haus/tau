defmodule Tau.Session.InformationalBuiltinDispatchTest do
  @moduledoc """
  D-042 dispatch tests for the three informational built-ins:
  `/tree`, `/copy`, `/export`.

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
    tmp = Path.join(System.tmp_dir!(), "tau-info-cmds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # Minimal recording provider — identical to builtin_command_dispatch_test.exs.
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

  # ── /tree ──────────────────────────────────────────────────────────────────

  test "D-042: /tree produces SystemNotice, zero provider stream calls, FSM alive" do
    sid = "builtin-tree-d042-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/tree")

    # Must receive at least one SystemNotice
    assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000

    # Must NOT drive a provider turn
    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    # Session alive in :awaiting_user
    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  # ── /copy ──────────────────────────────────────────────────────────────────

  test "D-042: /copy with no assistant messages produces error SystemNotice, no provider turn" do
    sid = "builtin-copy-noassist-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/copy")

    # Should be an error notice (no assistant messages yet)
    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: No assistant message")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  # ── /export ────────────────────────────────────────────────────────────────

  test "D-042: /export jsonl produces notice, zero provider stream calls, FSM alive" do
    sid = "builtin-export-jsonl-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/export jsonl")

    # Immediate notice ("Exporting...")
    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Exporting")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, snap} = Tau.snapshot(sid)
    assert snap.id == sid
  end

  test "D-042: /export html produces notice, no provider turn" do
    sid = "builtin-export-html-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/export html")

    assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000
    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, _snap} = Tau.snapshot(sid)
  end

  test "D-042: /export <unknown> produces error SystemNotice, no provider turn" do
    sid = "builtin-export-bad-#{System.unique_integer([:positive])}"
    owner = self()
    start_session(sid, owner)

    Tau.send(sid, "/export pdf")

    assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
    assert String.contains?(text, "Error: Unknown export format: pdf")

    refute_receive %SE.MessageStart{}, 300
    refute_receive {:stream_called, _}, 300

    assert {:ok, _snap} = Tau.snapshot(sid)
  end
end

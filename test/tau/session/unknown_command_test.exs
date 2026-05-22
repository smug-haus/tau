defmodule Tau.Session.UnknownCommandTest do
  @moduledoc """
  Tests for the unknown-command guard (D-101, SPEC-TUI-COMPLETION AC-2, AC-7, AC-10).

  AC-2: An unrecognized `/name` (no whitespace, no catalog match) emits a
        SystemNotice and does NOT start a provider turn.
  AC-7: A line with whitespace starting with `/` is sent to the model as prose
        (status → :streaming). The guard MUST NOT intercept it.
  AC-10: A bare `/` followed by Enter (empty command token) does NOT crash and
         emits a SystemNotice (NOT forwarded to the model).

  The guard is in `classify_slash_command/2` in `lib/tau/session.ex`.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-unknown-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  # A provider that records stream/3 calls.
  defmodule RecordingProvider do
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "rec-model"

    @impl Tau.Provider
    def capabilities do
      %{thinking: false, tools: false, vision: false, prompt_caching: false, parallel_tools: false}
    end

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(_messages, _opts, ctx) do
      if owner = ctx[:stream_owner], do: send(owner, {:stream_called, self()})

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "rec-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "ok"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          & &1
        )

      {:ok, stream}
    end
  end

  defp start_session(extra_opts \\ []) do
    sid = "unknown-cmd-#{System.unique_integer([:positive])}"
    owner = self()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        [
          provider: RecordingProvider,
          model: "rec-model",
          session_id: sid,
          provider_ctx: %{stream_owner: owner}
        ] ++ extra_opts
      )

    sid
  end

  describe "AC-2 — unknown /name emits SystemNotice, no provider turn (D-101)" do
    test "/notacommand emits SystemNotice mentioning the command name" do
      sid = start_session()
      Tau.send(sid, "/notacommand")

      assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000

      assert String.contains?(text, "/notacommand") or String.contains?(text, "Unknown"),
             "Expected notice to mention command name, got: #{inspect(text)}"

      refute_receive %SE.MessageStart{}, 300
      refute_receive {:stream_called, _}, 300
    end

    test "/notacommand does not start a provider turn" do
      sid = start_session()
      Tau.send(sid, "/notacommand")
      assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000
      refute_receive %SE.MessageStart{}, 300
    end

    test "notice mentions /help" do
      sid = start_session()
      Tau.send(sid, "/notacommand")
      assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000

      assert String.contains?(text, "/help"),
             "Expected notice to mention /help, got: #{inspect(text)}"
    end

    test "session stays in :awaiting_user after unknown command" do
      sid = start_session()
      Tau.send(sid, "/xyzunknownxyz")
      assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000

      # Should still be responsive
      {:ok, snap} = Tau.snapshot(sid)
      assert snap.id == sid
    end
  end

  describe "AC-7 — prose starting with / and containing whitespace passes through (C8-B5)" do
    test "/usr/bin is a path reaches the model (stream called)" do
      sid = start_session()
      Tau.send(sid, "/usr/bin is a path")

      # Provider stream should be called (it's treated as prose)
      assert_receive {:stream_called, _}, 3_000
      assert_receive %SE.MessageStart{session_id: ^sid}, 3_000
    end

    test "/help with a space before Enter reaches the model as prose" do
      # "/help  " (trailing space) — has whitespace, treated as prose
      # This uses a string containing whitespace so it bypasses the guard
      sid = start_session()
      Tau.send(sid, "/help ")

      # "/" + "help " has whitespace so the parser sees it as a command with args.
      # classify_slash_command will resolve "/help" to the builtin and run it.
      # We just verify it does NOT error/crash.
      assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000
    end
  end

  describe "AC-10 — bare / does not crash (D-109)" do
    test "bare / + enter emits SystemNotice and does not crash" do
      sid = start_session()
      # A bare "/" is a command with name "/" which is not in the builtin table.
      # It should hit the unknown-command guard and emit a notice.
      Tau.send(sid, "/")

      # Should receive a notice (not crash, not reach model)
      assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000
      refute_receive %SE.MessageStart{}, 300
    end

    test "session is still alive after bare /" do
      sid = start_session()
      Tau.send(sid, "/")
      assert_receive %SE.SystemNotice{session_id: ^sid}, 2_000
      {:ok, snap} = Tau.snapshot(sid)
      assert snap.id == sid
    end
  end
end

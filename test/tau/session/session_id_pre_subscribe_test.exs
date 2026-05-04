defmodule Tau.Session.SessionIdPreSubscribeTest do
  @moduledoc """
  D-004 (SPEC-USER-TURN [C6]): a subscriber that allocates a session
  id, subscribes to `"session:<id>"`, and THEN calls
  `Tau.start_session(session_id: id)` MUST receive the
  `%Events.SessionStart{}` event. The TUI flow depends on this:
  `Session.init/1` broadcasts SessionStart synchronously from inside
  FSM init, so post-hoc subscription misses the event.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Session.Events, as: SE

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-presub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    %{data_dir: tmp}
  end

  test "Tau.Session.generate_id/0 is exposed as a public function" do
    assert function_exported?(Tau.Session, :generate_id, 0)
    id = Tau.Session.generate_id()
    assert is_binary(id)
    assert byte_size(id) > 0
  end

  test "subscribe-before-start receives SessionStart" do
    sid = Tau.Session.generate_id()
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: Tau.Providers.Replay,
        model: "replay"
      )

    assert_receive %SE.SessionStart{session_id: ^sid}, 1_000
  end
end

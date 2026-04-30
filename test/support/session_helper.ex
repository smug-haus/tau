defmodule Tau.Test.SessionHelper do
  @moduledoc """
  ExUnit-aware wrapper around `Tau.start_session/1` that registers
  an `on_exit/1` callback to stop the session when the test
  finishes (#52).

  Sessions are dynamically supervised under `Tau.Sessions.Supervisor`
  with `restart: :transient`. Without an explicit `Tau.stop/1`, the
  FSM survives the test that started it — accumulating zombie
  processes across the suite, holding open JSONL file descriptors
  even after the per-test data dir is `rm`'d in `on_exit`. The
  symptoms are subtle (memory bloat, occasional ordering-dependent
  test passes), the cause is not.

  Use this from any test that calls `Tau.start_session/1`:

      import Tau.Test.SessionHelper

      test "..." do
        {:ok, sid} = start_session_for_test(provider: ..., cwd: ...)
        # ... test body ...
        # No need to Tau.stop/1 — on_exit handles it.
      end

  Forwards every option to `Tau.start_session/1` unchanged.
  """

  @doc """
  Like `Tau.start_session/1`, but registers `Tau.stop/1` as an
  `on_exit/1` callback so the session FSM is shut down
  deterministically when the test finishes.

  Returns whatever `Tau.start_session/1` returns (`{:ok, sid}` or
  `{:error, reason}`); the cleanup is only registered on the
  success path.
  """
  @spec start_session_for_test(keyword()) ::
          {:ok, Tau.session_id()} | {:error, term()}
  def start_session_for_test(opts) do
    case Tau.start_session(opts) do
      {:ok, sid} = ok ->
        ExUnit.Callbacks.on_exit(fn ->
          # Tau.stop/1 returns :ok even for already-dead sessions.
          Tau.stop(sid)
        end)

        ok

      err ->
        err
    end
  end
end

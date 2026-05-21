defmodule Tau.Session.CacheTelemetryTest do
  @moduledoc """
  SPEC-PROMPT-CACHING AC-4 / C3 — `Tau.Session` emits a
  `[:tau, :session, :cache_usage]` telemetry event at the
  `:provider_done` boundary of every assistant turn.

  The event is the user-facing signal that a prompt-cache hit/miss
  occurred (a miss is a silent cost regression in the API). It reads
  the canonical B3 usage-map keys (`:cache_read` / `:cache_write` /
  `:cache_breakdown`) straight off the finalised assistant message —
  no callback indirection.

  Driven by an in-process fake provider that emits a `%Event.Done{}`
  carrying a chosen `usage` map, so the assertion targets the session
  telemetry boundary precisely.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Provider.Event.{Done, Start}
  alias Tau.Session.Events, as: SE

  defmodule UsageProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_messages, _opts, ctx) do
      usage = Map.get(ctx, :usage, %{})

      {:ok,
       [
         %Start{request_id: "usage-prov-1", model: "usage-prov"},
         %Done{stop_reason: :stop, usage: usage}
       ]}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: false,
        vision: false,
        prompt_caching: true,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "usage-prov"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-cache-tel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  defp run_turn(sid, usage) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")
    test_pid = self()
    handler_id = "cache-usage-#{sid}"

    :telemetry.attach(
      handler_id,
      [:tau, :session, :cache_usage],
      fn _ev, m, meta, _ -> send(test_pid, {:cache_usage, m, meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Phoenix.PubSub.unsubscribe(Tau.PubSub, "session:#{sid}")
    end)

    {:ok, ^sid} =
      start_session_for_test(
        session_id: sid,
        provider: UsageProvider,
        model: "usage-prov",
        provider_ctx: %{usage: usage}
      )

    :ok = Tau.send(sid, "go")
  end

  test "emits [:tau, :session, :cache_usage] with the write/read split and breakdown" do
    sid = "cache-tel-#{System.unique_integer([:positive])}"

    run_turn(sid, %{
      input_tokens: 50,
      output_tokens: 10,
      cache_read: 4096,
      cache_write: 256,
      cache_breakdown: %{ephemeral_5m: 256, ephemeral_1h: 0}
    })

    assert_receive {:cache_usage, measurements, metadata}, 5_000

    assert measurements == %{write_tokens: 256, read_tokens: 4096, storage_tokens: 0}
    assert metadata.session_id == sid
    assert metadata.provider == UsageProvider
    assert metadata.breakdown == %{ephemeral_5m: 256, ephemeral_1h: 0}

    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
  end

  test "emits zeros when the turn had no cache activity" do
    sid = "cache-tel-zero-#{System.unique_integer([:positive])}"

    run_turn(sid, %{input_tokens: 20, output_tokens: 5, cache_read: 0, cache_write: 0})

    assert_receive {:cache_usage, measurements, metadata}, 5_000

    assert measurements == %{write_tokens: 0, read_tokens: 0, storage_tokens: 0}
    assert metadata.breakdown == %{}
  end

  test "does not crash when usage omits the cache keys entirely" do
    sid = "cache-tel-missing-#{System.unique_integer([:positive])}"

    run_turn(sid, %{input_tokens: 1, output_tokens: 1})

    assert_receive {:cache_usage, %{write_tokens: 0, read_tokens: 0, storage_tokens: 0}, _}, 5_000
    assert_receive %SE.MessageEnd{session_id: ^sid}, 5_000
  end
end

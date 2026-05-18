defmodule Tau.Session.ProviderFallbackTest do
  @moduledoc """
  E2E test for ADR-0012 / #41: a retryable provider error mid-stream
  triggers a transparent fallback to the next provider in
  `settings.providers.fallback_chains[primary]`.

  The first provider emits an `%Event.Error{retryable?: true}` on the
  first stream call; the second provider emits a clean response. The
  session should:

    * end in `:awaiting_user`
    * have a single assistant message assembled from the SECOND
      provider
    * have a `provider_fallback` JSONL event
    * fire `[:tau, :provider, :fallback]` telemetry
    * broadcast `%Events.ProviderFallback{}` on PubSub
    * still postpone an interleaved user_message until the retry
      finishes (ADR-0009)
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @primary Tau.Session.ProviderFallbackTest.PrimaryProvider
  @secondary Tau.Session.ProviderFallbackTest.SecondaryProvider

  defmodule PrimaryProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _) do
      {:ok,
       [
         %Event.Start{request_id: "r-primary", model: "primary"},
         %Event.TextStart{block_id: "b0"},
         %Event.TextDelta{block_id: "b0", text: "(partial) "},
         %Event.Error{reason: {:http_status, 503}, retryable?: true}
       ]}
    end

    @impl true
    def capabilities,
      do: %{thinking: true, tools: true, vision: true, prompt_caching: true, parallel_tools: true}

    @impl true
    def default_model, do: "primary"
  end

  defmodule SecondaryProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _) do
      {:ok,
       [
         %Event.Start{request_id: "r-secondary", model: "secondary"},
         %Event.TextStart{block_id: "b0"},
         %Event.TextDelta{block_id: "b0", text: "from-secondary"},
         %Event.TextEnd{block_id: "b0"},
         %Event.Done{stop_reason: :stop, usage: %{}}
       ]}
    end

    @impl true
    def capabilities,
      do: %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }

    @impl true
    def default_model, do: "secondary"
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-fallback-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    # Inject the fallback chain via :persistent_term — the cache reads
    # via :persistent_term.get/2 (lock-free), so this is the canonical
    # test override that doesn't race with the loader.
    prior_settings = :persistent_term.get({Tau, :settings}, %{})

    :persistent_term.put({Tau, :settings}, %{
      providers: %{
        fallback_chains: %{
          @primary => [@secondary]
        }
      }
    })

    on_exit(fn ->
      :persistent_term.put({Tau, :settings}, prior_settings)
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    :ok
  end

  test "session falls back to secondary provider on retryable error" do
    sid = "fallback-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    test_pid = self()

    :telemetry.attach_many(
      "tau-fallback-test-#{sid}",
      [[:tau, :provider, :fallback]],
      fn event, measurements, metadata, _ ->
        Kernel.send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("tau-fallback-test-#{sid}") end)

    {:ok, ^sid} =
      start_session_for_test(
        provider: @primary,
        model: "primary",
        session_id: sid
      )

    Tau.send(sid, "hello?")

    # The secondary's clean Done finalises the assistant message.
    assert_receive %SE.MessageEnd{message: msg}, 5_000

    # The final message came from the SECONDARY provider — its text is
    # `from-secondary`, not the primary's `(partial) `.
    assert msg.stop_reason == :stop
    assert [%{type: :text, text: "from-secondary"}] = msg.content

    assert msg.stop_reason != :error,
           "retryable mid-stream error MUST trigger fallback, not terminal finalize (clause-order guard)"

    # Fallback PubSub event reached the subscriber.
    assert_receive %SE.ProviderFallback{
                     from_provider: @primary,
                     to_provider: @secondary,
                     session_id: ^sid
                   },
                   5_000

    # Telemetry fired with from/to/reason/session_id.
    assert_receive {:telemetry, [:tau, :provider, :fallback], _measurements, metadata}, 5_000
    assert metadata.from_provider == @primary
    assert metadata.to_provider == @secondary
    assert metadata.session_id == sid
    assert metadata.reason == {:http_status, 503}

    # Snapshot reflects the per-message-fallback semantic: provider has
    # been restored to the original.
    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    assert snap.provider == @primary

    # JSONL has a `provider_fallback` event.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    kinds =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(& &1["kind"])

    assert "provider_fallback" in kinds
  end

  test "interleaved user_message during fallback is postponed (ADR-0009)" do
    sid = "fallback-q-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: @primary,
        model: "primary",
        session_id: sid
      )

    Tau.send(sid, "first")
    # Send a second user message immediately — it should not interleave
    # with the fallback retry; it gets postponed until :awaiting_user.
    Tau.send(sid, "second")

    # First turn finishes (after fallback) — secondary's clean Done.
    assert_receive %SE.MessageEnd{message: %{content: [%{text: "from-secondary"}]}}, 5_000

    # Second turn finishes — primary errors again, secondary again
    # produces "from-secondary".
    assert_receive %SE.MessageEnd{message: %{content: [%{text: "from-secondary"}]}}, 5_000
  end
end

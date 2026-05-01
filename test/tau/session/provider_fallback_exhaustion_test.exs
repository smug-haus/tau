defmodule Tau.Session.ProviderFallbackExhaustionTest do
  @moduledoc """
  ADR-0012 / #41: when every provider in the chain emits a retryable
  error, the original error surfaces and the assistant message ends
  with `stop_reason: :error`. No `provider_fallback` event past the
  last hop.
  """
  use ExUnit.Case, async: false

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]
  alias Tau.Provider.Event
  alias Tau.Session.Events, as: SE

  @primary Tau.Session.ProviderFallbackExhaustionTest.AlwaysFailA
  @secondary Tau.Session.ProviderFallbackExhaustionTest.AlwaysFailB

  defmodule AlwaysFailA do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _) do
      {:ok,
       [
         %Event.Start{request_id: "r-a", model: "a"},
         %Event.Error{reason: {:http_status, 503}, retryable?: true}
       ]}
    end

    @impl true
    def capabilities do
      %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }
    end

    @impl true
    def default_model, do: "a"
  end

  defmodule AlwaysFailB do
    @moduledoc false
    @behaviour Tau.Provider

    @impl true
    def stream(_, _, _) do
      {:ok,
       [
         %Event.Start{request_id: "r-b", model: "b"},
         %Event.Error{reason: {:http_status, 504}, retryable?: true}
       ]}
    end

    @impl true
    def capabilities do
      %{
        thinking: false,
        tools: true,
        vision: false,
        prompt_caching: false,
        parallel_tools: false
      }
    end

    @impl true
    def default_model, do: "b"
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "tau-fallback-exh-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

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

  test "exhausted chain surfaces the last error and stays in :awaiting_user" do
    sid = "exh-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        provider: @primary,
        model: "a",
        session_id: sid
      )

    Tau.send(sid, "hello?")

    assert_receive %SE.MessageEnd{message: msg}, 5_000

    # Final message reflects the *secondary*'s error (the last hop).
    assert msg.stop_reason == :error

    {:ok, snap} = Tau.snapshot(sid)
    assert snap.state == :awaiting_user
    # Provider restored to the configured primary.
    assert snap.provider == @primary

    # Exactly one `provider_fallback` event in the JSONL — primary -> secondary.
    [path] = Path.wildcard(Path.join(Tau.Settings.data_dir(), "sessions/*/#{sid}.jsonl"))

    fallback_count =
      File.read!(path)
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.count(&(&1["kind"] == "provider_fallback"))

    assert fallback_count == 1
  end
end

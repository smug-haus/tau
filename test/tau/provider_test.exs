defmodule Tau.ProviderTest do
  @moduledoc """
  Covers the `Tau.Provider.chat/4` provider-agnostic entry point
  (#36): default-impl drain, native-override delegation, and error
  surface.
  """
  use ExUnit.Case, async: true

  alias Tau.Provider.Event

  defmodule SyncErrorProvider do
    @behaviour Tau.Provider

    @impl true
    def stream(_msgs, _opts, _ctx), do: {:error, :missing_api_key}

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
    def default_model, do: "sync-err"
  end

  defmodule NativeChatProvider do
    @behaviour Tau.Provider

    @impl true
    def stream(_msgs, _opts, _ctx) do
      raise "stream/3 should not be called when chat/3 is defined"
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
    def default_model, do: "native"

    @impl true
    def chat(_msgs, _opts, _ctx) do
      {:ok,
       Tau.Message.Assistant.new(content: [%{type: :text, text: "native"}], stop_reason: :stop)}
    end
  end

  describe "Tau.Provider.chat/4 default implementation" do
    test "drains a Replay stream into an assembled %Assistant{}" do
      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.TextStart{block_id: "b"},
        %Event.TextDelta{block_id: "b", text: "hello "},
        %Event.TextDelta{block_id: "b", text: "world"},
        %Event.TextEnd{block_id: "b"},
        %Event.Done{stop_reason: :stop, usage: %{output_tokens: 2}}
      ]

      {:ok, msg} =
        Tau.Provider.chat(
          Tau.Providers.Replay,
          [Tau.Message.User.new("hi")],
          %{model: "replay"},
          %{replay_fixture: fixture}
        )

      assert %Tau.Message.Assistant{stop_reason: :stop} = msg
      assert [%{type: :text, text: "hello world"}] = msg.content
      assert msg.usage == %{output_tokens: 2}
    end

    test "in-stream %Event.Error{} surfaces as {:error, reason}" do
      fixture = [
        %Event.Start{request_id: "r", model: "replay"},
        %Event.Error{reason: {:http_status, 503}, retryable?: true}
      ]

      assert {:error, {:http_status, 503}} =
               Tau.Provider.chat(
                 Tau.Providers.Replay,
                 [Tau.Message.User.new("hi")],
                 %{},
                 %{replay_fixture: fixture}
               )
    end

    test "synchronous {:error, _} from stream/3 surfaces unchanged" do
      assert {:error, :missing_api_key} =
               Tau.Provider.chat(SyncErrorProvider, [Tau.Message.User.new("hi")], %{}, %{})
    end
  end

  describe "Tau.Provider.chat/4 native override" do
    test "delegates to provider.chat/3 when exported, bypassing stream/3" do
      assert {:ok, msg} = Tau.Provider.chat(NativeChatProvider, [], %{}, %{})
      assert [%{type: :text, text: "native"}] = msg.content
    end
  end
end

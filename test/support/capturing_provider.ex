defmodule Tau.Test.CapturingProvider do
  @moduledoc """
  Test-only provider that captures the `stream_opts` of every
  `stream/3` call so tests can assert on what the session FSM
  actually exposed to the provider (notably `stream_opts[:tools]`).

  Returns a benign canned event stream by default (a single
  `:end_turn` text turn) so the session FSM completes without
  needing a tool round-trip.

  ## Routing the capture back to the test

  `stream/3` resolves the receiver in this order:

    1. If `ctx[:report_to]` is a pid, send to that pid.
    2. Else if a process is registered under the atom name in
       `ctx[:capture_name]`, send to that process.
    3. Else if a process is registered under the default name
       `:tau_capturing_provider` (see `default_capture_name/0`), send
       to it.
    4. Else: do nothing (the message is dropped — tests that don't
       care about the capture are still free to use this provider).

  In every case the message has the shape `{:stream_opts, opts}`.

  ## Per-test register/unregister

  The simplest pattern is:

      setup do
        Process.register(self(), Tau.Test.CapturingProvider.default_capture_name())
        :ok
      end

  Tests that want to override the canned events can stash a list of
  `Tau.Provider.Event` structs under `ctx[:capturing_events]` — when
  set, that list is returned instead of the default.

  This is the shared-library generalisation of the inline
  `RecordingProvider` in `test/tau/cli/headless_run_tool_exposure_test.exs`
  — same shape, plus a configurable receiver and an event override.
  Kept here so other tests (notably the `mix tau.qa` layer-E suite,
  issue #268) can re-use it without duplicating the pattern.
  """

  @behaviour Tau.Provider

  alias Tau.Provider.Event

  @default_capture_name :tau_capturing_provider

  @doc "The atom name `stream/3` looks up when neither `:report_to` nor `:capture_name` is set."
  @spec default_capture_name() :: atom()
  def default_capture_name, do: @default_capture_name

  @impl Tau.Provider
  def stream(_messages, opts, ctx) do
    if pid = resolve_receiver(ctx) do
      send(pid, {:stream_opts, opts})
    end

    events = ctx[:capturing_events] || default_events()
    {:ok, events}
  end

  @impl Tau.Provider
  def capabilities,
    do: %{
      thinking: false,
      tools: true,
      vision: false,
      prompt_caching: false,
      parallel_tools: true
    }

  @impl Tau.Provider
  def default_model, do: "capturing"

  # --- internals ----------------------------------------------------------

  defp resolve_receiver(ctx) do
    cond do
      is_pid(ctx[:report_to]) ->
        ctx[:report_to]

      is_atom(ctx[:capture_name]) and not is_nil(ctx[:capture_name]) ->
        Process.whereis(ctx[:capture_name])

      true ->
        Process.whereis(@default_capture_name)
    end
  end

  defp default_events do
    [
      %Event.Start{request_id: "cap-1", model: "capturing"},
      %Event.TextStart{block_id: "b0"},
      %Event.TextDelta{block_id: "b0", text: "(capturing) ok"},
      %Event.TextEnd{block_id: "b0"},
      %Event.Done{stop_reason: :end_turn, usage: %{}}
    ]
  end
end

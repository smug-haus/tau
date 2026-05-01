defmodule Tau.Cost.Tracker do
  @moduledoc """
  ETS-owner process for cost / token-usage aggregation.

  Per ADR-0010: this `GenServer` exists to anchor the lifecycle of
  the named `:tau_cost_counters` ETS table and to keep a telemetry
  handler attached. It deliberately holds no state in its
  `GenServer` mailbox — writers call `:ets.update_counter/3`
  directly from the telemetry handler, and readers
  (`Tau.Cost.summary/0`, `Tau.Cost.summary/1`) do table scans
  without going through this process.

  ## ETS shape

      key   :: {date_iso8601 :: String.t(), provider :: module(),
                 model :: String.t() | nil, session_id :: String.t()}
      value :: {input_tokens, output_tokens, cache_read, cache_write}

  Stored as a 5-element row tuple `{key, in, out, cr, cw}` so all
  four counters can be bumped with a single atomic
  `:ets.update_counter/3` call.

  ## Telemetry contract

  Subscribed to `[:tau, :provider, :request, :stop]`. Expected
  measurements: a numeric `usage` field with keys
  `:input_tokens`, `:output_tokens`, `:cache_read`,
  `:cache_write` (zeros for missing keys are fine). Expected
  metadata: `provider :: module()`, `model :: String.t() | nil`,
  `session_id :: String.t()`. Events lacking the required keys
  are dropped silently — observability data, not source of truth.
  """

  use GenServer

  @table :tau_cost_counters
  @handler_id "tau-cost-tracker"

  @type counters :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @doc "Start the tracker (typically supervised by `Tau.Telemetry.Supervisor`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "ETS table name. Exposed for tests."
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :telemetry.attach(
      @handler_id,
      [:tau, :provider, :request, :stop],
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(_event, measurements, metadata, _config) do
    with provider when is_atom(provider) and not is_nil(provider) <- metadata[:provider],
         session_id when is_binary(session_id) <- metadata[:session_id],
         usage when is_map(usage) <- measurements[:usage] do
      key = {today_iso(), provider, metadata[:model], session_id}

      input = nz(usage[:input_tokens])
      output = nz(usage[:output_tokens])
      cr = nz(usage[:cache_read])
      cw = nz(usage[:cache_write])

      :ets.update_counter(
        @table,
        key,
        [{2, input}, {3, output}, {4, cr}, {5, cw}],
        {key, 0, 0, 0, 0}
      )
    else
      _ -> :ok
    end
  end

  defp today_iso, do: Date.utc_today() |> Date.to_iso8601()

  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_), do: 0
end

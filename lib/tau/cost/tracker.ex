defmodule Tau.Cost.Tracker do
  @moduledoc """
  ETS-owner process for cost / token-usage aggregation.

  Per ADR-0010: this `GenServer` exists to anchor the lifecycle of
  the named `:tau_cost_counters` ETS table and to keep telemetry
  handlers attached. It deliberately holds no state in its
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

  When the row originates from a coding-agent run (D-038), the
  `provider` slot in the key is set to the adapter module
  (`Tau.CodingAgents.ClaudeCode` etc.). `Tau.Cost.summary/0`'s
  `:by_provider` map therefore presents the split — Anthropic-direct
  vs Claude Code, Aider, … — without a schema change. The line item
  carries its `coding_agent.<agent>` / `provider.<provider>` source
  tag via the `[:tau, :coding_agent, :cost]` telemetry event for
  any downstream consumer that wants the explicit string.

  ## Telemetry contract

  Two events feed the table:

    * `[:tau, :provider, :request, :stop]` — the existing path.
      Measurements: `usage :: map()` with
      `:input_tokens`, `:output_tokens`, `:cache_read`,
      `:cache_write`. Metadata: `provider :: module()`,
      `model :: String.t() | nil`, `session_id :: String.t()`.
    * `[:tau, :coding_agent, :cost]` — D-034 / D-038 addition.
      Measurements: `usd :: float() | nil`,
      `duration_ms :: non_neg_integer()`,
      `input_tokens`, `output_tokens`, `cache_read`, `cache_write`.
      Metadata: `session_id :: String.t()`, `agent :: module()`,
      `model :: String.t() | nil`, `source :: String.t()` (e.g.
      `"coding_agent.claude_code"`).

  Events lacking the required keys are dropped silently —
  observability data, not source of truth. Failures inside the
  handler are caught and logged via `[:tau, :cost, :tracker,
  :handler_failed]` so a malformed cost event MUST NOT crash the
  session that emitted it (D-035).
  """

  use GenServer

  require Logger

  @table :tau_cost_counters
  @handler_id "tau-cost-tracker"
  @coding_agent_handler_id "tau-cost-tracker-coding-agent"

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

    # D-038 / SPEC-CODING-AGENT §7 Q4: coding-agent runs fold their
    # `%Event.Cost{}` into the same ETS table via a dedicated event
    # so the user sees the split between provider-direct and
    # coding-agent cost without a schema change.
    :telemetry.attach(
      @coding_agent_handler_id,
      [:tau, :coding_agent, :cost],
      &__MODULE__.handle_coding_agent_cost/4,
      nil
    )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :telemetry.detach(@coding_agent_handler_id)
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

  @doc false
  # D-035: cost-folding errors MUST degrade gracefully. A
  # mis-shaped measurement bag MUST NOT bubble out of the
  # telemetry handler and crash the session that emitted it.
  def handle_coding_agent_cost(_event, measurements, metadata, _config) do
    with agent when is_atom(agent) and not is_nil(agent) <- metadata[:agent],
         session_id when is_binary(session_id) <- metadata[:session_id] do
      key = {today_iso(), agent, metadata[:model], session_id}

      input = nz(measurements[:input_tokens])
      output = nz(measurements[:output_tokens])
      cr = nz(measurements[:cache_read])
      cw = nz(measurements[:cache_write])

      :ets.update_counter(
        @table,
        key,
        [{2, input}, {3, output}, {4, cr}, {5, cw}],
        {key, 0, 0, 0, 0}
      )
    else
      _ -> :ok
    end
  rescue
    e ->
      :telemetry.execute(
        [:tau, :cost, :tracker, :handler_failed],
        %{system_time: System.system_time()},
        %{reason: Exception.message(e)}
      )

      :ok
  end

  defp today_iso, do: Date.utc_today() |> Date.to_iso8601()

  defp nz(n) when is_integer(n) and n >= 0, do: n
  defp nz(_), do: 0
end

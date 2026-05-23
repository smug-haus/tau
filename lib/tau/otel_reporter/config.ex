defmodule Tau.OtelReporter.Config do
  @moduledoc """
  Pure-function module. Reads the `:tau, :otel` application env and returns
  a validated config struct.

  SPEC-OTEL-REPORTER §2 / D-055.
  No process. No side effects.
  """

  @default_endpoint "http://localhost:4317"
  @default_sampling_ratio 1.0
  @default_max_open_spans 1_000
  @default_sweep_interval_ms 60_000
  @default_sweep_age_ms 120_000

  defstruct [
    :enabled,
    :endpoint,
    :sampling_ratio,
    :max_open_spans,
    :sweep_interval_ms,
    :sweep_age_ms,
    :headers,
    # Optional event families (SPEC §4 B1 — default off).
    # MCP and compaction spans require their emit sites to carry span_ref
    # before they can correlate; attach only when explicitly enabled.
    :mcp_spans_enabled,
    :compaction_spans_enabled,
    :permissions_spans_enabled
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          endpoint: String.t(),
          sampling_ratio: float(),
          max_open_spans: pos_integer(),
          sweep_interval_ms: pos_integer(),
          sweep_age_ms: pos_integer(),
          headers: [{String.t(), String.t()}],
          mcp_spans_enabled: boolean(),
          compaction_spans_enabled: boolean(),
          permissions_spans_enabled: boolean()
        }

  @doc """
  Reads the `:tau, :otel` application env and returns a validated `Config` struct.
  Always returns a struct; `enabled: false` when no OTel config is present.
  """
  @spec load() :: t()
  def load do
    otel_env = Application.get_env(:tau, :otel, [])
    from_keyword(otel_env)
  end

  @doc """
  Builds a `Config` struct from a keyword list (for testing).
  """
  @spec from_keyword(keyword()) :: t()
  def from_keyword(kw) do
    %__MODULE__{
      enabled: Keyword.get(kw, :enabled, false),
      endpoint: Keyword.get(kw, :endpoint, @default_endpoint),
      sampling_ratio: clamp_ratio(Keyword.get(kw, :sampling_ratio, @default_sampling_ratio)),
      max_open_spans: pos_integer(Keyword.get(kw, :max_open_spans, @default_max_open_spans)),
      sweep_interval_ms:
        pos_integer(Keyword.get(kw, :sweep_interval_ms, @default_sweep_interval_ms)),
      sweep_age_ms: pos_integer(Keyword.get(kw, :sweep_age_ms, @default_sweep_age_ms)),
      headers: Keyword.get(kw, :headers, []),
      mcp_spans_enabled: Keyword.get(kw, :mcp_spans_enabled, false),
      compaction_spans_enabled: Keyword.get(kw, :compaction_spans_enabled, false),
      permissions_spans_enabled: Keyword.get(kw, :permissions_spans_enabled, false)
    }
  end

  defp clamp_ratio(r) when is_float(r) and r >= 0.0 and r <= 1.0, do: r
  defp clamp_ratio(r) when is_integer(r) and r >= 0 and r <= 1, do: r * 1.0
  defp clamp_ratio(_), do: @default_sampling_ratio

  defp pos_integer(n) when is_integer(n) and n > 0, do: n
  defp pos_integer(_), do: 1
end

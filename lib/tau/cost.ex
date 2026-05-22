defmodule Tau.Cost do
  @moduledoc """
  Read-side API for cost / token-usage aggregates (#40).

  All counters live in the `:tau_cost_counters` ETS table owned by
  `Tau.Cost.Tracker` (ADR-0010). Updates flow from the
  `[:tau, :provider, :request, :stop]` telemetry event; readers
  here do table scans.

  Token aggregation only. Pricing-per-model and dollar-spend estimates
  live in a separate concern; pricing tables churn faster than the
  surrounding code.
  """

  alias Tau.Cost.Tracker

  @type counters :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }

  @type bucket_key :: %{
          provider: module(),
          model: String.t() | nil,
          session_id: String.t() | nil,
          date: String.t()
        }

  @type bucket :: {bucket_key(), counters()}

  @doc """
  Aggregate usage for a date (defaults to today, UTC).

  Returns a map of `%{by_provider: ..., by_session: ...,
  by_model: ..., totals: ...}`. Each `by_*` map is keyed by the
  grouping value and carries a `t:counters/0` value.
  """
  @spec summary(Date.t() | String.t() | nil) :: %{
          date: String.t(),
          totals: counters(),
          by_provider: %{module() => counters()},
          by_model: %{{module(), String.t() | nil} => counters()},
          by_session: %{String.t() => counters()}
        }
  def summary(date \\ nil) do
    iso = to_iso(date || Date.utc_today())
    rows = rows_for_date(iso)

    %{
      date: iso,
      totals: fold(rows, fn _ -> :total end) |> Map.get(:total, zeros()),
      by_provider: fold(rows, fn {_d, p, _m, _s} -> p end),
      by_model: fold(rows, fn {_d, p, m, _s} -> {p, m} end),
      by_session: fold(rows, fn {_d, _p, _m, s} -> s end)
    }
  end

  @doc """
  Counters scoped to a single session across all dates.
  """
  @spec for_session(String.t()) :: counters()
  def for_session(session_id) when is_binary(session_id) do
    Tracker.table()
    |> :ets.match_object({{:_, :_, :_, session_id}, :_, :_, :_, :_})
    |> Enum.reduce(zeros(), &add_row/2)
  end

  @doc """
  Reset all counters. Test-only.
  """
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(Tracker.table())
    :ok
  end

  # --- private --------------------------------------------------------------

  defp rows_for_date(iso) do
    :ets.match_object(Tracker.table(), {{iso, :_, :_, :_}, :_, :_, :_, :_})
  end

  defp fold(rows, key_fun) do
    Enum.reduce(rows, %{}, fn {{_, _, _, _} = k, _, _, _, _} = row, acc ->
      g = key_fun.(k)
      Map.update(acc, g, add_row(row, zeros()), &add_row(row, &1))
    end)
  end

  defp add_row({_, in_, out, cr, cw}, %{
         input_tokens: i,
         output_tokens: o,
         cache_read: r,
         cache_write: w
       }) do
    %{
      input_tokens: i + in_,
      output_tokens: o + out,
      cache_read: r + cr,
      cache_write: w + cw
    }
  end

  defp zeros, do: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0}

  defp to_iso(%Date{} = d), do: Date.to_iso8601(d)
  defp to_iso(s) when is_binary(s), do: s
end

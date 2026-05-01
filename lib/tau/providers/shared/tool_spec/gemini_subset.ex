defmodule Tau.Providers.Shared.ToolSpec.GeminiSubset do
  @moduledoc """
  Down-shifter from a generic JSON-Schema tool spec to the reduced subset
  Gemini's `functionDeclarations` accepts.

  Gemini's schema dialect is a strict subset of JSON Schema:

    * `oneOf` (and the related `anyOf`) are not supported and must be
      removed — composing a working subset is beyond the scope of this
      adapter, so we strip them and emit a one-shot warning.
    * `additionalProperties` cannot be a schema (only `false` or absent)
      — we clamp any non-`false` value to `false`.

  Other constructs Gemini doesn't support (e.g. `$ref`, `format`-specific
  keywords) are left in place: the model server will reject them with a
  clearer error than anything we could synthesise here. ADR-0003 stays
  in force — we never silently coerce types or relax invalid schemas.
  """

  require Logger

  @doc """
  Down-shift a JSON-Schema map to Gemini's accepted subset.

  Returns the rewritten schema. Idempotent: re-running on output produces
  the same map.
  """
  @spec downshift(map() | nil) :: map() | nil
  def downshift(nil), do: nil

  def downshift(schema) when is_map(schema) do
    {result, lossy?} = walk(schema, false)

    if lossy? do
      Logger.warning(
        "Tau.Providers.Shared.ToolSpec.GeminiSubset: dropped unsupported keywords " <>
          "(oneOf/anyOf or schema-valued additionalProperties) while down-shifting tool " <>
          "schema for Gemini. The remaining schema is a subset of the original."
      )
    end

    result
  end

  # --- recursive walk -------------------------------------------------------

  defp walk(%{} = map, lossy?) do
    Enum.reduce(map, {%{}, lossy?}, fn {k, v}, {acc, l} ->
      cond do
        k in ["oneOf", "anyOf", :oneOf, :anyOf] ->
          {acc, true}

        k in ["additionalProperties", :additionalProperties] and is_map(v) ->
          {Map.put(acc, k, false), true}

        true ->
          {v2, l2} = walk(v, l)
          {Map.put(acc, k, v2), l2}
      end
    end)
  end

  defp walk(list, lossy?) when is_list(list) do
    Enum.reduce(list, {[], lossy?}, fn elem, {acc, l} ->
      {e2, l2} = walk(elem, l)
      {acc ++ [e2], l2}
    end)
  end

  defp walk(other, lossy?), do: {other, lossy?}
end

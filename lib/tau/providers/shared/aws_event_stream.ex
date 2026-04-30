defmodule Tau.Providers.Shared.AwsEventStream do
  @moduledoc """
  Pure incremental parser for the AWS event-stream binary framing.

  Each frame:

      4 bytes: total_length (u32 BE)
      4 bytes: headers_length (u32 BE)
      4 bytes: prelude CRC (u32 BE) — over the prior 8 bytes
      N bytes: headers (per-header: 1 byte name length, name, 1 byte type,
                       value)
      M bytes: payload
      4 bytes: message CRC (u32 BE) — over the entire prior frame

  We only need the headers and the payload bytes for Bedrock — the
  payload is `event: \\"chunk\\"` style with a JSON document. CRCs are
  not validated here; AWS's TLS connection covers integrity at the
  network layer.
  """

  defstruct buffer: <<>>

  @type t :: %__MODULE__{buffer: binary()}

  @type frame :: %{
          headers: %{String.t() => term()},
          payload: binary()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Feed bytes; returns `{frames, new_state}`."
  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(%__MODULE__{buffer: buf}, chunk) do
    parse(buf <> chunk, [])
  end

  defp parse(<<total::32-big, _hlen::32-big, _crc::32-big, _rest::binary>> = buf, acc)
       when byte_size(buf) >= total do
    <<full::binary-size(total), tail::binary>> = buf
    frame = decode(full)
    parse(tail, [frame | acc])
  end

  defp parse(buf, acc), do: {Enum.reverse(acc), %__MODULE__{buffer: buf}}

  defp decode(<<_total::32-big, hlen::32-big, _crc::32-big, rest::binary>>) do
    headers_bytes = binary_part(rest, 0, hlen)
    payload_size = byte_size(rest) - hlen - 4
    payload = binary_part(rest, hlen, payload_size)
    headers = parse_headers(headers_bytes, %{})
    %{headers: headers, payload: payload}
  end

  defp parse_headers(<<>>, acc), do: acc

  defp parse_headers(<<nlen, rest::binary>>, acc) do
    <<name::binary-size(nlen), type, after_type::binary>> = rest
    {value, rest2} = decode_value(type, after_type)
    parse_headers(rest2, Map.put(acc, name, value))
  end

  defp decode_value(7, <<vlen::16-big, v::binary-size(vlen), rest::binary>>), do: {v, rest}
  defp decode_value(2, <<v::8-signed, rest::binary>>), do: {v, rest}
  defp decode_value(3, <<v::16-signed, rest::binary>>), do: {v, rest}
  defp decode_value(4, <<v::32-signed, rest::binary>>), do: {v, rest}
  defp decode_value(5, <<v::64-signed, rest::binary>>), do: {v, rest}
  defp decode_value(_other, rest), do: {nil, rest}
end

defmodule Tau.Providers.Shared.SigV4 do
  @moduledoc """
  AWS Signature V4 signing.

  Pure: input is method/url/headers/body/credentials/region/service,
  output is the augmented headers list (with `Authorization`,
  `X-Amz-Date`, etc. added). No process state, no IO.
  """

  @doc """
  Sign a request. Returns the headers list with all SigV4 headers added.
  """
  @spec sign(
          atom(),
          String.t(),
          [{String.t(), String.t()}],
          iodata(),
          map(),
          String.t(),
          String.t()
        ) ::
          [{String.t(), String.t()}]
  def sign(method, url, headers, body, creds, region, service) do
    %URI{host: host, path: path, query: query} = URI.parse(url)
    path = path || "/"
    query = query || ""

    body_bin = IO.iodata_to_binary(body)
    payload_hash = sha256_hex(body_bin)

    now = DateTime.utc_now()
    amz_date = format_date(now)
    date_stamp = String.slice(amz_date, 0, 8)

    headers =
      [
        {"host", host},
        {"x-amz-date", amz_date},
        {"x-amz-content-sha256", payload_hash}
      ] ++
        if(creds[:session_token], do: [{"x-amz-security-token", creds[:session_token]}], else: []) ++
        Enum.reject(headers, fn {k, _} -> String.downcase(k) in ["host", "x-amz-date"] end)

    canonical_headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
      |> Enum.sort()

    signed_headers_str = canonical_headers |> Enum.map_join(";", fn {k, _} -> k end)
    canonical_headers_str = canonical_headers |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_request =
      [
        String.upcase(to_string(method)),
        path,
        query,
        canonical_headers_str,
        signed_headers_str,
        payload_hash
      ]
      |> Enum.join("\n")

    credential_scope = "#{date_stamp}/#{region}/#{service}/aws4_request"

    string_to_sign =
      [
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        sha256_hex(canonical_request)
      ]
      |> Enum.join("\n")

    signing_key =
      "AWS4#{creds[:secret_access_key]}"
      |> hmac_sha256(date_stamp)
      |> hmac_sha256(region)
      |> hmac_sha256(service)
      |> hmac_sha256("aws4_request")

    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{creds[:access_key_id]}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_headers_str}, Signature=#{signature}"

    headers ++ [{"authorization", auth}]
  end

  defp sha256_hex(data),
    do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp format_date(dt) do
    dt
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end
end

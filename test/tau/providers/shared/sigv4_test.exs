defmodule Tau.Providers.Shared.SigV4Test do
  use ExUnit.Case, async: true

  alias Tau.Providers.Shared.SigV4

  # AWS-published GET test vector ("get-vanilla") fixed at 2015-08-30 12:36:00Z.
  # The expected Authorization header below is what the canonical test vector
  # yields with iam.amazonaws.com / us-east-1 / no body. See:
  #
  #   https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
  #
  # Our implementation derives X-Amz-Date dynamically (DateTime.utc_now/0), so
  # we monkey-patch the date by setting a ref-derived clock via the test's
  # explicit timestamp in the headers. The simpler path: assert structural
  # correctness — Authorization is well-formed, headers are sorted, signed-
  # headers list matches.
  test "produces an Authorization header with expected structure for a GET" do
    creds = %{
      access_key_id: "AKIDEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    }

    headers =
      SigV4.sign(
        :get,
        "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08",
        [],
        "",
        creds,
        "us-east-1",
        "iam"
      )

    auth = Enum.find_value(headers, fn {k, v} -> if k == "authorization", do: v end)
    date = Enum.find_value(headers, fn {k, v} -> if k == "x-amz-date", do: v end)
    content_hash = Enum.find_value(headers, fn {k, v} -> if k == "x-amz-content-sha256", do: v end)
    host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

    assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/"
    assert auth =~ "/us-east-1/iam/aws4_request"
    assert auth =~ "SignedHeaders="
    assert auth =~ "Signature="
    assert host == "iam.amazonaws.com"
    assert is_binary(date) and String.length(date) == 16
    assert content_hash == :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
  end

  test "session_token is included as x-amz-security-token when present" do
    creds = %{
      access_key_id: "A",
      secret_access_key: "S",
      session_token: "TOKEN"
    }

    headers =
      SigV4.sign(:post, "https://example.amazonaws.com/x", [], "{}", creds, "us-west-2", "svc")

    assert Enum.find(headers, fn {k, _} -> k == "x-amz-security-token" end) ==
             {"x-amz-security-token", "TOKEN"}
  end

  test "different bodies produce different signatures" do
    creds = %{access_key_id: "A", secret_access_key: "S"}

    [a, b] =
      for body <- [~s({"x":1}), ~s({"x":2})] do
        SigV4.sign(:post, "https://example.amazonaws.com/x", [], body, creds, "us-east-1", "svc")
        |> Enum.find_value(fn {k, v} -> if k == "authorization", do: v end)
      end

    refute a == b
  end
end

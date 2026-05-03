defmodule Tau.Providers.Anthropic.AuthHeadersTest do
  @moduledoc """
  D-017 (SPEC-USER-TURN [C46]/[C47]): integration test that the
  `Tau.Providers.Anthropic` provider sends the correct headers for
  each auth path.

    * API-key auth → `x-api-key: <key>` (no Authorization header).
    * OAuth auth   → `authorization: Bearer <token>` AND
      `anthropic-beta: oauth-2025-04-20,...` (no `x-api-key`).

  Uses Bypass to capture the request without hitting the real
  Anthropic API.
  """
  use ExUnit.Case, async: false

  alias Tau.Message.User

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    Application.put_env(:tau, Tau.Providers.Anthropic, base_url: base_url)

    on_exit(fn ->
      Application.delete_env(:tau, Tau.Providers.Anthropic)
    end)

    %{bypass: bypass}
  end

  defp drain_stream({:ok, stream}) do
    # Force evaluation so the HTTP request actually fires.
    try do
      Enum.to_list(stream)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp drain_stream(other), do: other

  describe "API-key auth → x-api-key header (D-017)" do
    test "sends x-api-key when :api_key opt is set", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        headers = Map.new(conn.req_headers)

        assert headers["x-api-key"] == "sk-ant-api03-test-key"
        refute headers["authorization"]
        assert headers["anthropic-version"]

        Plug.Conn.resp(conn, 200, "")
      end)

      Tau.Providers.Anthropic.stream(
        [User.new("hi")],
        %{model: "claude-opus-4-7", api_key: "sk-ant-api03-test-key"},
        %{}
      )
      |> drain_stream()
    end
  end

  describe "OAuth auth → Bearer header + oauth-2025-04-20 beta (D-017)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tau-auth-headers-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      path = Path.join(tmp, "creds.json")

      File.write!(
        path,
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-bearer-token",
            "refreshToken" => "sk-ant-ort01-x",
            "expiresAt" => :os.system_time(:millisecond) + 60 * 60 * 1000,
            "scopes" => ["user:inference", "user:profile"],
            "subscriptionType" => "max",
            "rateLimitTier" => "default"
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{credentials_path: path}
    end

    test "sends Authorization: Bearer and oauth-2025-04-20 beta when only OAuth file is set",
         %{bypass: bypass, credentials_path: creds_path} do
      Bypass.expect_once(bypass, "POST", "/v1/messages", fn conn ->
        headers = Map.new(conn.req_headers)

        assert headers["authorization"] == "Bearer sk-ant-oat01-bearer-token"
        refute headers["x-api-key"]

        beta = headers["anthropic-beta"]
        assert is_binary(beta)
        assert beta =~ "oauth-2025-04-20",
               "Anthropic Messages API requires the oauth-2025-04-20 beta header for OAuth tokens; got #{inspect(beta)}"

        Plug.Conn.resp(conn, 200, "")
      end)

      Tau.Providers.Anthropic.stream(
        [User.new("hi")],
        %{model: "claude-opus-4-7", credentials_path: creds_path},
        %{}
      )
      |> drain_stream()
    end
  end
end

defmodule Tau.Providers.Anthropic.AuthTest do
  @moduledoc """
  D-017 / D-018 / D-019 (SPEC-USER-TURN): the Anthropic auth resolver
  must support both the API-key path and the Claude Code OAuth path,
  and must surface actionable error messages for each failure mode.
  """
  use ExUnit.Case, async: true

  alias Tau.Providers.Anthropic.Auth

  @future_ms_offset 60 * 60 * 1000
  @past_ms_offset -60 * 1000

  setup do
    # Per-test temp directory for the credentials fixture.
    tmp = Path.join(System.tmp_dir!(), "tau-auth-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

  defp write_oauth(path, overrides) do
    base = %{
      "claudeAiOauth" => Map.merge(
        %{
          "accessToken" => "sk-ant-oat01-test-token",
          "refreshToken" => "sk-ant-ort01-test-refresh",
          "expiresAt" => :os.system_time(:millisecond) + @future_ms_offset,
          "scopes" => ["user:inference", "user:profile"],
          "subscriptionType" => "max",
          "rateLimitTier" => "default"
        },
        overrides
      )
    }

    File.write!(path, Jason.encode!(base))
    path
  end

  describe "API-key path (D-017)" do
    test "resolves explicit :api_key opt to {:api_key, key}" do
      assert {:ok, {:api_key, "sk-ant-api03-explicit"}} =
               Auth.resolve(%{api_key: "sk-ant-api03-explicit"})
    end

    test "resolves Application.get_env api_key" do
      Application.put_env(:tau, Tau.Providers.Anthropic, api_key: "sk-ant-api03-from-app-env")

      on_exit(fn ->
        Application.delete_env(:tau, Tau.Providers.Anthropic)
      end)

      assert {:ok, {:api_key, "sk-ant-api03-from-app-env"}} = Auth.resolve(%{})
    end

    test "API key takes precedence over OAuth file when both are set", %{tmp: tmp} do
      path = write_oauth(Path.join(tmp, "creds.json"), %{})

      assert {:ok, {:api_key, "sk-ant-api03-wins"}} =
               Auth.resolve(%{api_key: "sk-ant-api03-wins", credentials_path: path})
    end
  end

  describe "OAuth path (D-017)" do
    test "resolves valid OAuth file to {:oauth, ...}", %{tmp: tmp} do
      path = write_oauth(Path.join(tmp, "creds.json"), %{})

      assert {:ok, {:oauth, info}} = Auth.resolve(%{credentials_path: path})

      assert info.access_token == "sk-ant-oat01-test-token"
      assert is_integer(info.expires_at) and info.expires_at > :os.system_time(:millisecond)
      assert "user:inference" in info.scopes
      assert info.subscription_type == "max"
    end

    test "missing credentials file returns :no_auth", %{tmp: tmp} do
      path = Path.join(tmp, "missing.json")
      assert {:error, :no_auth} = Auth.resolve(%{credentials_path: path})
    end

    test "expired OAuth token returns :oauth_expired", %{tmp: tmp} do
      now_ms = :os.system_time(:millisecond)
      path = write_oauth(Path.join(tmp, "creds.json"), %{"expiresAt" => now_ms + @past_ms_offset})

      assert {:error, :oauth_expired} = Auth.resolve(%{credentials_path: path})
    end

    test "OAuth missing user:inference scope returns :oauth_missing_scope", %{tmp: tmp} do
      path = write_oauth(Path.join(tmp, "creds.json"), %{"scopes" => ["user:profile"]})

      assert {:error, :oauth_missing_scope} = Auth.resolve(%{credentials_path: path})
    end

    test "malformed JSON returns :oauth_malformed", %{tmp: tmp} do
      path = Path.join(tmp, "creds.json")
      File.write!(path, "{ this is not json")

      assert {:error, :oauth_malformed} = Auth.resolve(%{credentials_path: path})
    end

    test "missing claudeAiOauth key returns :oauth_malformed", %{tmp: tmp} do
      path = Path.join(tmp, "creds.json")
      File.write!(path, Jason.encode!(%{"someOtherKey" => "value"}))

      assert {:error, :oauth_malformed} = Auth.resolve(%{credentials_path: path})
    end

    test "missing required field returns :oauth_malformed", %{tmp: tmp} do
      path = Path.join(tmp, "creds.json")
      File.write!(path, Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "t"}}))

      assert {:error, :oauth_malformed} = Auth.resolve(%{credentials_path: path})
    end
  end

  describe "describe_error/1 (D-018: actionable messages)" do
    test ":no_auth mentions both API key env var and Claude /login" do
      msg = Auth.describe_error({:error, :no_auth})
      assert msg =~ "ANTHROPIC_API_KEY"
      assert msg =~ "claude /login"
    end

    test ":oauth_expired mentions claude /login" do
      msg = Auth.describe_error({:error, :oauth_expired})
      assert msg =~ "expired"
      assert msg =~ "claude /login"
    end

    test ":oauth_missing_scope names user:inference" do
      msg = Auth.describe_error({:error, :oauth_missing_scope})
      assert msg =~ "user:inference"
      assert msg =~ "claude /login"
    end

    test ":oauth_malformed mentions both renewal paths" do
      msg = Auth.describe_error({:error, :oauth_malformed})
      assert msg =~ "credentials.json"
      assert msg =~ "claude /login"
    end
  end
end

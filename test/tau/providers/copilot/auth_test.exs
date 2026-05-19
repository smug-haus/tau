defmodule Tau.Providers.Copilot.AuthTest do
  @moduledoc """
  D-056 / C82-B8 (SPEC-USER-TURN §3 Q3): The Copilot auth subsystem
  must resolve the long-lived OAuth token from hosts.json / apps.json /
  env vars, refresh the short-lived API token via the Copilot internal
  endpoint, and surface actionable errors for each failure mode.

  Uses Bypass to stub the GitHub token endpoint; no real network calls.
  """
  use ExUnit.Case, async: false

  alias Tau.Providers.Copilot.Auth
  alias Tau.Providers.Copilot.TokenStore

  # Future expiry far enough ahead to avoid a false "nearing expiry" refresh.
  @future_ms 30 * 60 * 1000
  # Expiry just under the 5-minute refresh threshold.
  @near_expiry_ms 4 * 60 * 1000

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-copilot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}/copilot_internal/v2/token"

    %{tmp: tmp, bypass: bypass, base_url: base_url}
  end

  # ---------------------------------------------------------------------------
  # hosts.json / apps.json parsing
  # ---------------------------------------------------------------------------

  describe "resolve_oauth/1 — hosts.json" do
    test "extracts oauth_token from github.com entry", %{tmp: tmp} do
      path = write_hosts_json(tmp, "github.com", "gho_test_oauth_token")
      assert {:ok, "gho_test_oauth_token"} = Auth.resolve_oauth(%{hosts_json_path: path})
    end

    test "extracts oauth_token when key contains github.com (e.g. github.com:Copilot)", %{
      tmp: tmp
    } do
      path = write_keyed_hosts_json(tmp, "github.com:Copilot", "gho_apps_token")
      assert {:ok, "gho_apps_token"} = Auth.resolve_oauth(%{hosts_json_path: path})
    end

    test "missing hosts.json falls through to apps.json", %{tmp: tmp} do
      missing_hosts = Path.join(tmp, "missing_hosts.json")
      apps_path = write_hosts_json(tmp, "github.com", "gho_apps_fallback", "apps.json")

      assert {:ok, "gho_apps_fallback"} =
               Auth.resolve_oauth(%{
                 hosts_json_path: missing_hosts,
                 apps_json_path: apps_path
               })
    end

    test "both files missing returns :no_auth", %{tmp: tmp} do
      missing_hosts = Path.join(tmp, "missing_hosts.json")
      missing_apps = Path.join(tmp, "missing_apps.json")

      assert {:error, :no_auth} =
               Auth.resolve_oauth(%{
                 hosts_json_path: missing_hosts,
                 apps_json_path: missing_apps
               })
    end

    test "malformed JSON returns :oauth_malformed", %{tmp: tmp} do
      path = Path.join(tmp, "hosts.json")
      File.write!(path, "not json {")
      missing_apps = Path.join(tmp, "missing_apps.json")

      assert {:error, :oauth_malformed} =
               Auth.resolve_oauth(%{hosts_json_path: path, apps_json_path: missing_apps})
    end

    test "no github.com key in hosts.json returns :no_auth", %{tmp: tmp} do
      path = Path.join(tmp, "hosts.json")
      File.write!(path, Jason.encode!(%{"bitbucket.org" => %{"oauth_token" => "xyz"}}))
      missing_apps = Path.join(tmp, "missing_apps.json")

      assert {:error, :no_auth} =
               Auth.resolve_oauth(%{hosts_json_path: path, apps_json_path: missing_apps})
    end
  end

  describe "resolve_oauth/1 — env var override" do
    test "COPILOT_TOKEN takes precedence over file", %{tmp: tmp} do
      path = write_hosts_json(tmp, "github.com", "gho_from_file")

      System.put_env("COPILOT_TOKEN", "env_token_wins")
      on_exit(fn -> System.delete_env("COPILOT_TOKEN") end)

      assert {:ok, "env_token_wins"} = Auth.resolve_oauth(%{hosts_json_path: path})
    end

    test "GITHUB_COPILOT_TOKEN is accepted as alias", %{tmp: tmp} do
      missing = Path.join(tmp, "missing.json")

      System.put_env("GITHUB_COPILOT_TOKEN", "alias_token")
      on_exit(fn -> System.delete_env("GITHUB_COPILOT_TOKEN") end)

      assert {:ok, "alias_token"} =
               Auth.resolve_oauth(%{
                 hosts_json_path: missing,
                 apps_json_path: missing
               })
    end

    test "COPILOT_TOKEN beats GITHUB_COPILOT_TOKEN" do
      System.put_env("COPILOT_TOKEN", "primary")
      System.put_env("GITHUB_COPILOT_TOKEN", "alias")

      on_exit(fn ->
        System.delete_env("COPILOT_TOKEN")
        System.delete_env("GITHUB_COPILOT_TOKEN")
      end)

      assert {:ok, "primary"} = Auth.resolve_oauth(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # refresh/2 — Bypass-stubbed GitHub token endpoint
  # ---------------------------------------------------------------------------

  describe "refresh/2" do
    test "200 response with ISO-8601 expires_at returns api token info", %{
      bypass: bypass,
      base_url: base_url
    } do
      expires_str = DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.to_iso8601()

      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "token" => "tid_abc123",
            "expires_at" => expires_str
          })
        )
      end)

      assert {:ok, %{token: "tid_abc123", expires_at: exp}} =
               Auth.refresh("gho_oauth", %{base_url: base_url})

      assert is_integer(exp) and exp > :os.system_time(:millisecond)
    end

    test "200 response with integer Unix epoch expires_at returns api token info", %{
      bypass: bypass,
      base_url: base_url
    } do
      # Some Copilot API versions return expires_at as a Unix epoch integer (seconds).
      expires_epoch_s = System.system_time(:second) + 1800

      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "token" => "tid_epoch",
            "expires_at" => expires_epoch_s
          })
        )
      end)

      assert {:ok, %{token: "tid_epoch", expires_at: exp}} =
               Auth.refresh("gho_oauth", %{base_url: base_url})

      # expires_at should be converted to milliseconds
      assert is_integer(exp) and exp > :os.system_time(:millisecond)
      assert_in_delta exp, expires_epoch_s * 1000, 1000
    end

    test "401 response returns :oauth_expired", %{bypass: bypass, base_url: base_url} do
      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        Plug.Conn.send_resp(conn, 401, ~s({"message":"Bad credentials"}))
      end)

      assert {:error, :oauth_expired} =
               Auth.refresh("expired_oauth_token", %{base_url: base_url})
    end

    test "non-200/non-401 response returns :oauth_refresh_failed", %{
      bypass: bypass,
      base_url: base_url
    } do
      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        Plug.Conn.send_resp(conn, 503, "Service Unavailable")
      end)

      assert {:error, :oauth_refresh_failed} =
               Auth.refresh("gho_oauth", %{base_url: base_url})
    end

    test "network error returns :oauth_refresh_failed" do
      # Point at a port with nothing listening
      dead_url = "http://localhost:1/copilot_internal/v2/token"

      assert {:error, :oauth_refresh_failed} =
               Auth.refresh("gho_oauth", %{base_url: dead_url})
    end
  end

  # ---------------------------------------------------------------------------
  # token/1 — proactive refresh logic via serialized TokenStore
  # ---------------------------------------------------------------------------

  describe "token/1 — token store interaction" do
    setup do
      # Start an isolated TokenStore per test under a unique registered name.
      # Auth.token/1 accepts opts[:token_store] as the registered atom name.
      name = :"token_store_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(TokenStore, :empty, name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{store_name: name}
    end

    test "returns cached token when fresh (no refresh)", %{
      store_name: name,
      bypass: bypass,
      base_url: base_url
    } do
      future_exp = :os.system_time(:millisecond) + @future_ms
      GenServer.call(name, {:put, %{token: "cached_tid", expires_at: future_exp}})

      # Bypass should NOT be called for a fresh token.
      Bypass.stub(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        flunk("refresh should NOT be called for a fresh token")
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, "cached_tid"} =
               Auth.token(%{token_store: name, base_url: base_url})
    end

    test "refreshes when token is nearing expiry", %{
      store_name: name,
      bypass: bypass,
      base_url: base_url,
      tmp: tmp
    } do
      near_exp = :os.system_time(:millisecond) + @near_expiry_ms
      GenServer.call(name, {:put, %{token: "old_tid", expires_at: near_exp}})

      new_exp_str =
        DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.to_iso8601()

      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"token" => "new_tid", "expires_at" => new_exp_str})
        )
      end)

      hosts_path = write_hosts_json(tmp, "github.com", "gho_oauth")

      assert {:ok, "new_tid"} =
               Auth.token(%{
                 token_store: name,
                 base_url: base_url,
                 hosts_json_path: hosts_path
               })
    end

    test "refreshes when store is empty", %{
      store_name: name,
      bypass: bypass,
      base_url: base_url,
      tmp: tmp
    } do
      new_exp_str =
        DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.to_iso8601()

      Bypass.expect_once(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"token" => "fresh_tid", "expires_at" => new_exp_str})
        )
      end)

      hosts_path = write_hosts_json(tmp, "github.com", "gho_oauth")

      assert {:ok, "fresh_tid"} =
               Auth.token(%{
                 token_store: name,
                 base_url: base_url,
                 hosts_json_path: hosts_path
               })
    end

    # F1: thundering-herd — N concurrent callers against a cold store must
    # hit the token endpoint EXACTLY ONCE.
    test "concurrent callers against cold store hit endpoint exactly once", %{
      store_name: name,
      bypass: bypass,
      base_url: base_url,
      tmp: tmp
    } do
      # Use an Agent to count endpoint hits in a race-safe manner.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      new_exp_str =
        DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.to_iso8601()

      # Bypass stub: count every hit and introduce a small delay to allow
      # concurrent callers to pile up behind the first in-flight refresh.
      Bypass.stub(bypass, "POST", "/copilot_internal/v2/token", fn conn ->
        Agent.update(counter, &(&1 + 1))
        # Small sleep to widen the race window
        Process.sleep(50)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"token" => "shared_tid", "expires_at" => new_exp_str})
        )
      end)

      hosts_path = write_hosts_json(tmp, "github.com", "gho_oauth")
      opts = %{token_store: name, base_url: base_url, hosts_json_path: hosts_path}
      n = 10

      results =
        1..n
        |> Enum.map(fn _ ->
          Task.async(fn -> Auth.token(opts) end)
        end)
        |> Task.await_many(10_000)

      # All callers must succeed and receive the same token
      assert Enum.all?(results, fn r -> r == {:ok, "shared_tid"} end),
             "Expected all #{n} callers to receive {:ok, 'shared_tid'}, got: #{inspect(results)}"

      # The endpoint must have been hit EXACTLY ONCE — the store serialized the refresh
      hit_count = Agent.get(counter, & &1)
      assert hit_count == 1, "Expected token endpoint hit exactly 1 time, got #{hit_count}"
    end
  end

  # ---------------------------------------------------------------------------
  # TokenStore.clear/0 — auth reset path (F4)
  # ---------------------------------------------------------------------------

  describe "TokenStore.clear/1" do
    setup do
      name = :"token_store_clear_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(TokenStore, :empty, name: name)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{store_name: name}
    end

    test "clear/1 resets populated store to :empty", %{store_name: name} do
      future_exp = :os.system_time(:millisecond) + @future_ms
      TokenStore.put(%{token: "some_tid", expires_at: future_exp}, name)
      assert {:ok, _} = TokenStore.get(name)

      assert :ok = TokenStore.clear(name)
      assert :empty = TokenStore.get(name)
    end

    test "clear/1 on already-empty store returns :ok", %{store_name: name} do
      assert :empty = TokenStore.get(name)
      assert :ok = TokenStore.clear(name)
      assert :empty = TokenStore.get(name)
    end
  end

  # ---------------------------------------------------------------------------
  # Error messages (D-056: actionable)
  # ---------------------------------------------------------------------------

  describe "describe_error/1" do
    test ":no_auth mentions both env var and gh auth login" do
      msg = Auth.describe_error({:error, :no_auth})
      assert msg =~ "COPILOT_TOKEN"
      assert msg =~ "gh auth login"
    end

    test ":oauth_expired mentions gh auth login" do
      msg = Auth.describe_error({:error, :oauth_expired})
      assert msg =~ "expired"
      assert msg =~ "gh auth login"
    end

    test ":oauth_refresh_failed mentions network and gh auth login" do
      msg = Auth.describe_error({:error, :oauth_refresh_failed})
      assert msg =~ "refresh failed"
      assert msg =~ "gh auth login"
    end

    test ":oauth_malformed mentions hosts.json and env var" do
      msg = Auth.describe_error({:error, :oauth_malformed})
      assert msg =~ "hosts.json"
      assert msg =~ "COPILOT_TOKEN"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_hosts_json(tmp, host_key, token, filename \\ "hosts.json") do
    path = Path.join(tmp, filename)

    File.write!(
      path,
      Jason.encode!(%{
        host_key => %{
          "oauth_token" => token,
          "user" => "testuser"
        }
      })
    )

    path
  end

  defp write_keyed_hosts_json(tmp, key, token) do
    path = Path.join(tmp, "hosts.json")

    File.write!(
      path,
      Jason.encode!(%{
        key => %{"oauth_token" => token}
      })
    )

    path
  end
end

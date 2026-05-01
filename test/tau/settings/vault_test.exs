defmodule Tau.Settings.VaultTest do
  @moduledoc """
  Tests for the dispatcher in `Tau.Settings.Vault`.

  Live macOS Keychain and Linux libsecret round-trips are tagged
  `:skip` — they require a real keychain and CI does not have one.
  Manual smoke test plan: see PR #66 description.
  """
  use ExUnit.Case, async: false

  alias Tau.Settings.Vault

  describe "resolve_backend/1" do
    test ":env resolves to the Env passthrough" do
      assert Vault.resolve_backend(:env) == Vault.Env
    end

    test ":keychain_mac, :keychain_linux, :keychain_windows resolve to backends" do
      assert Vault.resolve_backend(:keychain_mac) == Vault.Keychain.Mac
      assert Vault.resolve_backend(:keychain_linux) == Vault.Keychain.Linux
      assert Vault.resolve_backend(:keychain_windows) == Vault.Keychain.Windows
    end

    test ":auto picks based on :os.type/0" do
      expected =
        case :os.type() do
          {:unix, :darwin} -> Vault.Keychain.Mac
          {:unix, _} -> Vault.Keychain.Linux
          {:win32, _} -> Vault.Keychain.Windows
          _ -> Vault.Env
        end

      assert Vault.resolve_backend(:auto) == expected
    end

    test "unknown values fall back to Env (fail-soft on the default)" do
      assert Vault.resolve_backend(:bogus) == Vault.Env
      assert Vault.resolve_backend(nil) == Vault.Env
      assert Vault.resolve_backend("not_a_real_backend") == Vault.Env
    end

    test "string values resolve to their atom equivalents" do
      assert Vault.resolve_backend("env") == Vault.Env
      assert Vault.resolve_backend("keychain_mac") == Vault.Keychain.Mac
      assert Vault.resolve_backend("keychain_linux") == Vault.Keychain.Linux
      assert Vault.resolve_backend("keychain_windows") == Vault.Keychain.Windows
    end
  end

  describe "backend/0 (cache-driven)" do
    setup do
      original = :persistent_term.get({Tau, :settings}, %{})
      on_exit(fn -> :persistent_term.put({Tau, :settings}, original) end)
      :ok
    end

    test "defaults to Env when no vault block is set" do
      :persistent_term.put({Tau, :settings}, %{})
      assert Vault.backend() == Vault.Env
    end

    test "honours `vault.backend` (atom key)" do
      :persistent_term.put({Tau, :settings}, %{vault: %{backend: :keychain_mac}})
      assert Vault.backend() == Vault.Keychain.Mac
    end

    test "honours `vault.backend` (string key)" do
      :persistent_term.put({Tau, :settings}, %{vault: %{"backend" => "keychain_linux"}})
      assert Vault.backend() == Vault.Keychain.Linux
    end

    test ":auto in the cache picks based on :os.type/0" do
      :persistent_term.put({Tau, :settings}, %{vault: %{backend: :auto}})

      expected =
        case :os.type() do
          {:unix, :darwin} -> Vault.Keychain.Mac
          {:unix, _} -> Vault.Keychain.Linux
          {:win32, _} -> Vault.Keychain.Windows
          _ -> Vault.Env
        end

      assert Vault.backend() == expected
    end
  end

  describe "resolve/1" do
    setup do
      var = "TAU_VAULT_RESOLVE_TEST"
      System.put_env(var, "resolved-value")
      original = :persistent_term.get({Tau, :settings}, %{})
      :persistent_term.put({Tau, :settings}, %{vault: %{backend: :env}})

      on_exit(fn ->
        System.delete_env(var)
        :persistent_term.put({Tau, :settings}, original)
      end)

      {:ok, var: var}
    end

    test "passes through literal strings unchanged" do
      assert Vault.resolve("literal-key") == "literal-key"
    end

    test "resolves {:vault, name} via the configured backend", %{var: var} do
      assert Vault.resolve({:vault, var}) == "resolved-value"
    end

    test "resolves %{vault: name} (settings-file shape)", %{var: var} do
      assert Vault.resolve(%{vault: var}) == "resolved-value"
    end

    test "resolves %{\"vault\" => name} (string-keyed fixture)", %{var: var} do
      assert Vault.resolve(%{"vault" => var}) == "resolved-value"
    end

    test "returns nil on miss" do
      assert Vault.resolve({:vault, "DEFINITELY_NOT_SET_TAU_VAULT_TEST"}) == nil
    end

    test "returns nil for nil input" do
      assert Vault.resolve(nil) == nil
    end
  end

  describe "telemetry" do
    setup do
      original = :persistent_term.get({Tau, :settings}, %{})
      :persistent_term.put({Tau, :settings}, %{vault: %{backend: :env}})

      handler_id = "test-handler-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:tau, :vault, :get],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
        :persistent_term.put({Tau, :settings}, original)
      end)

      :ok
    end

    test "fires [:tau, :vault, :get] without the credential value" do
      var = "TAU_VAULT_TELEMETRY_TEST"
      System.put_env(var, "super-secret")
      on_exit(fn -> System.delete_env(var) end)

      Vault.get(var)

      assert_receive {:telemetry, _measurements, metadata}, 500

      assert metadata.backend == Vault.Env
      assert metadata.result == :ok
      assert is_binary(metadata.name_hash)
      # 12-char truncated lowercase hex.
      assert byte_size(metadata.name_hash) == 12
      # Crucially: nothing in metadata is the cleartext value.
      refute Enum.any?(Map.values(metadata), &(&1 == "super-secret"))
    end

    test "result :not_found on a missing var" do
      Vault.get("DEFINITELY_NOT_SET_TAU_VAULT_TEST")

      assert_receive {:telemetry, _measurements, metadata}, 500
      assert metadata.result == :not_found
    end
  end

  describe "live keychain backends" do
    @describetag :skip

    test "macOS Keychain round-trip" do
      # Manual smoke test: enable on a developer's macOS box.
      # Tagged :skip — CI has no keychain session.
      _ = Vault.Keychain.Mac.put("tau_test_key", "secret")
      assert {:ok, "secret"} = Vault.Keychain.Mac.get("tau_test_key")
    end

    test "Linux libsecret round-trip" do
      # Manual smoke test: requires a running secret-service backend
      # (gnome-keyring-daemon, kwalletd-libsecret, etc.).
      _ = Vault.Keychain.Linux.put("tau_test_key", "secret")
      assert {:ok, "secret"} = Vault.Keychain.Linux.get("tau_test_key")
    end
  end

  describe "Windows backend" do
    test "stub returns :not_implemented for all operations" do
      assert {:error, :not_implemented} = Vault.Keychain.Windows.get("anything")
      assert {:error, :not_implemented} = Vault.Keychain.Windows.put("anything", "value")
      assert {:error, :not_implemented} = Vault.Keychain.Windows.list()
    end
  end
end

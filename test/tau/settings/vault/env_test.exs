defmodule Tau.Settings.Vault.EnvTest do
  @moduledoc """
  Round-trip + miss tests for the default `Env` backend.

  No real OS keychain is exercised here — `Env` is the v1 default
  and the headless / CI fallback (ADR-0016). Live keychain backends
  are tagged `:skip` in the parent `vault_test.exs` because CI does
  not have a Keychain / libsecret session.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Tau.Settings.Vault.Env

  @var "TAU_VAULT_ENV_TEST"

  setup do
    on_exit(fn -> System.delete_env(@var) end)
    :ok
  end

  describe "get/1" do
    test "round-trips a value set via System.put_env" do
      System.put_env(@var, "secret-1234")
      assert {:ok, "secret-1234"} = Env.get(@var)
    end

    test "returns :not_found when the variable is unset" do
      System.delete_env(@var)
      assert {:error, :not_found} = Env.get(@var)
    end

    test "treats an empty-string env var as :not_found" do
      System.put_env(@var, "")
      assert {:error, :not_found} = Env.get(@var)
    end
  end

  describe "put/2" do
    test "is read-only — Env does not write back to the process env" do
      assert {:error, :read_only} = Env.put(@var, "anything")
      assert System.get_env(@var) == nil
    end
  end

  describe "list/0" do
    test "is :not_supported — refuse to enumerate the process env" do
      assert {:error, :not_supported} = Env.list()
    end
  end

  describe "property: any non-empty string round-trips through Env" do
    @describetag :property

    property "set then get yields the same value" do
      check all(value <- StreamData.string(:printable, min_length: 1, max_length: 64)) do
        System.put_env(@var, value)
        assert {:ok, ^value} = Env.get(@var)
      end
    end
  end
end

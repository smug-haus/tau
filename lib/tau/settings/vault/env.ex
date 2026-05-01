defmodule Tau.Settings.Vault.Env do
  @moduledoc """
  Default vault backend: passthrough to OS environment variables.

  This is the v1 default and the headless / CI fallback. It implements
  the `Tau.Settings.Vault` behaviour in the most boring way possible —
  `get/1` is `System.get_env/1`, `put/2` is `{:error, :read_only}`,
  `list/0` returns `{:error, :not_supported}` because enumerating the
  full process env to find credentials would leak unrelated names
  into telemetry.

  The Env backend exists explicitly so that anyone running Tau today
  with `ANTHROPIC_API_KEY` exported keeps working with zero config
  change after this PR. Encryption-at-rest is opt-in (set
  `vault.backend` in settings); see ADR-0016.
  """

  @behaviour Tau.Settings.Vault

  @impl true
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    case System.get_env(name) do
      nil -> {:error, :not_found}
      "" -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  @spec put(String.t(), String.t()) :: {:error, :read_only}
  def put(_name, _value), do: {:error, :read_only}

  @impl true
  @spec list() :: {:error, :not_supported}
  def list, do: {:error, :not_supported}
end

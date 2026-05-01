defmodule Tau.Settings.Vault.Keychain.Windows do
  @moduledoc """
  Windows DPAPI backend for `Tau.Settings.Vault`.

  **Stubbed.** DPAPI exposes its API through `Crypt32.dll` and the
  Credential Manager UI; calling either cleanly from BEAM requires
  a NIF (or a long detour via `powershell.exe -Command
  ConvertFrom-SecureString`, which round-trips a base64 SecureString
  representation through stdout — viable but with caveats around
  user-context and machine-vs-user scope).

  We ship the stub so the dispatcher resolution is symmetric across
  platforms; a real implementation lands in a follow-up. Until then
  every operation returns `{:error, :not_implemented}`. Users on
  Windows should keep the default `Env` backend.

  See ADR-0016 and the follow-up issue tracking the real DPAPI
  implementation.
  """

  @behaviour Tau.Settings.Vault

  @impl true
  @spec get(String.t()) :: {:error, :not_implemented}
  def get(_name), do: {:error, :not_implemented}

  @impl true
  @spec put(String.t(), String.t()) :: {:error, :not_implemented}
  def put(_name, _value), do: {:error, :not_implemented}

  @impl true
  @spec list() :: {:error, :not_implemented}
  def list, do: {:error, :not_implemented}
end

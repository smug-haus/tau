defmodule Tau.Settings.Vault do
  @moduledoc """
  Credential vault behaviour and dispatcher.

  Tau delegates credential custody to the operating system rather
  than owning long-lived ciphertext. See ADR-0016 for the rationale.

  ## Behaviour

  Implementations provide four callbacks:

      @callback get(name :: String.t()) :: {:ok, String.t()} | {:error, term()}
      @callback put(name :: String.t(), value :: String.t()) :: :ok | {:error, term()}
      @callback delete(name :: String.t()) :: :ok | {:error, term()}
      @callback list() :: {:ok, [String.t()]} | {:error, term()}

  The four shipped backends live under `Tau.Settings.Vault`:

    * `Tau.Settings.Vault.Env` — passthrough to `System.get_env/1`.
      The default; preserves today's headless / CI behaviour.
    * `Tau.Settings.Vault.Keychain.Mac` — macOS Security framework
      via `/usr/bin/security`.
    * `Tau.Settings.Vault.Keychain.Linux` — freedesktop libsecret
      via `secret-tool`.
    * `Tau.Settings.Vault.Keychain.Windows` — DPAPI (stubbed,
      tracked as a follow-up — see issue #66).

  ## Configuration

  Configuration flows through `Tau.Settings.Cache` (per ADR-0002,
  not `Application.get_env/2`):

      # .tau/settings.json
      {
        "vault": { "backend": "auto" }
      }

  Backend values: `:env | :keychain_mac | :keychain_linux |
  :keychain_windows | :auto`. The `:auto` resolver picks based on
  `:os.type/0` and falls through to `:env` for unrecognised
  platforms — and crucially, headless / CI runs that haven't set
  `vault.backend` keep the unchanged Env passthrough.

  ## Resolver

  Settings files reference credentials by name, not by literal
  value:

      %{api_key: {:vault, "anthropic_api_key"}}

  `resolve/1` takes either a literal string or a `{:vault, name}`
  tuple and returns the resolved string (or `nil` on miss). Provider
  modules call this in their key-read path instead of
  `System.get_env/1`.

  ## Telemetry

  `[:tau, :vault, :get]` fires for every dispatch with metadata
  `%{backend: atom, result: :ok | :not_found | :error,
    name_hash: <truncated sha256>}`. **The credential value is
  never in metadata, logs, or error tuples.**
  """

  @callback get(name :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback put(name :: String.t(), value :: String.t()) :: :ok | {:error, term()}
  @callback delete(name :: String.t()) :: :ok | {:error, term()}
  @callback list() :: {:ok, [String.t()]} | {:error, term()}

  @type backend ::
          :env | :keychain_mac | :keychain_linux | :keychain_windows | :auto

  @doc """
  Return the configured backend module. Reads
  `settings[:vault][:backend]` from `Tau.Settings.Cache`. Defaults
  to `:env`. Accepts atom or string values; unknown values fall
  back to `:env` (fail soft on the default; misconfiguration must
  not lose creds).
  """
  @spec backend() :: module()
  def backend do
    settings = safe_settings()

    settings
    |> Map.get(:vault, %{})
    |> case do
      %{} = m -> Map.get(m, :backend) || Map.get(m, "backend")
      _ -> nil
    end
    |> resolve_backend()
  end

  @doc "Resolve a backend atom (or string) to its implementation module."
  @spec resolve_backend(any()) :: module()
  def resolve_backend(:env), do: __MODULE__.Env
  def resolve_backend(:keychain_mac), do: __MODULE__.Keychain.Mac
  def resolve_backend(:keychain_linux), do: __MODULE__.Keychain.Linux
  def resolve_backend(:keychain_windows), do: __MODULE__.Keychain.Windows

  def resolve_backend(:auto) do
    case :os.type() do
      {:unix, :darwin} -> __MODULE__.Keychain.Mac
      {:unix, _} -> __MODULE__.Keychain.Linux
      {:win32, _} -> __MODULE__.Keychain.Windows
      _ -> __MODULE__.Env
    end
  end

  def resolve_backend(s) when is_binary(s) do
    case s do
      "env" -> resolve_backend(:env)
      "keychain_mac" -> resolve_backend(:keychain_mac)
      "keychain_linux" -> resolve_backend(:keychain_linux)
      "keychain_windows" -> resolve_backend(:keychain_windows)
      "auto" -> resolve_backend(:auto)
      _ -> __MODULE__.Env
    end
  end

  def resolve_backend(_), do: __MODULE__.Env

  @doc """
  Look up a credential by name through the configured backend.

  Emits `[:tau, :vault, :get]` telemetry with the backend, result
  classification, and a truncated SHA-256 hash of the name. The
  value never appears in metadata or logs.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(name) when is_binary(name) do
    mod = backend()
    result = mod.get(name)
    emit_telemetry(:get, mod, name, classify(result))
    result
  end

  @doc "Store a credential by name through the configured backend."
  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(name, value) when is_binary(name) and is_binary(value) do
    backend().put(name, value)
  end

  @doc "Delete a credential by name through the configured backend."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    backend().delete(name)
  end

  @doc "List the credential names known to the configured backend."
  @spec list() :: {:ok, [String.t()]} | {:error, term()}
  def list, do: backend().list()

  @doc """
  Resolve a settings field that may be a literal string or a
  `{:vault, name}` reference. Returns the resolved string, or
  `nil` on miss / error.

  Accepts both atom and string keys for tolerance with hand-built
  test fixtures (`{:vault, "x"}` and `%{"vault" => "x"}`).
  """
  @spec resolve(nil | String.t() | {:vault, String.t()} | %{optional(any) => any}) ::
          nil | String.t()
  def resolve(nil), do: nil
  def resolve(value) when is_binary(value), do: value

  def resolve({:vault, name}) when is_binary(name) do
    case get(name) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  def resolve(%{vault: name}) when is_binary(name), do: resolve({:vault, name})
  def resolve(%{"vault" => name}) when is_binary(name), do: resolve({:vault, name})
  def resolve(_), do: nil

  # --- private --------------------------------------------------------------

  defp safe_settings do
    # `Tau.Settings.Cache` is supervised; if it's not up (e.g. unit
    # tests that don't start the application), fall through to `%{}`
    # and let the Env default handle it. Never crash a credential
    # lookup on a missing cache.
    if Process.whereis(Tau.Settings.Cache) do
      Tau.Settings.Cache.get()
    else
      %{}
    end
  end

  defp classify({:ok, _}), do: :ok
  defp classify({:error, :not_found}), do: :not_found
  defp classify(nil), do: :not_found
  defp classify({:error, _}), do: :error
  defp classify(_), do: :error

  defp emit_telemetry(event, backend_mod, name, result) do
    :telemetry.execute(
      [:tau, :vault, event],
      %{system_time: System.system_time()},
      %{
        backend: backend_mod,
        result: result,
        name_hash: hash_name(name)
      }
    )
  end

  # Truncated SHA-256 — enough to correlate two events for the same
  # name without being reversible to anything useful in logs.
  defp hash_name(name) do
    :crypto.hash(:sha256, name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end

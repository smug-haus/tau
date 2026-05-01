defmodule Tau.Settings.Vault.Keychain.Mac do
  @moduledoc """
  macOS Keychain backend for `Tau.Settings.Vault`.

  Shells out to `/usr/bin/security` (Apple-shipped, signed). Service
  name `"tau"`, account = the credential `name`. No NIF; no extra
  dependency. See ADR-0016 for why we shell out instead of binding
  Security.framework directly.

  Operations:

    * `get/1` → `security find-generic-password -s tau -a <name> -w`.
      The `-w` flag prints only the password to stdout (no metadata).
    * `put/2` → `security add-generic-password -U -s tau -a <name>
      -w <value>`. The `-U` flag updates an existing entry instead
      of failing with `errSecDuplicateItem`.
    * `list/0` → `security dump-keychain | grep` would leak unrelated
      entries; we'd need richer parsing. Returns
      `{:error, :not_supported}` for now — wire when needed.

  ## A note on argv exposure

  `security add-generic-password -w <value>` puts the credential
  on the command line, so it appears in `ps` for the lifetime of
  the call. macOS scrubs argv for `security` specifically (it
  zeroes the password slot in argv after read), but a determined
  observer with `dtrace` can still see it. This is the documented
  Apple pattern; the alternative is a tiny C helper that reads
  from stdin via `Security` APIs, which is a NIF and out of scope
  here. Reads use `find-generic-password -w` which never echoes
  the value to argv.
  """

  @behaviour Tau.Settings.Vault

  @security "/usr/bin/security"
  @service "tau"

  @impl true
  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(name) when is_binary(name) do
    if File.exists?(@security) do
      case System.cmd(@security, ["find-generic-password", "-s", @service, "-a", name, "-w"],
             stderr_to_stdout: false
           ) do
        {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
        {_, 44} -> {:error, :not_found}
        {_, 128} -> {:error, :not_found}
        {_, code} -> {:error, {:security_exit, code}}
      end
    else
      {:error, :security_unavailable}
    end
  end

  @impl true
  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(name, value) when is_binary(name) and is_binary(value) do
    if File.exists?(@security) do
      args = ["add-generic-password", "-U", "-s", @service, "-a", name, "-w", value]

      case System.cmd(@security, args, stderr_to_stdout: false) do
        {_, 0} -> :ok
        {_, code} -> {:error, {:security_exit, code}}
      end
    else
      {:error, :security_unavailable}
    end
  end

  @impl true
  @spec list() :: {:error, :not_supported}
  def list, do: {:error, :not_supported}
end

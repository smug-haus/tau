defmodule Tau.Settings.Vault.Keychain.Linux do
  @moduledoc """
  Linux libsecret backend for `Tau.Settings.Vault`.

  Shells out to `secret-tool` (from `libsecret-tools` /
  `libsecret-1-bin`), which talks to the freedesktop.org Secret
  Service over D-Bus. The user's session keyring backend (GNOME
  Keyring, KWallet via `kwalletd-libsecret`, etc.) handles
  storage; we never see plaintext beyond the read result.

  Operations:

    * `get/1` →
      `secret-tool lookup service tau account <name>`. Stdout is
      the password; non-zero exit means "not found" (libsecret
      doesn't distinguish missing-vs-error here, so we collapse
      to `:not_found`).
    * `put/2` → `secret-tool store --label <name> service tau
      account <name>`, with the value piped on stdin via
      `Port.command/2`. We do NOT use the `--password` flag (it
      would put the value on argv).
    * `list/0` returns `{:error, :not_supported}` — `secret-tool
      search` exists but is verbose and inconsistent across
      backends.

  ## Availability

  If `secret-tool` is not on `PATH` at the time the call is made,
  every operation returns `{:error, :secret_tool_unavailable}`.
  This is fail-loud on purpose: silently falling through to env
  on a host that *should* have a keychain would defeat the point
  of opting in.
  """

  @behaviour Tau.Settings.Vault

  @service "tau"

  @impl true
  @spec get(String.t()) :: {:ok, String.t()} | {:error, term()}
  def get(name) when is_binary(name) do
    case System.find_executable("secret-tool") do
      nil ->
        {:error, :secret_tool_unavailable}

      path ->
        case System.cmd(path, ["lookup", "service", @service, "account", name],
               stderr_to_stdout: false
             ) do
          {"", 0} -> {:error, :not_found}
          {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
          {_, _code} -> {:error, :not_found}
        end
    end
  end

  @impl true
  @spec put(String.t(), String.t()) :: :ok | {:error, term()}
  def put(name, value) when is_binary(name) and is_binary(value) do
    case System.find_executable("secret-tool") do
      nil ->
        {:error, :secret_tool_unavailable}

      path ->
        store_via_port(path, name, value)
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name) when is_binary(name) do
    case System.find_executable("secret-tool") do
      nil ->
        {:error, :secret_tool_unavailable}

      path ->
        case System.cmd(path, ["clear", "service", @service, "account", name],
               stderr_to_stdout: false,
               into: ""
             ) do
          {_, 0} -> :ok
          {_, _code} -> {:error, :not_found}
        end
    end
  end

  @impl true
  @spec list() :: {:error, :not_supported}
  def list, do: {:error, :not_supported}

  # secret-tool reads the password from stdin when invoked without
  # `--password`. Use a Port so the value never lands on argv.
  defp store_via_port(path, name, value) do
    args = ["store", "--label", name, "service", @service, "account", name]

    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        {:args, args}
      ])

    Port.command(port, value)
    Port.command(port, "\n")
    Port.close(port)
    wait_for_exit(port)
  end

  defp wait_for_exit(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, code}} -> {:error, {:secret_tool_exit, code}}
    after
      5_000 -> {:error, :secret_tool_timeout}
    end
  end
end

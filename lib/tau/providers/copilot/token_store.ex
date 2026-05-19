defmodule Tau.Providers.Copilot.TokenStore do
  @moduledoc """
  Supervised GenServer that holds the short-lived Copilot API token
  and its expiry timestamp.

  This is the single owner of the mutable token state (OTP non-negotiable
  #1). The store is intentionally minimal — it is NOT a cache with
  auto-refresh logic; that lives in `Tau.Providers.Copilot.Auth.token/1`.
  The store merely provides a named, supervised home for the token so
  it survives across calls within a session without a disk read each time.

  ## Interface

    * `get/0` — `{:ok, %{token: t, expires_at: ms}} | :empty`
    * `put/1` — store a new token info map; returns `:ok`
    * `clear/0` — reset to empty state; returns `:ok`
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :empty, name: name)
  end

  @doc "Retrieve the current token info, or `:empty` if none is stored."
  @spec get() :: {:ok, %{token: String.t(), expires_at: integer()}} | :empty
  def get, do: GenServer.call(__MODULE__, :get)

  @doc "Store a new `%{token: t, expires_at: epoch_ms}` map."
  @spec put(%{token: String.t(), expires_at: integer()}) :: :ok
  def put(info) when is_map(info), do: GenServer.call(__MODULE__, {:put, info})

  @doc "Clear the stored token (used in tests and on auth reset)."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:empty), do: {:ok, :empty}

  @impl true
  def handle_call(:get, _from, :empty), do: {:reply, :empty, :empty}
  def handle_call(:get, _from, info), do: {:reply, {:ok, info}, info}

  def handle_call({:put, info}, _from, _state), do: {:reply, :ok, info}

  def handle_call(:clear, _from, _state), do: {:reply, :ok, :empty}
end

defmodule Tau.Providers.Copilot.TokenStore do
  @moduledoc """
  Supervised GenServer that holds the short-lived Copilot API token
  and its expiry timestamp.

  This is the single owner of the mutable token state (OTP non-negotiable
  #1). The store serializes both the expiry check and the refresh action in
  one `handle_call`, which eliminates the thundering-herd race that would
  occur if callers each independently decided to refresh.

  ## Interface

    * `token/2` — primary entry point. Checks expiry; if a refresh is
      needed, calls the provided `refresh_fn` inline (serialized) before
      replying. Concurrent callers queue behind the single in-flight refresh.
    * `get/1` — retrieve the current token info, or `:empty`.
    * `put/2` — store a new token info map; returns `:ok`.
    * `clear/1` — reset to empty state; returns `:ok`.

  ## Thundering-herd guarantee

  `token/2` runs entirely inside `handle_call`. Because OTP serializes
  `handle_call` invocations for a single process, at most one refresh HTTP
  request can be in flight at a time per store instance. All concurrent
  callers that arrive while a refresh is running queue behind it and receive
  the already-refreshed token from the updated state.

  The Finch request inside `refresh_fn` carries a receive timeout (default
  30 s), so a hung GitHub endpoint cannot wedge the store forever; callers
  will time out on their `GenServer.call/3` if the store's `handle_call`
  does not return within the configured call timeout (default 5 s, raised
  to 35 s below to encompass the Finch timeout).
  """
  use GenServer

  # GenServer call timeout: must exceed the Finch receive timeout (30 s)
  # so the store can complete an in-flight refresh before callers time out.
  @call_timeout 35_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :empty, name: name)
  end

  @doc """
  Return the usable short-lived API token, refreshing if absent or nearing
  expiry.

  `refresh_fn` is a zero-arity function that returns
  `{:ok, %{token: t, expires_at: epoch_ms}} | {:error, term()}`.
  It is called **inside `handle_call`** — serialized within the store
  process — so only one refresh can be in flight at a time per store.

  `store_name` defaults to `__MODULE__`.

  Returns `{:ok, token_string} | {:error, term()}`.
  """
  @spec token((-> {:ok, map()} | {:error, term()}), atom()) ::
          {:ok, String.t()} | {:error, term()}
  def token(refresh_fn, store_name \\ __MODULE__) when is_function(refresh_fn, 0) do
    GenServer.call(store_name, {:token, refresh_fn}, @call_timeout)
  end

  @doc "Retrieve the current token info, or `:empty` if none is stored."
  @spec get(atom()) :: {:ok, %{token: String.t(), expires_at: integer()}} | :empty
  def get(store_name \\ __MODULE__), do: GenServer.call(store_name, :get)

  @doc "Store a new `%{token: t, expires_at: epoch_ms}` map."
  @spec put(%{token: String.t(), expires_at: integer()}, atom()) :: :ok
  def put(info, store_name \\ __MODULE__) when is_map(info),
    do: GenServer.call(store_name, {:put, info})

  @doc "Clear the stored token (used in tests and on auth reset)."
  @spec clear(atom()) :: :ok
  def clear(store_name \\ __MODULE__), do: GenServer.call(store_name, :clear)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:empty), do: {:ok, :empty}

  @impl true
  def handle_call({:token, refresh_fn}, _from, state) do
    case state do
      %{token: t, expires_at: exp} when is_binary(t) ->
        if needs_refresh?(exp) do
          do_refresh(refresh_fn, state)
        else
          {:reply, {:ok, t}, state}
        end

      _ ->
        do_refresh(refresh_fn, state)
    end
  end

  def handle_call(:get, _from, :empty), do: {:reply, :empty, :empty}
  def handle_call(:get, _from, info), do: {:reply, {:ok, info}, info}

  def handle_call({:put, info}, _from, _state), do: {:reply, :ok, info}

  def handle_call(:clear, _from, _state), do: {:reply, :ok, :empty}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # @refresh_threshold_ms: refresh when fewer than 5 minutes remain
  @refresh_threshold_ms 5 * 60 * 1000

  defp needs_refresh?(expires_at) do
    now_ms = :os.system_time(:millisecond)
    expires_at - now_ms < @refresh_threshold_ms
  end

  defp do_refresh(refresh_fn, _old_state) do
    case refresh_fn.() do
      {:ok, %{token: t} = info} when is_binary(t) ->
        {:reply, {:ok, t}, info}

      {:error, _} = err ->
        {:reply, err, :empty}
    end
  end
end

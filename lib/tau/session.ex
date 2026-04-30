defmodule Tau.Session do
  @moduledoc """
  The session is a `:gen_statem` (callback mode `:handle_event_function`).

  States (M2 scope; M0 stub here only declares them):

      :idle
      :awaiting_user
      :provider_streaming
      :tool_dispatch
      :tool_executing
      :hook_running
      :compacting
      :stopped

  Cross-cutting events (`:cancel`, `:settings_reloaded`, `:DOWN` from a tool
  task) are handled in `handle_event/4` regardless of state — that's why we
  picked `:handle_event_function` mode over `:state_functions`.

  M0 stub: API surface returns `{:error, :not_implemented}` so the public
  contract is testable and documented; the real state machine arrives in M2.
  """
  @behaviour :gen_statem

  @type id :: String.t()

  defmodule Meta do
    @moduledoc "Session metadata returned by `Tau.list_sessions/1`."
    @enforce_keys [:id, :cwd, :created_at]
    defstruct [:id, :cwd, :created_at, :updated_at, :provider, :model, :metadata]

    @type t :: %__MODULE__{
            id: String.t(),
            cwd: String.t(),
            created_at: DateTime.t(),
            updated_at: DateTime.t() | nil,
            provider: module() | nil,
            model: String.t() | nil,
            metadata: map() | nil
          }
  end

  # Public API (delegated to from the top-level `Tau` module)

  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(_opts), do: {:error, :not_implemented}

  @spec send(id(), String.t() | map()) :: :ok | {:error, term()}
  def send(_id, _message), do: {:error, :not_implemented}

  @spec stream(id(), keyword()) :: Enumerable.t()
  def stream(_id, _opts \\ []), do: Stream.unfold(:done, fn :done -> nil end)

  @spec resume(id()) :: {:ok, id()} | {:error, term()}
  def resume(_id), do: {:error, :not_implemented}

  @spec fork(id(), String.t()) :: {:ok, id()} | {:error, term()}
  def fork(_id, _event_id), do: {:error, :not_implemented}

  @spec cancel(id()) :: :ok
  def cancel(_id), do: :ok

  @spec stop(id()) :: :ok
  def stop(_id), do: :ok

  @spec list_sessions(map()) :: [Meta.t()]
  def list_sessions(_filters \\ %{}), do: []

  # :gen_statem child_spec / start_link / callbacks

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(_opts) do
    {:ok, :idle, %{}}
  end

  @impl :gen_statem
  def handle_event(_event_type, _event, _state, data) do
    {:keep_state, data}
  end
end

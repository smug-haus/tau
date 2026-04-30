defmodule Tau.Sessions.Supervisor do
  @moduledoc """
  `DynamicSupervisor` that owns the lifetime of every `Tau.Session` FSM.

  Sessions are decoupled from their callers — `Tau.start_session/1` returns
  a session id; the session itself lives on under this supervisor. Callers
  observe the session via PubSub (`stream/2`) or by directly addressing the
  process by session_id through `Tau.Sessions.Registry`.
  """
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Start a new `Tau.Session` under this supervisor.
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Tau.Session, opts})
  end
end

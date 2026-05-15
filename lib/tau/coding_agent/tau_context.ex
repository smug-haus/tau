defmodule Tau.CodingAgent.TauContext do
  @moduledoc """
  Per-run `tau-context` MCP server (SPEC-CODING-AGENT §4 B4).

  Each `Tau.CodingAgent.Dispatcher` run that opts in (default:
  on, via `coding_agent.expose_tau_context = true` in settings)
  starts one of these alongside the coding-agent subprocess.
  The server:

    * mints a per-run secret token (`Auth.mint/0`),
    * starts a Cowboy listener bound to `127.0.0.1` on an
      ephemeral port (the OS picks; we read it back from
      `:ranch.get_port/1`),
    * publishes its live state into a `:persistent_term` key the
      `Router` Plug reads on every request,
    * exposes the four tau-side tools (`Tools.catalog/0`),
    * shuts down cleanly when its owner (the dispatcher) exits.

  ## D-032 enforcement

  The dispatcher passes its pid; we `Process.monitor/1` it. If
  the dispatcher dies for any reason — supervisor restart, user
  cancel, BEAM crash — we stop, taking the listener with us.
  Conversely, our crash does NOT take down the dispatcher; the
  dispatcher treats absence of a TauContext as "feature
  disabled" and continues.

  ## D-035 conformance

  Both `start_link/1` and `stop/1` are total — failure to bind
  a port returns a tagged tuple rather than raising. The router
  itself rescues across the request boundary.

  ## Public mcp_servers entry

  `mcp_servers_entry/1` returns the map a coding-agent adapter
  threads into its `--mcp-config` invocation:

      %{
        "name" => "tau-context",
        "url"  => "http://127.0.0.1:54321/mcp",
        "token" => "<secret>",
        "transport" => "http"
      }

  The adapter is free to translate this into whatever
  per-CLI configuration shape it needs; this contract is the
  one Phase 1B Team A's ClaudeCode adapter consumes.
  """

  use GenServer, restart: :temporary

  alias Tau.CodingAgent.TauContext.{Auth, Router}

  @default_max_depth 2
  @default_server_name "tau-context"

  defmodule State do
    @moduledoc false

    @enforce_keys [:token, :state_ref, :name]
    defstruct [
      :token,
      :state_ref,
      :name,
      :ref,
      :port,
      :url,
      :owner,
      :owner_ref,
      :session_id,
      :cwd,
      max_depth: 2
    ]

    @type t :: %__MODULE__{
            token: String.t(),
            state_ref: term(),
            name: String.t(),
            ref: term() | nil,
            port: non_neg_integer() | nil,
            url: String.t() | nil,
            owner: pid() | nil,
            owner_ref: reference() | nil,
            session_id: String.t() | nil,
            cwd: String.t() | nil,
            max_depth: non_neg_integer()
          }
  end

  # ── public API ────────────────────────────────────────────────

  @doc """
  Start a TauContext server.

  ## Options

    * `:owner`      — pid of the dispatcher (monitored; required for
      production use, but optional for tests).
    * `:session_id` — tau session id this run is bound to. The
      `tau_session_status` tool reads from this.
    * `:cwd`        — workspace cwd, used as the default search
      root for `tau_memory_query`. Defaults to the session's cwd
      (via `Tau.Session.snapshot/1`), or `File.cwd!/0`.
    * `:max_depth`  — recursive delegation cap (default 2).
    * `:name`       — friendly name embedded in the `mcp_servers`
      entry. Defaults to `"tau-context"`.

  Returns the pid of the lifecycle process; the listener has
  already been bound (synchronous bind in `init/1`) so callers
  can safely call `mcp_servers_entry/1` immediately.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Return the `mcp_servers` entry to thread into a coding-agent
  task struct.
  """
  @spec mcp_servers_entry(pid()) :: map()
  def mcp_servers_entry(pid) when is_pid(pid) do
    GenServer.call(pid, :mcp_servers_entry)
  end

  @doc "Return the listener URL (test convenience)."
  @spec url(pid()) :: String.t()
  def url(pid) when is_pid(pid), do: GenServer.call(pid, :url)

  @doc "Return the per-run token (test convenience)."
  @spec token(pid()) :: String.t()
  def token(pid) when is_pid(pid), do: GenServer.call(pid, :token)

  @doc "Return the bound port (test convenience)."
  @spec port_number(pid()) :: non_neg_integer()
  def port_number(pid) when is_pid(pid), do: GenServer.call(pid, :port)

  @doc """
  Cooperative stop. Releases the listener port and persistent_term
  key, then exits `:normal`. Returns `:ok` whether the process was
  alive or already gone — this is a cleanup helper, not a
  supervision signal.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    else
      :ok
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.get(opts, :owner)
    session_id = Keyword.get(opts, :session_id)
    cwd = Keyword.get(opts, :cwd) || maybe_session_cwd(session_id)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    name = Keyword.get(opts, :name, @default_server_name)

    token = Auth.mint()
    state_ref = make_state_ref()

    case start_listener(state_ref) do
      {:ok, ref, port} ->
        owner_ref = if is_pid(owner), do: Process.monitor(owner), else: nil

        state = %State{
          token: token,
          state_ref: state_ref,
          name: name,
          ref: ref,
          port: port,
          url: "http://127.0.0.1:#{port}/mcp",
          owner: owner,
          owner_ref: owner_ref,
          session_id: session_id,
          cwd: cwd,
          max_depth: max_depth
        }

        publish_state(state)

        :telemetry.execute(
          [:tau, :coding_agent, :tau_context, :start],
          %{system_time: System.system_time()},
          %{port: port, session_id: session_id, owner: owner}
        )

        {:ok, state}

      {:error, reason} ->
        {:stop, {:listener_bind_failed, reason}}
    end
  end

  @impl true
  def handle_call(:mcp_servers_entry, _from, state) do
    {:reply, build_mcp_entry(state), state}
  end

  def handle_call(:url, _from, state), do: {:reply, state.url, state}
  def handle_call(:token, _from, state), do: {:reply, state.token, state}
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{owner_ref: ref} = state) do
    # Dispatcher died — take the listener down with it.
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_listener(state.ref)
    unpublish_state(state.state_ref)

    if state.owner_ref do
      Process.demonitor(state.owner_ref, [:flush])
    end

    :telemetry.execute(
      [:tau, :coding_agent, :tau_context, :stop],
      %{system_time: System.system_time()},
      %{port: state.port, session_id: state.session_id}
    )

    :ok
  end

  # ── internals ─────────────────────────────────────────────────

  defp build_mcp_entry(%State{} = s) do
    %{
      "name" => s.name,
      "url" => s.url,
      "token" => s.token,
      "transport" => "http"
    }
  end

  defp publish_state(%State{} = s) do
    :persistent_term.put(s.state_ref, %{
      token: s.token,
      session_id: s.session_id,
      cwd: s.cwd,
      max_depth: s.max_depth
    })
  end

  defp unpublish_state(state_ref) do
    try do
      :persistent_term.erase(state_ref)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp make_state_ref do
    {__MODULE__, make_ref()}
  end

  defp start_listener(state_ref) do
    ref = make_ref()

    cowboy_opts = [
      ip: {127, 0, 0, 1},
      port: 0,
      ref: ref
    ]

    plug_opts = [state_ref: state_ref]

    case Plug.Cowboy.http(Router, plug_opts, cowboy_opts) do
      {:ok, _pid} ->
        port = :ranch.get_port(ref)
        {:ok, ref, port}

      {:error, {:already_started, _pid}} ->
        # Vanishingly unlikely given fresh `make_ref/0`, but be
        # explicit so we don't leak a half-started listener.
        _ = Plug.Cowboy.shutdown(ref)
        {:error, :ref_already_started}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:cowboy_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:cowboy_threw, kind, reason}}
  end

  defp stop_listener(nil), do: :ok

  defp stop_listener(ref) do
    try do
      Plug.Cowboy.shutdown(ref)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp maybe_session_cwd(nil), do: nil

  defp maybe_session_cwd(id) when is_binary(id) do
    case Tau.Session.snapshot(id) do
      {:ok, %{cwd: cwd}} when is_binary(cwd) -> cwd
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end

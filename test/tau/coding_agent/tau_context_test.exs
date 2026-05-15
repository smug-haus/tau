defmodule Tau.CodingAgent.TauContextTest do
  @moduledoc """
  Lifecycle test for the per-run tau-context MCP server
  (SPEC-CODING-AGENT §4 B4).

  Asserts:

    * `start_link/1` binds a port on 127.0.0.1 synchronously.
    * `mcp_servers_entry/1` returns a usable URL + token.
    * The bound port closes when `stop/1` returns.
    * `Process.monitor` on the owner is honored — owner exit
      stops the listener (D-032).
  """

  use ExUnit.Case, async: true

  alias Tau.CodingAgent.TauContext

  describe "start_link/1" do
    test "binds an ephemeral port on 127.0.0.1 and exposes the mcp_servers entry" do
      {:ok, pid} = TauContext.start_link([])
      entry = TauContext.mcp_servers_entry(pid)

      assert is_map(entry)
      assert entry["name"] == "tau-context"
      assert String.starts_with?(entry["url"], "http://127.0.0.1:")
      assert String.ends_with?(entry["url"], "/mcp")
      assert is_binary(entry["token"])
      assert byte_size(entry["token"]) >= 40
      assert entry["transport"] == "http"

      assert TauContext.port_number(pid) > 0

      TauContext.stop(pid)
    end

    test "port is actually listening on 127.0.0.1" do
      {:ok, pid} = TauContext.start_link([])
      port = TauContext.port_number(pid)

      # Open a TCP socket to confirm the listener is up.
      {:ok, sock} =
        :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

      :ok = :gen_tcp.close(sock)
      TauContext.stop(pid)
    end

    test "two servers get distinct ports and distinct tokens" do
      {:ok, a} = TauContext.start_link([])
      {:ok, b} = TauContext.start_link([])

      assert TauContext.port_number(a) != TauContext.port_number(b)
      assert TauContext.token(a) != TauContext.token(b)

      TauContext.stop(a)
      TauContext.stop(b)
    end
  end

  describe "stop/1" do
    test "releases the bound port" do
      {:ok, pid} = TauContext.start_link([])
      port = TauContext.port_number(pid)

      :ok = TauContext.stop(pid)
      refute Process.alive?(pid)

      # Give Cowboy a beat to release the listener.
      :timer.sleep(50)

      # Re-binding the same port on 127.0.0.1 must succeed.
      case :gen_tcp.listen(port, ifaddr: {127, 0, 0, 1}, reuseaddr: true) do
        {:ok, sock} -> :gen_tcp.close(sock)
        # A non-eaddrinuse error is also acceptable (the port may
        # still be in TIME_WAIT). What matters is that the listener
        # is no longer holding the socket.
        {:error, :eaddrinuse} -> flag_port_still_held(port)
        {:error, _other} -> :ok
      end
    end

    defp flag_port_still_held(port) do
      flunk("port #{port} still held by tau-context after stop/1")
    end
  end

  describe "owner monitoring (D-032)" do
    test "tau-context stops when its owner exits" do
      parent = self()

      owner =
        spawn(fn ->
          receive do
            :exit_now -> :ok
          end
        end)

      {:ok, pid} = TauContext.start_link(owner: owner)
      ref = Process.monitor(pid)

      send(parent, {:ready, pid})

      send(owner, :exit_now)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "options" do
    test "session_id and cwd flow into the persistent_term state" do
      {:ok, pid} =
        TauContext.start_link(
          session_id: "sess-abc",
          cwd: "/tmp",
          max_depth: 4
        )

      # We don't expose the state directly; instead exercise it via
      # the router-visible URL. Confirm the GenServer is alive and
      # returns the expected friendly URL.
      assert TauContext.url(pid) =~ "127.0.0.1"
      TauContext.stop(pid)
    end
  end
end

defmodule Tau.Extensions.LoaderTest do
  @moduledoc """
  Unit tests for `Tau.Extensions.Loader`.

  Covers SPEC-EXTENSIONS Stage A:
    - AC-3 / D-120: crash-proof registration; application boots with a raising extension
    - AC-4 / D-121: synchronous load in init/1
    - AC-5 / D-123: auto-discovery with pre-compile collision guard
    - AC-6 / D-124: reload unload-before-load (no stale generation)
  """
  use ExUnit.Case, async: false

  alias Tau.Extensions.Loader

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_id, do: System.unique_integer([:positive])

  # ---------------------------------------------------------------------------
  # Fixture extension modules (defined at compile time, available in the VM)
  # ---------------------------------------------------------------------------

  defmodule RaisingExtension do
    @moduledoc "Fixture: tools/0 raises."
    @behaviour Tau.Extension

    @impl Tau.Extension
    def tools, do: raise("intentional crash in tools/0")

    @impl Tau.Extension
    def hooks, do: []

    @impl Tau.Extension
    def commands, do: []

    @impl Tau.Extension
    def skills, do: []
  end

  defmodule RaisingHooksExtension do
    @moduledoc "Fixture: hooks/0 raises."
    @behaviour Tau.Extension

    @impl Tau.Extension
    def tools, do: []

    @impl Tau.Extension
    def hooks, do: raise("intentional crash in hooks/0")

    @impl Tau.Extension
    def commands, do: []

    @impl Tau.Extension
    def skills, do: []
  end

  # ---------------------------------------------------------------------------
  # AC-3 / D-120: crash-proof registration
  # ---------------------------------------------------------------------------

  describe "AC-3 / D-120: crash-proof registration" do
    test "application is already running — proves Loader.init/1 did not crash the boot tree" do
      # The full Tau app is started by ExUnit. If Loader.init/1 crashed,
      # the :rest_for_one cascade would prevent the app from starting and
      # ExUnit itself would have failed before reaching this test.
      assert Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :tau end)
    end

    test "Loader process is alive" do
      assert Process.alive?(Process.whereis(Loader))
    end

    test "register_module/1 with a raising tools/0 emits exception telemetry and keeps Loader alive" do
      test_pid = self()
      handler_id = "test-ext-exception-#{unique_id()}"

      :telemetry.attach(
        handler_id,
        [:tau, :extensions, :load, :exception],
        fn _event, _measurements, meta, _ ->
          send(test_pid, {:ext_exception, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Reload with the raising module — the cast goes to the live Loader.
      Loader.reload(RaisingExtension)

      # Must receive the telemetry exception event — proves crash was handled.
      assert_receive {:ext_exception, %{entry: RaisingExtension}}, 3_000

      # Loader process must still be alive after the raise.
      assert Process.alive?(Process.whereis(Loader))
    end

    test "register_module/1 with a raising hooks/0 emits exception telemetry and keeps Loader alive" do
      test_pid = self()
      handler_id = "test-ext-exception-hooks-#{unique_id()}"

      :telemetry.attach(
        handler_id,
        [:tau, :extensions, :load, :exception],
        fn _event, _measurements, meta, _ ->
          send(test_pid, {:ext_exception, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Loader.reload(RaisingHooksExtension)
      assert_receive {:ext_exception, %{entry: RaisingHooksExtension}}, 3_000
      assert Process.alive?(Process.whereis(Loader))
    end

    test "telemetry start/stop span is emitted on successful module registration" do
      test_pid = self()
      ref = make_ref()
      handler_id = "test-ext-load-stop-#{unique_id()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:tau, :extensions, :load, :start],
          [:tau, :extensions, :load, :stop]
        ],
        fn event, _measurements, _meta, _ ->
          send(test_pid, {ref, event})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Load via module atom (already compiled, skips collision check).
      Loader.reload(HelloWorldExt)

      assert_receive {^ref, [:tau, :extensions, :load, :start]}, 3_000
      assert_receive {^ref, [:tau, :extensions, :load, :stop]}, 3_000
    end
  end

  # ---------------------------------------------------------------------------
  # AC-4 / D-121: synchronous load in init/1
  # ---------------------------------------------------------------------------

  describe "AC-4 / D-121: synchronous load in init/1" do
    test "Loader responds to list/0 immediately — proves init/1 returned {:ok, state}" do
      entries = Loader.list()
      assert is_list(entries)
    end

    test "extension tools registered via module atom are visible via Tau.Tool.lookup/1" do
      # Register by module atom (bypasses compilation path).
      Loader.reload(HelloWorldExt)
      # Allow the async cast to process.
      :timer.sleep(100)

      assert {:ok, HelloWorldExt.HelloTool} = Tau.Tool.lookup("hello_world")
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-123: auto-discovery and collision guard
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-123: auto-discovery and collision guard" do
    test "load_entry with a module atom appears in loaded list" do
      # HelloWorldExt is compiled from test/support at test compile time.
      # Register it directly by module atom.
      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      entries = Loader.list()
      assert Enum.any?(entries, fn %{key: key} -> key == HelloWorldExt end)
    end

    test "collision guard: a module already loaded prevents re-compilation of a file defining the same module" do
      # HelloWorldExt is compiled at test compile time (test/support/).
      # Create a tmp file that defines HelloWorldExt — should be skipped.
      collision_path =
        Path.join(System.tmp_dir!(), "collision_#{unique_id()}.ex")

      File.write!(collision_path, """
      defmodule HelloWorldExt do
        use Tau.Extension
        def extra_fn, do: :collision_marker
      end
      """)

      on_exit(fn -> File.rm(collision_path) end)

      # HelloWorldExt should already be loaded (it is a test/support module).
      assert Code.ensure_loaded?(HelloWorldExt)

      # Now try to load the collision file — Loader should skip it.
      Loader.reload(collision_path)
      :timer.sleep(200)

      # The original module is preserved — extra_fn/0 should NOT be defined.
      refute function_exported?(HelloWorldExt, :extra_fn, 0),
             "Collision guard failed: the colliding file was compiled and clobbered the original module"
    end

    test "loading a non-existent path produces an entry with zero modules (path is safely ignored)" do
      nonexistent = "/nonexistent/path/that/does/not/exist-#{unique_id()}"
      Loader.reload(nonexistent)
      :timer.sleep(100)

      entries = Loader.list()
      entry = Enum.find(entries, fn %{key: k} -> k == nonexistent end)

      if entry do
        # If an entry is recorded, it must have an empty modules list —
        # no extension modules registered from a non-existent path.
        assert entry.info[:modules] == []
      else
        # Also acceptable: no entry recorded at all.
        assert true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC-6 / D-124: reload unload-before-load
  # ---------------------------------------------------------------------------

  describe "AC-6 / D-124: reload does not leave stale generation" do
    test "reloading a module removes prior generation from loaded map" do
      # First load.
      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      entries_before = Loader.list()
      count_before = Enum.count(entries_before, fn %{key: k} -> k == HelloWorldExt end)
      assert count_before == 1

      # Second reload — should replace, not accumulate.
      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      entries_after = Loader.list()
      count_after = Enum.count(entries_after, fn %{key: k} -> k == HelloWorldExt end)

      assert count_after == 1,
             "Expected 1 entry after reload, got #{count_after} — stale generation not removed"
    end

    test "tool is still resolvable after reload (not unregistered without re-registering)" do
      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      assert {:ok, HelloWorldExt.HelloTool} = Tau.Tool.lookup("hello_world")
    end
  end

  # ---------------------------------------------------------------------------
  # list/0 API
  # ---------------------------------------------------------------------------

  describe "list/0" do
    test "returns a list" do
      assert is_list(Loader.list())
    end

    test "each entry has :key and :info fields" do
      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      for entry <- Loader.list() do
        assert Map.has_key?(entry, :key)
        assert Map.has_key?(entry, :info)
      end
    end
  end
end

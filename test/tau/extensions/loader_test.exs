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

      on_exit(fn ->
        :telemetry.detach(handler_id)
        Loader.unload(HelloWorldExt)
        # Allow the async cast to complete before the test process exits.
        :timer.sleep(50)
      end)

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
      on_exit(fn ->
        Loader.unload(HelloWorldExt)
        :timer.sleep(50)
      end)

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
      on_exit(fn ->
        Loader.unload(HelloWorldExt)
        :timer.sleep(50)
      end)

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
      on_exit(fn ->
        Loader.unload(HelloWorldExt)
        :timer.sleep(50)
      end)

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
      on_exit(fn ->
        Loader.unload(HelloWorldExt)
        :timer.sleep(50)
      end)

      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      assert {:ok, HelloWorldExt.HelloTool} = Tau.Tool.lookup("hello_world")
    end
  end

  # ---------------------------------------------------------------------------
  # AC-3 / D-122: init/1 crash-isolation — the REAL path (f-1)
  #
  # The tests above exercise crash-isolation in handle_cast (Loader.reload/1).
  # This section starts a FRESH Loader process whose init/1 encounters a
  # raising extension, and asserts init/1 returns {:ok, _} (not {:stop, _}).
  # ---------------------------------------------------------------------------

  describe "AC-3 / D-122: init/1 crash-isolation for a raising extension" do
    test "a fresh Loader whose init/1 encounters a raising extension starts successfully" do
      # AC-3 requires that Loader.init/1 itself is crash-isolated, not just
      # handle_cast (which Loader.reload/1 uses). This test starts a FRESH,
      # anonymous Loader process with a raising extension injected directly
      # into init/1 via opts[:entries]. If the crash-isolation guard were
      # absent from the init/1 load path, start_link would return {:error, _}
      # because init/1 would propagate the raise to the supervisor.
      #
      # A known-good sibling extension (HelloWorldExt) registered before the
      # raising extension MUST still be registered — proves the failing extension
      # was skipped, not the whole load aborted — D-120, D-122.
      uid = unique_id()

      # Write a raising extension source file to a temp dir.
      tmp = Path.join(System.tmp_dir!(), "tau-loader-init-#{uid}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      raising_file = Path.join(tmp, "raising_#{uid}.ex")

      raising_src =
        "defmodule Tau.Extensions.LoaderTest.InitRaising#{uid} do\n" <>
          "  @behaviour Tau.Extension\n" <>
          "  def tools, do: raise(\"boom — intentional crash inside init/1 load path\")\n" <>
          "  def hooks, do: []\n" <>
          "  def commands, do: []\n" <>
          "  def skills, do: []\n" <>
          "end\n"

      File.write!(raising_file, raising_src)

      # opts[:entries] bypasses Settings.Cache — passes HelloWorldExt (good)
      # and the raising file path as init/1 entries directly. start_link calls
      # init/1 synchronously; if init/1 does not crash-isolate the raiser, it
      # propagates the exception and start_link returns {:error, reason}.
      test_name = :"test_loader_init_#{uid}"

      result =
        start_supervised(
          %{
            id: test_name,
            start:
              {Tau.Extensions.Loader, :start_link,
               [[name: test_name, entries: [HelloWorldExt, raising_file]]]}
          },
          id: test_name
        )

      assert {:ok, pid} = result,
             "Loader.init/1 MUST return {:ok, state} even when a raising extension is present. " <>
               "Got: #{inspect(result)}. This means init/1 propagated the raise — " <>
               "the crash-isolation guard in the init/1 load path is missing or broken."

      assert Process.alive?(pid),
             "Fresh Loader process must be alive after init/1 encountered a raising extension"

      # The good extension (HelloWorldExt) must be registered despite the raiser.
      entries = GenServer.call(test_name, :list)

      assert Enum.any?(entries, fn %{key: k} -> k == HelloWorldExt end),
             "HelloWorldExt must be registered — the raising extension must be skipped, " <>
               "not cause the entire load to abort (D-120, D-122)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-5 / D-123: collision guard for brand-new (never-compiled) modules (f-3)
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-123: collision guard catches brand-new module name collisions" do
    test "two dirs each defining the same never-before-seen module: second is skipped" do
      # Use a unique module name so neither file is compiled at test-compile time.
      # This is the scenario the old String.to_existing_atom guard MISSED:
      # the name had no existing atom, so peek_module_names/1 returned [] for it,
      # and both files passed the guard independently.
      uid = unique_id()
      mod_name = "TauTestCollision#{uid}"
      full_mod = "Tau.Extensions.LoaderTest.#{mod_name}"

      dir_a = Path.join(System.tmp_dir!(), "tau-coll-a-#{uid}")
      dir_b = Path.join(System.tmp_dir!(), "tau-coll-b-#{uid}")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      on_exit(fn ->
        File.rm_rf!(dir_a)
        File.rm_rf!(dir_b)
      end)

      src_template = fn extra ->
        """
        defmodule #{full_mod} do
          @behaviour Tau.Extension
          def tools, do: []
          def hooks, do: []
          def commands, do: []
          def skills, do: []
          def marker, do: #{inspect(extra)}
        end
        """
      end

      File.write!(Path.join(dir_a, "ext.ex"), src_template.(:dir_a))
      File.write!(Path.join(dir_b, "ext.ex"), src_template.(:dir_b))

      # Load dir_a first — this compiles the module.
      Loader.reload(dir_a)
      :timer.sleep(200)

      # Now load dir_b — same module name, already compiled from dir_a.
      # The collision guard should detect the collision and skip dir_b.
      Loader.reload(dir_b)
      :timer.sleep(200)

      # The module from dir_a should be the one that stuck.
      # Its marker/0 should return :dir_a.
      mod_atom = String.to_existing_atom("Elixir." <> full_mod)

      assert Code.ensure_loaded?(mod_atom),
             "Module from dir_a should be compiled"

      assert mod_atom.marker() == :dir_a,
             "Collision guard failed: dir_b clobbered dir_a's module. " <>
               "The guard must detect collisions even for brand-new module names."

      on_exit(fn ->
        Loader.unload(dir_a)
        Loader.unload(dir_b)
        :timer.sleep(50)
      end)
    end

    test "two dirs each defining the same never-before-seen module in one load: first file wins, second skipped" do
      # Variant: both files are in the same directory scan, i.e. both go through
      # compile_with_collision_guard in the same load_entry call. After the first
      # file is compiled, the second should be skipped.
      uid = unique_id()
      mod_name = "TauTestCollSameDir#{uid}"
      full_mod = "Tau.Extensions.LoaderTest.#{mod_name}"

      dir = Path.join(System.tmp_dir!(), "tau-coll-same-#{uid}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      src = fn extra ->
        """
        defmodule #{full_mod} do
          @behaviour Tau.Extension
          def tools, do: []
          def hooks, do: []
          def commands, do: []
          def skills, do: []
          def marker, do: #{inspect(extra)}
        end
        """
      end

      # Two files in the same dir — alphabetical order determines which compiles first.
      File.write!(Path.join(dir, "a_first.ex"), src.(:first))
      File.write!(Path.join(dir, "b_second.ex"), src.(:second))

      Loader.reload(dir)
      :timer.sleep(200)

      mod_atom = String.to_existing_atom("Elixir." <> full_mod)

      assert Code.ensure_loaded?(mod_atom),
             "First file in the dir should have compiled the module"

      # The first file (alphabetically a_first.ex) defines :first.
      assert mod_atom.marker() == :first,
             "The second file should have been skipped by the collision guard — " <>
               "its defmodule defines the same module as the first file"

      on_exit(fn ->
        Loader.unload(dir)
        :timer.sleep(50)
      end)
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
      on_exit(fn ->
        Loader.unload(HelloWorldExt)
        :timer.sleep(50)
      end)

      Loader.reload(HelloWorldExt)
      :timer.sleep(100)

      for entry <- Loader.list() do
        assert Map.has_key?(entry, :key)
        assert Map.has_key?(entry, :info)
      end
    end
  end
end

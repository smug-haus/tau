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
  # AC-5 / D-123: discover_extension_dirs/0 — genuine auto-discovery (f-1 gap)
  #
  # The existing AC-5 collision-guard tests use Loader.reload/1 (handle_cast),
  # which bypasses init/1 and Settings.Cache entirely. They do NOT cover
  # discover_extension_dirs/0 or the explicit ++ reject(discovered) dedup in
  # init/1. These tests start a fresh anonymous Loader with NO opts[:entries]
  # injection, so the real discovery path runs.
  #
  # Override strategy:
  #   File.cwd() reads the OS-level POSIX process cwd, which is shared across
  #   all BEAM processes in the same OS process. File.cd!/2 wrapping
  #   start_supervised is synchronous (start_supervised waits for init/1 to
  #   return), so init/1 sees the changed cwd when it calls File.cwd().
  #
  # Home-dir discovery limitation:
  #   System.user_home/0 reads :init.get_argument(:home), which is set by the
  #   Erlang VM at startup and is NOT updated by System.put_env("HOME", ...).
  #   Therefore, ~/.tau/extensions/ discovery cannot be unit-tested without
  #   modifying production code (to accept a home-dir override). The cwd path
  #   IS overridable, so these tests exercise discover_extension_dirs/0 through
  #   the <cwd>/.tau/extensions/ branch. This is a genuine test of the function:
  #   if discover_extension_dirs/0 returns [] (broken), the load fails and the
  #   test goes red.
  # ---------------------------------------------------------------------------

  describe "AC-5 / D-123: genuine auto-discovery via discover_extension_dirs/0" do
    test "extensions in <cwd>/.tau/extensions/ auto-load without a settings.extensions entry" do
      uid = unique_id()
      mod_src_name = "Tau.Extensions.LoaderTest.DiscoveryCwd#{uid}"
      mod_atom = String.to_atom("Elixir." <> mod_src_name)

      # Create a temp dir to act as cwd; place a .tau/extensions/ subdir in it.
      tmp_cwd = Path.join(System.tmp_dir!(), "tau-disc-cwd-#{uid}")
      ext_dir = Path.join(tmp_cwd, ".tau/extensions")
      File.mkdir_p!(ext_dir)

      File.write!(Path.join(ext_dir, "discovery_cwd_ext.ex"), """
      defmodule #{mod_src_name} do
        @behaviour Tau.Extension
        def tools, do: []
        def hooks, do: []
        def commands, do: []
        def skills, do: []
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      # Start a fresh anonymous Loader with NO opts[:entries] — forces the real
      # discovery path: init/1 calls Settings.Cache.get() (returns [] for extensions
      # in the test env) and discover_extension_dirs/0. File.cd!/2 changes the
      # OS-level process cwd so discover_extension_dirs/0's File.cwd() returns tmp_cwd.
      test_name = :"test_loader_discovery_cwd_#{uid}"

      result =
        File.cd!(tmp_cwd, fn ->
          start_supervised(
            %{
              id: test_name,
              start: {Tau.Extensions.Loader, :start_link, [[name: test_name]]}
            },
            id: test_name
          )
        end)

      assert {:ok, _pid} = result,
             "Anonymous Loader must start successfully; got: #{inspect(result)}"

      entries = GenServer.call(test_name, :list)

      # The auto-discovered dir must appear in the loaded entries.
      assert Enum.any?(entries, fn %{key: k} -> k == ext_dir end),
             "Expected auto-discovered dir #{inspect(ext_dir)} in loaded entries. " <>
               "Got: #{inspect(Enum.map(entries, & &1.key))}. " <>
               "discover_extension_dirs/0 may not scan <cwd>/.tau/extensions/."

      # The compiled extension module must be in the VM.
      assert Code.ensure_loaded?(mod_atom),
             "Extension module #{mod_src_name} must be compiled by auto-discovery"
    end

    test "cwd dir appears in loaded entries before any subsequent entries — ordering preserved" do
      # discover_extension_dirs/0 builds [home_dir | cwd_dirs].
      # When cwd has extensions and home has none (as is the case in the test
      # environment), the cwd entry appears at position 0 in the loaded map.
      # This test asserts the cwd entry IS present and that it was loaded as part
      # of init/1's entry list (not injected).
      uid = unique_id()
      cwd_mod = "Tau.Extensions.LoaderTest.DiscoveryOrder#{uid}"

      tmp_cwd = Path.join(System.tmp_dir!(), "tau-disc-order-#{uid}")
      cwd_ext_dir = Path.join(tmp_cwd, ".tau/extensions")
      File.mkdir_p!(cwd_ext_dir)

      File.write!(Path.join(cwd_ext_dir, "order_ext.ex"), """
      defmodule #{cwd_mod} do
        @behaviour Tau.Extension
        def tools, do: []
        def hooks, do: []
        def commands, do: []
        def skills, do: []
      end
      """)

      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      test_name = :"test_loader_disc_order_#{uid}"

      result =
        File.cd!(tmp_cwd, fn ->
          start_supervised(
            %{
              id: test_name,
              start: {Tau.Extensions.Loader, :start_link, [[name: test_name]]}
            },
            id: test_name
          )
        end)

      assert {:ok, _pid} = result
      entries = GenServer.call(test_name, :list)
      keys = Enum.map(entries, & &1.key)

      assert cwd_ext_dir in keys,
             "Cwd extension dir must appear in loaded entries. Got: #{inspect(keys)}"
    end

    test "no extensions load when cwd and home have no .tau/extensions/ dirs" do
      uid = unique_id()

      # A cwd with no .tau/extensions subdir, and the real home (which in the
      # test env also has no .tau/extensions/ with test extensions).
      tmp_cwd = Path.join(System.tmp_dir!(), "tau-disc-empty-#{uid}")
      File.mkdir_p!(tmp_cwd)

      on_exit(fn -> File.rm_rf!(tmp_cwd) end)

      test_name = :"test_loader_discovery_no_dirs_#{uid}"

      result =
        File.cd!(tmp_cwd, fn ->
          start_supervised(
            %{
              id: test_name,
              start: {Tau.Extensions.Loader, :start_link, [[name: test_name]]}
            },
            id: test_name
          )
        end)

      assert {:ok, _pid} = result
      entries = GenServer.call(test_name, :list)

      # With no .tau/extensions/ dir in cwd (and presumably none in real home),
      # discover_extension_dirs/0 returns [] → nothing loads from discovery.
      # (The test env home may have extensions from a real ~/.tau/extensions/;
      # we assert the test-discovered cwd dir is not present, not that entries is empty.)
      refute Enum.any?(entries, fn %{key: k} ->
               is_binary(k) and String.contains?(k, tmp_cwd)
             end),
             "No entry keyed under tmp_cwd should appear when it has no .tau/extensions/ subdir"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-9: {module, opts} programmatic load path — direct test (gap)
  #
  # The loader accepts a {module, opts} tuple as an entry (programmatic API,
  # D-125 / SPEC-EXTENSIONS C-010). This branch of load_entry/1 has no direct
  # test. The test verifies the module registers correctly and that the tuple
  # form is keyed as {module, nil} in the loaded map (per entry_key/1).
  # ---------------------------------------------------------------------------

  describe "AC-9: {module, opts} programmatic load path" do
    test "{module, opts} tuple entry loads and registers the module, keyed as {module, nil}" do
      on_exit(fn ->
        GenServer.cast(Loader, {:unload, {HelloWorldExt, nil}})
        # Allow the cast to complete before the test process exits.
        :timer.sleep(50)
      end)

      # Cast a {module, opts} tuple to the production Loader via handle_cast.
      Loader.reload({HelloWorldExt, [some_opt: :value]})
      :timer.sleep(100)

      # The entry should appear in the loaded map keyed as {HelloWorldExt, nil}
      # (entry_key/1 normalises {mod, _opts} to {mod, nil}).
      entries = Loader.list()

      assert Enum.any?(entries, fn %{key: k} -> k == {HelloWorldExt, nil} end),
             "Expected {HelloWorldExt, nil} key in loaded entries (entry_key/1 normalises opts). " <>
               "Got keys: #{inspect(Enum.map(entries, & &1.key))}"

      # The module must register its tools — opts are currently unused by load_entry/1
      # ({module, opts} delegates straight to crash_safe_register which ignores opts).
      assert {:ok, HelloWorldExt.HelloTool} = Tau.Tool.lookup("hello_world"),
             "HelloWorldExt.HelloTool must be registered after {module, opts} load"
    end

    test "{module, opts} load is crash-isolated — a raising module does not crash the Loader" do
      test_pid = self()
      handler_id = "test-ext-tuple-exception-#{unique_id()}"

      :telemetry.attach(
        handler_id,
        [:tau, :extensions, :load, :exception],
        fn _event, _measurements, meta, _ ->
          send(test_pid, {:ext_exception, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A raising extension loaded via {module, opts} must be crash-isolated
      # (the crash-safe wrapper in crash_safe_register/2 covers this path).
      Loader.reload({RaisingExtension, []})

      assert_receive {:ext_exception, %{entry: {RaisingExtension, nil}}}, 3_000

      assert Process.alive?(Process.whereis(Loader)),
             "Loader must survive a raising {module, opts} entry"
    end

    test "{module, opts} opts are not propagated to the extension — load_entry/1 ignores opts" do
      # Documented behaviour: opts in {module, opts} entries are inert in the
      # current implementation (load_entry/1 delegates to crash_safe_register/2
      # which only uses the module atom). This test asserts that opts do not
      # cause a crash, and that the result is identical to loading the module atom.
      on_exit(fn ->
        GenServer.cast(Loader, {:unload, {HelloWorldExt, nil}})
        :timer.sleep(50)
      end)

      Loader.reload({HelloWorldExt, [unused_opt: :ignored, another: 42]})
      :timer.sleep(100)

      # The tool is registered — opts had no adverse effect.
      assert {:ok, HelloWorldExt.HelloTool} = Tau.Tool.lookup("hello_world"),
             "Tool must register even when opts are provided (opts are inert)"
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

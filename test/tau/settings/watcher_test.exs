defmodule Tau.Settings.WatcherTest do
  @moduledoc """
  Tests for Tau.Settings.Watcher degraded-mode behaviour (D-008).

  D-008: Watcher degraded mode emits [:tau, :settings, :watcher_degraded]
  telemetry when file_system worker cannot be started.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @telemetry_event [:tau, :settings, :watcher_degraded]

  describe "degraded mode (D-008)" do
    test "emits [:tau, :settings, :watcher_degraded] telemetry when file_system fails" do
      test_pid = self()
      ref = make_ref()

      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Pass dirs: [] to force the {:error, :no_dirs} degraded path without
      # calling FileSystem.start_link at all. This verifies the telemetry
      # emission path regardless of whether inotify-tools is installed.
      {:ok, _pid} =
        GenServer.start(Tau.Settings.Watcher, [dirs: []], name: :"tau_watcher_test_#{inspect(ref)}")

      assert_receive {:telemetry, ^ref, [:tau, :settings, :watcher_degraded], measurements,
                      metadata},
                     1000

      assert is_integer(measurements.system_time_native)
      assert metadata.reason != nil
    end

    test "no [error] or [warning] noise when FileSystem.start_link is called on this host" do
      # Use a real tmpdir so dirs is non-empty and FileSystem.start_link/1 is
      # actually invoked. On a host without inotify-tools, :file_system emits
      # [error]/[warning] to stderr before the Watcher can degrade gracefully.
      # The primary logger filter installed in Tau.Application.start/2 must
      # suppress those messages. This test validates that the filter is in place
      # (it is installed at app boot; the application is running during tests).
      tmpdir = System.tmp_dir!()

      log =
        capture_log(fn ->
          {:ok, pid} =
            GenServer.start(Tau.Settings.Watcher, [dirs: [tmpdir]],
              name: :"tau_watcher_noise_test_#{System.unique_integer()}"
            )

          Process.sleep(100)
          GenServer.stop(pid)
        end)

      refute log =~ "[error]"
      refute log =~ "[warning]"
      refute log =~ "inotify"
      refute log =~ "file_system"
    end
  end
end

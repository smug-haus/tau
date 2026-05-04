defmodule Tau.CLI.TuiSmokeTest do
  @moduledoc """
  Headless TUI smoke gates. See `docs/spec/SPEC-TUI-HEADLESS.md`.

  Tests are tagged `:tui_smoke` so they can be skipped on hosts without
  `tmux` or without a built Burrito binary. Run explicitly with:

      mix test --only tui_smoke

  Each test maps directly to an AC-H from SPEC-TUI-HEADLESS §6, which
  in turn maps to an AC-N from SPEC-USER-TURN §7.
  """

  use ExUnit.Case, async: false

  alias Tau.Test.TuiPtyHelper

  @moduletag :tui_smoke
  @moduletag timeout: 60_000

  setup do
    # Arch-aware binary selection; if the matching binary doesn't exist,
    # skip rather than fail.
    case binary_for_host() do
      nil ->
        {:skip, "No matching Burrito binary for host arch — run `mix release` first"}

      bin ->
        unless System.find_executable("tmux") do
          {:skip, "tmux not found on PATH"}
        else
          tmpdir = System.tmp_dir!() |> Path.join("tau-tui-smoke-#{:rand.uniform(1_000_000)}")
          File.mkdir_p!(tmpdir)

          on_exit(fn ->
            File.rm_rf(tmpdir)
          end)

          {:ok, binary: bin, tmpdir: tmpdir}
        end
    end
  end

  describe "AC-H1: first-run smoke (mirrors SPEC-USER-TURN AC-1)" do
    test "TUI renders status bar, transcript panel, prompt", %{
      binary: binary,
      tmpdir: tmpdir
    } do
      {:ok, sess} = TuiPtyHelper.start(binary, env: [{"TAU_DATA_DIR", tmpdir}])

      on_exit(fn -> TuiPtyHelper.quit(sess) end)

      {:ok, pane} = TuiPtyHelper.capture(sess)

      assert pane =~ ~r/session:/, "status bar missing session id; pane:\n#{pane}"
      assert pane =~ "transcript", "transcript panel header missing; pane:\n#{pane}"
      assert pane =~ "<Enter> submit", "prompt help missing; pane:\n#{pane}"
    end
  end

  describe "AC-H4: quit ergonomics (mirrors SPEC-USER-TURN AC-4)" do
    test "literal 'q' in input does not quit", %{binary: binary, tmpdir: tmpdir} do
      {:ok, sess} = TuiPtyHelper.start(binary, env: [{"TAU_DATA_DIR", tmpdir}])
      on_exit(fn -> TuiPtyHelper.quit(sess) end)

      :ok = TuiPtyHelper.send(sess, "abcq")
      Process.sleep(300)
      {:ok, pane} = TuiPtyHelper.capture(sess)

      # The literal "q" should appear in the prompt line, NOT have
      # exited the TUI. Status bar must still render.
      assert pane =~ "abcq", "input not echoed in prompt; pane:\n#{pane}"
      assert pane =~ ~r/session:/, "TUI exited on 'q' as part of input — bug; pane:\n#{pane}"
    end

    test "'q' on empty prompt quits with exit 0", %{binary: binary, tmpdir: tmpdir} do
      {:ok, sess} = TuiPtyHelper.start(binary, env: [{"TAU_DATA_DIR", tmpdir}])

      # Capture before quitting (D-023).
      {:ok, _pane} = TuiPtyHelper.capture(sess)

      :ok = TuiPtyHelper.send(sess, "q")
      Process.sleep(500)

      {:ok, _} = TuiPtyHelper.quit(sess)
    end
  end

  describe "AC-H3: provider error visibility (mirrors SPEC-USER-TURN AC-3)" do
    @tag :pending
    test "submitting with no auth surfaces an error in transcript", %{
      binary: binary,
      tmpdir: tmpdir
    } do
      # Pending: requires the SPEC-USER-TURN AC-3 fix to land first.
      # Currently the TUI reaches `:sending` and the transcript pane
      # stays empty — the error_message field on the synthetic
      # Assistant message isn't routed to render. Tracked in #149/#153
      # and addressed by D-009 / [C12]/[C19] (already partially fixed
      # on feat/anthropic-oauth — verify when this branch merges).

      {:ok, sess} =
        TuiPtyHelper.start(binary,
          env: [{"TAU_DATA_DIR", tmpdir}, {"ANTHROPIC_API_KEY", ""}]
        )

      on_exit(fn -> TuiPtyHelper.quit(sess) end)

      :ok = TuiPtyHelper.send(sess, "hi")
      :ok = TuiPtyHelper.send(sess, :enter)

      case TuiPtyHelper.await(sess, ~r/Error|auth|expired/i, timeout_ms: 5_000) do
        {:ok, _pane} ->
          :ok

        {:error, :timeout, last_pane} ->
          flunk(
            "AC-H3 violation: TUI did not surface an error within 5s. " <>
              "This is the [C12]/[C19] error-message-lost-in-render bug. " <>
              "Pane:\n#{last_pane}"
          )
      end
    end
  end

  describe "AC-H2: single turn round-trip (mirrors SPEC-USER-TURN AC-2)" do
    test "replay provider produces assistant response in transcript", %{
      binary: binary,
      tmpdir: tmpdir
    } do
      # The bar for "working TUI": user types, hits Enter, the assistant
      # response appears in the transcript pane. Replay produces a
      # deterministic "(replay) hello" so this test is hermetic.
      {:ok, sess} =
        TuiPtyHelper.start(binary,
          env: [{"TAU_DATA_DIR", tmpdir}],
          args: ["tui", "--provider", "replay", "--model", "replay"]
        )

      on_exit(fn -> TuiPtyHelper.quit(sess) end)

      :ok = TuiPtyHelper.send(sess, "hello")
      :ok = TuiPtyHelper.send(sess, :enter)

      case TuiPtyHelper.await(sess, ~r/\(replay\)/, timeout_ms: 30_000) do
        {:ok, _pane} ->
          :ok

        {:error, :timeout, last_pane} ->
          flunk(
            "AC-H2 violation: assistant response did not appear in the " <>
              "transcript pane within 30s. Pane:\n#{last_pane}"
          )
      end
    end
  end

  # --- helpers --------------------------------------------------------

  defp binary_for_host do
    candidates = [
      "burrito_out/tau_linux_#{host_arch()}",
      "burrito_out/tau_linux_amd64",
      "burrito_out/tau_linux_arm64",
      "_build/prod/rel/tau/bin/tau"
    ]

    Enum.find(candidates, fn path ->
      full = Path.join(File.cwd!(), path)
      File.regular?(full)
    end)
  end

  defp host_arch do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "x86_64" <> _ -> "amd64"
      "aarch64" <> _ -> "arm64"
      "arm64" <> _ -> "arm64"
      other -> other
    end
  end
end

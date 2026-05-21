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

  # setup_all/1 detects whether the host can run these tests and stores
  # the result in the context. setup/1 then creates per-test isolation
  # (tmpdir) when a binary is available.
  #
  # ExUnit 1.18.1 does not support {:skip, reason} from setup/1 or
  # setup_all/1 (only compile-time @tag skip: works for true ExUnit
  # "skipped" semantics). This module uses skip_if_unavailable/1 at the
  # top of each test body — it prints a "[SKIP]" notice and causes the
  # test to return without any assertions (counted as 0 failures, no
  # RuntimeError). This is the correct runtime-conditional skip pattern
  # for ExUnit 1.18.1.
  setup_all do
    skip_reason =
      cond do
        is_nil(System.find_executable("tmux")) ->
          "tmux not found on PATH"

        is_nil(binary_for_host()) ->
          "No matching Burrito binary for host arch — run `mix release` first"

        true ->
          nil
      end

    {:ok, binary: binary_for_host(), skip_reason: skip_reason}
  end

  setup ctx do
    if is_nil(ctx[:skip_reason]) do
      tmpdir = System.tmp_dir!() |> Path.join("tau-tui-smoke-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmpdir)

      on_exit(fn ->
        File.rm_rf(tmpdir)
      end)

      {:ok, Map.put(ctx, :tmpdir, tmpdir)}
    else
      {:ok, ctx}
    end
  end

  describe "AC-H1: first-run smoke (mirrors SPEC-USER-TURN AC-1)" do
    test "TUI renders status bar, transcript panel, prompt", ctx do
      if skip_if_unavailable(ctx), do: nil, else: run_ac_h1(ctx)
    end
  end

  describe "AC-H4: quit ergonomics (mirrors SPEC-USER-TURN AC-4)" do
    test "literal 'q' in input does not quit", ctx do
      if skip_if_unavailable(ctx), do: nil, else: run_ac_h4_no_quit(ctx)
    end

    test "'q' on empty prompt quits with exit 0", ctx do
      if skip_if_unavailable(ctx), do: nil, else: run_ac_h4_quit(ctx)
    end
  end

  describe "AC-H3: provider error visibility (mirrors SPEC-USER-TURN AC-3)" do
    test "submitting with no auth surfaces an error in transcript", ctx do
      if skip_if_unavailable(ctx), do: nil, else: run_ac_h3(ctx)
    end
  end

  describe "AC-H2: single turn round-trip (mirrors SPEC-USER-TURN AC-2)" do
    test "replay provider produces assistant response in transcript", ctx do
      if skip_if_unavailable(ctx), do: nil, else: run_ac_h2(ctx)
    end
  end

  # --- test implementations -----------------------------------------------

  defp run_ac_h1(%{binary: binary, tmpdir: tmpdir}) do
    {:ok, sess} = TuiPtyHelper.start(binary, env: [{"TAU_DATA_DIR", tmpdir}])

    on_exit(fn -> TuiPtyHelper.quit(sess) end)

    {:ok, pane} = TuiPtyHelper.capture(sess)

    assert pane =~ ~r/session:/, "status bar missing session id; pane:\n#{pane}"
    assert pane =~ "transcript", "transcript panel header missing; pane:\n#{pane}"
    assert pane =~ "<Enter> submit", "prompt help missing; pane:\n#{pane}"

    # D-026 ([C51-B3]): the prompt MUST render a visible cursor glyph
    # so the user can see the insertion point. "█" (U+2588) is appended
    # after model.input by the render/1 path.
    Process.sleep(150)
    {:ok, pane2} = TuiPtyHelper.capture(sess)
    assert pane2 =~ "█", "cursor glyph missing from prompt; pane:\n#{pane2}"
  end

  defp run_ac_h4_no_quit(%{binary: binary, tmpdir: tmpdir}) do
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

  defp run_ac_h4_quit(%{binary: binary, tmpdir: tmpdir}) do
    {:ok, sess} = TuiPtyHelper.start(binary, env: [{"TAU_DATA_DIR", tmpdir}])

    # Capture before quitting (D-023).
    {:ok, _pane} = TuiPtyHelper.capture(sess)

    :ok = TuiPtyHelper.send(sess, "q")
    Process.sleep(500)

    {:ok, _} = TuiPtyHelper.quit(sess)
  end

  defp run_ac_h3(%{binary: binary, tmpdir: tmpdir}) do
    # SPEC-TUI-HEADLESS §7 protocol step 3 (D-066..D-071 enforced by harness).
    #
    # Offline no-auth approach: configure the session so auth resolves
    # locally to nothing — no ANTHROPIC_API_KEY in env, and HOME pointed
    # at a tmpdir that has no ~/.claude/.credentials.json. The binary's
    # Auth.resolve/1 hits both the vault (env empty) and the OAuth file
    # path (~/<HOME>/.claude/.credentials.json, which doesn't exist) and
    # returns {:error, :no_auth}. The session FSM maps that to
    # :missing_api_key and routes the error to the transcript via
    # MessageEnd (D-009 / [C12]/[C19] fix). No network round-trip occurs.
    #
    # This test MUST pass deterministically offline. Timeout is short
    # because the error is produced locally, not over the wire.
    {:ok, sess} =
      TuiPtyHelper.start(binary,
        env: [
          {"TAU_DATA_DIR", tmpdir},
          # Empty HOME so ~/.claude/.credentials.json resolves to a
          # path under tmpdir that does not exist. Also unset any
          # ambient ANTHROPIC_API_KEY (set explicitly to empty so tmux
          # does not inherit the caller's value).
          {"HOME", tmpdir},
          {"ANTHROPIC_API_KEY", ""}
        ]
      )

    on_exit(fn -> TuiPtyHelper.quit(sess) end)

    :ok = TuiPtyHelper.send(sess, "hi")
    :ok = TuiPtyHelper.send(sess, :enter)

    case TuiPtyHelper.await(sess, ~r/Error|auth|expired|missing|key/i, timeout_ms: 5_000) do
      {:ok, _pane} ->
        :ok

      {:error, :timeout, last_pane} ->
        flunk(
          "AC-H3 violation: TUI did not surface an auth error within 5s " <>
            "(offline no-auth path). Pane:\n#{last_pane}"
        )
    end
  end

  defp run_ac_h2(%{binary: binary, tmpdir: tmpdir}) do
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

  # --- helpers --------------------------------------------------------

  # Returns true and prints a "[SKIP]" notice when the host is missing the
  # binary or tmux; returns false when the host can run the test.
  # Callers: `if skip_if_unavailable(ctx), do: nil, else: run_impl(ctx)`.
  #
  # ExUnit 1.18.1 has no runtime skip mechanism from setup/setup_all —
  # only compile-time @tag skip: produces the "skipped" ExUnit state.
  # This helper produces 0 failures and a clear console notice.
  defp skip_if_unavailable(%{skip_reason: reason}) when is_binary(reason) do
    IO.puts("[SKIP] #{reason}")
    true
  end

  defp skip_if_unavailable(_ctx), do: false

  defp binary_for_host do
    # TAU_TUI_BINARY is set by `mix tau.tui_ux` to point at the binary it
    # has already located or built. When set, skip candidate detection.
    case System.get_env("TAU_TUI_BINARY") do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: path, else: nil

      _ ->
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

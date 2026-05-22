if Code.ensure_loaded?(Ratatouille.Runtime) do
  defmodule Tau.TUI.PermissionDialogTest do
    @moduledoc """
    Gating tests for #341 PR-B — the TUI permission-prompt surface
    (SPEC-PERMISSION-PROMPTS §7, PR-B acceptance criteria AC-B1..AC-B8).

    These tests drive the **user-facing MVU path**: `Tau.TUI.App.update/2`
    with realistic `%PermissionRequest{}` event structs and realistic
    termbox key events, plus `Tau.TUI.App.render/1` /
    `Tau.TUI.StatusBar.render_text/1` for the render-assertion ACs.

    They are written BEFORE the PR-B implementation exists and are
    expected to FAIL until the implementer adds:

      * the `pending_permissions` model field + `%PermissionRequest{}`
        `update/2` clause (AC-B1..AC-B4, AC-B8);
      * the back-tab `update/2` clause cycling `permissions_mode`
        (AC-B6, AC-B7);
      * the ` mode: <mode>` `StatusBar` segment (AC-B5).

    AC-B9 is a `(meta)` criterion (`RuntimeOpts` plumbing, verified by
    inspection + the `tau tui` smoke path) and has NO gating test here,
    per the factory-loop meta-AC exemption.

    SPEC GAP — back-tab keycode (AC-B6 / AC-B7): the exact termbox
    keycode delivered for the `Shift+Tab` (back-tab) key cannot be
    determined from the repository. Upstream termbox defines
    `TB_KEY_BACK_TAB = 0xFFFF - 21 = 65514`, but `lib/tau/tui/app.ex`
    already binds `65514` to arrow-right (`move_char_right`). The PR-B
    draft body itself states the keycode "MUST be confirmed by a tmux
    probe before coding". The AC-B6/AC-B7 tests below therefore drive a
    `@back_tab_event` placeholder shape; the implementer MUST reconcile
    that shape with the probed keycode (and either correct this constant
    via the challenge protocol, or wire `update/2` to match it). The
    tests still fail-before regardless: no back-tab clause exists yet.
    """
    use ExUnit.Case, async: false

    alias Tau.Session.Events
    alias Tau.TUI.App
    alias Tau.TUI.Editor
    alias Tau.TUI.History
    alias Tau.TUI.StatusBar

    # Realistic MVU model — mirrors test/tau/tui/app_test.exs `model/0`,
    # extended with the PR-B fields the dialog/indicator read. A
    # fresh-from-`init` model would already carry these once PR-B lands;
    # seeding them here keeps the tests honest about the field names.
    defp model(overrides \\ %{}) do
      base = %{
        session_id: "sess-test",
        editor: Editor.new(),
        history: History.new(),
        search: nil,
        history_data_dir: System.tmp_dir!(),
        history_cwd: File.cwd!(),
        transcript: [],
        subagents: %{},
        status: :idle,
        last_assistant: nil,
        wrap_width: 80,
        coding_agent: nil,
        catalog: nil,
        menu: nil,
        # PR-B model fields (do not exist on the pre-PR-B model).
        pending_permissions: [],
        permissions_mode: :default
      }

      Map.merge(base, overrides)
    end

    # Realistic %PermissionRequest{} as broadcast by the FSM (SPEC §4 B2).
    defp permission_request(tool_call_id, name, args \\ %{}) do
      %Events.PermissionRequest{
        session_id: "sess-test",
        tool_call_id: tool_call_id,
        name: name,
        arguments: args,
        decision_reason: "Tool not matched by any allow rule in current mode."
      }
    end

    # Realistic termbox key events. Printable keys: %{key: 0, ch: CP, mod: 0}.
    # Special/control keys carry a non-zero :key and ch: 0.
    defp key_event(fields), do: {:event, Map.merge(%{key: 0, ch: 0, mod: 0}, fields)}

    # SPEC GAP placeholder — see @moduledoc. The implementer reconciles this
    # with the tmux-probed back-tab keycode.
    @back_tab_event {:event, %{key: :back_tab, ch: 0, mod: 0}}

    # Render the App view tree to a flat list of all label content strings,
    # so a test can assert dialog text appears somewhere in the frame.
    defp render_texts(model) do
      model
      |> App.render()
      |> collect_strings()
    end

    defp collect_strings(node) when is_binary(node), do: [node]

    defp collect_strings(%{} = node) do
      attrs = Map.get(node, :attributes, %{})
      children = Map.get(node, :children, [])

      from_attrs =
        attrs
        |> Map.values()
        |> Enum.flat_map(&collect_strings/1)

      [Map.get(attrs, :content)]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(from_attrs)
      |> Kernel.++(Enum.flat_map(children, &collect_strings/1))
    end

    defp collect_strings(list) when is_list(list),
      do: Enum.flat_map(list, &collect_strings/1)

    defp collect_strings(_other), do: []

    # ------------------------------------------------------------------
    # AC-B1 — a %PermissionRequest{} renders a permission dialog naming
    # the tool and offering allow/deny, before any tool output renders.
    # ------------------------------------------------------------------
    describe "AC-B1 — permission dialog renders on %PermissionRequest{}" do
      @tag :ac_b1
      test "AC-B1: %PermissionRequest{} queues the request and render/1 shows the dialog" do
        m = model()
        event = permission_request("tc-1", "Bash", %{"command" => "ls -la"})

        next = App.update(m, event)

        assert next.pending_permissions != [],
               "AC-B1: a %PermissionRequest{} MUST be queued onto model.pending_permissions; " <>
                 "got: #{inspect(next.pending_permissions)}"

        frame = render_texts(next)
        joined = Enum.join(frame, "\n")

        assert String.contains?(joined, "Bash"),
               "AC-B1: the rendered permission dialog MUST name the tool (Bash); " <>
                 "frame: #{inspect(frame)}"

        assert String.contains?(joined, "allow") and String.contains?(joined, "deny"),
               "AC-B1: the dialog MUST offer allow/deny options; frame: #{inspect(frame)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B2 — `y` resolves the head request with :allow_once and pops it.
    # ------------------------------------------------------------------
    describe "AC-B2 — `y` allows the head request" do
      @tag :ac_b2
      test "AC-B2: `y` key with dialog open pops the head request (allow_once)" do
        m =
          model()
          |> App.update(permission_request("tc-allow", "Bash"))

        assert length(m.pending_permissions) == 1,
               "precondition: one request queued; got #{inspect(m.pending_permissions)}"

        # Realistic printable key event for `y`.
        next = App.update(m, key_event(%{ch: ?y}))

        assert next.pending_permissions == [],
               "AC-B2: pressing `y` MUST resolve (allow_once) and pop the head request; " <>
                 "got: #{inspect(next.pending_permissions)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B3 — `n` resolves the head request with :deny_once and pops it.
    # ------------------------------------------------------------------
    describe "AC-B3 — `n` denies the head request" do
      @tag :ac_b3
      test "AC-B3: `n` key with dialog open pops the head request (deny_once)" do
        m =
          model()
          |> App.update(permission_request("tc-deny", "Write"))

        assert length(m.pending_permissions) == 1,
               "precondition: one request queued; got #{inspect(m.pending_permissions)}"

        next = App.update(m, key_event(%{ch: ?n}))

        assert next.pending_permissions == [],
               "AC-B3: pressing `n` MUST resolve (deny_once) and pop the head request; " <>
                 "got: #{inspect(next.pending_permissions)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B4 — while the dialog is open, a printable keystroke does NOT
    # reach the prompt/input editor; the modal captures all input.
    # ------------------------------------------------------------------
    describe "AC-B4 — open dialog captures all input" do
      @tag :ac_b4
      test "AC-B4: `h` keystroke with dialog open does not reach the input editor" do
        m =
          model(%{editor: Editor.new()})
          |> App.update(permission_request("tc-capture", "Bash"))

        assert m.pending_permissions != [],
               "precondition: dialog is open"

        next = App.update(m, key_event(%{ch: ?h}))

        assert Editor.text(next.editor) == "",
               "AC-B4: while the permission dialog is open, a printable keystroke MUST NOT " <>
                 "leak into the input editor; got editor text: #{inspect(Editor.text(next.editor))}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B5 — StatusBar.render_text/1 includes a ` mode: <mode>` segment
    # reflecting the model's permissions_mode.
    # ------------------------------------------------------------------
    describe "AC-B5 — status bar shows the permissions mode" do
      @tag :ac_b5
      test "AC-B5: render_text/1 includes a `mode: <mode>` segment for permissions_mode" do
        text =
          %{
            session_id: "sess-test",
            model: "claude-opus-4-7",
            provider: Tau.Providers.Anthropic,
            usage: %{input_tokens: 0, output_tokens: 0, cache_read: 0, cache_write: 0},
            context_tokens: 0,
            context_window: 200_000,
            compaction: :idle,
            status: :idle,
            coding_agent_label: nil,
            permissions_mode: :accept_edits
          }
          |> StatusBar.render_text()

        assert String.contains?(text, "mode: accept_edits"),
               "AC-B5: the status bar MUST carry a `mode: <permissions_mode>` segment; " <>
                 "got: #{inspect(text)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B6 — back-tab cycles permissions_mode
    # :default -> :accept_edits -> :plan -> :default.
    # (SPEC GAP on the back-tab keycode — see @moduledoc.)
    # ------------------------------------------------------------------
    describe "AC-B6 — back-tab cycles the permissions mode" do
      @tag :ac_b6
      test "AC-B6: back-tab cycles :default -> :accept_edits -> :plan -> :default" do
        m0 = model(%{permissions_mode: :default, status: :idle})

        m1 = App.update(m0, @back_tab_event)

        assert m1.permissions_mode == :accept_edits,
               "AC-B6: back-tab from :default MUST move to :accept_edits; " <>
                 "got: #{inspect(m1.permissions_mode)}"

        m2 = App.update(m1, @back_tab_event)

        assert m2.permissions_mode == :plan,
               "AC-B6: back-tab from :accept_edits MUST move to :plan; " <>
                 "got: #{inspect(m2.permissions_mode)}"

        m3 = App.update(m2, @back_tab_event)

        assert m3.permissions_mode == :default,
               "AC-B6: back-tab from :plan MUST wrap back to :default; " <>
                 "got: #{inspect(m3.permissions_mode)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B7 — back-tab while streaming does NOT change the displayed mode
    # (the FSM rejects the change :busy, D-096); it works again once idle.
    # ------------------------------------------------------------------
    describe "AC-B7 — back-tab is inert mid-turn" do
      @tag :ac_b7
      test "AC-B7: back-tab while :streaming does not move the mode; works again when :idle" do
        streaming = model(%{permissions_mode: :default, status: :streaming})

        mid_turn = App.update(streaming, @back_tab_event)

        assert mid_turn.permissions_mode == :default,
               "AC-B7: back-tab while :streaming MUST NOT change the displayed mode " <>
                 "(FSM rejects :busy per D-096); got: #{inspect(mid_turn.permissions_mode)}"

        # After the turn ends the cycle works again.
        idle = %{mid_turn | status: :idle}
        resumed = App.update(idle, @back_tab_event)

        assert resumed.permissions_mode == :accept_edits,
               "AC-B7: once status is :idle, back-tab MUST cycle the mode again; " <>
                 "got: #{inspect(resumed.permissions_mode)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B8 — two %PermissionRequest{} events queue: the dialog shows the
    # first; resolving it reveals the second; resolving both clears it.
    # ------------------------------------------------------------------
    describe "AC-B8 — multiple requests queue and resolve in order" do
      @tag :ac_b8
      test "AC-B8: two requests queue; resolving the head reveals the second" do
        m =
          model()
          |> App.update(permission_request("tc-first", "Bash"))
          |> App.update(permission_request("tc-second", "Write"))

        assert length(m.pending_permissions) == 2,
               "AC-B8: two %PermissionRequest{} events MUST both queue; " <>
                 "got: #{inspect(m.pending_permissions)}"

        # The dialog shows the FIRST request.
        first_frame = Enum.join(render_texts(m), "\n")

        assert String.contains?(first_frame, "Bash"),
               "AC-B8: the dialog MUST show the first queued request (Bash); " <>
                 "frame: #{inspect(first_frame)}"

        # Resolve the head — the second request is revealed.
        after_first = App.update(m, key_event(%{ch: ?y}))

        assert length(after_first.pending_permissions) == 1,
               "AC-B8: resolving the head MUST leave exactly one request queued; " <>
                 "got: #{inspect(after_first.pending_permissions)}"

        second_frame = Enum.join(render_texts(after_first), "\n")

        assert String.contains?(second_frame, "Write"),
               "AC-B8: after resolving the first, the dialog MUST show the second " <>
                 "request (Write); frame: #{inspect(second_frame)}"

        # Resolve the second — the dialog clears.
        after_second = App.update(after_first, key_event(%{ch: ?n}))

        assert after_second.pending_permissions == [],
               "AC-B8: resolving both requests MUST clear the dialog; " <>
                 "got: #{inspect(after_second.pending_permissions)}"
      end
    end
  end
end

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
      * the `/perms <mode>` slash command that sets `permissions_mode`
        via `set_permissions_mode/2` (AC-B6, AC-B7);
      * the ` mode: <mode>` `StatusBar` segment (AC-B5).

    AC-B9 is a `(meta)` criterion (`RuntimeOpts` plumbing, verified by
    inspection + the `tau tui` smoke path) and has NO gating test here,
    per the factory-loop meta-AC exemption.

    Mode-change mechanism (AC-B6 / AC-B7): the original `Shift+Tab`
    cycle is **infeasible** — an empirical tmux probe confirmed termbox
    delivers `Shift+Tab` (`CSI Z`) as three separate events (`ESC` `[`
    `Z`), and the `ESC` functionally collides with cancel/clear. The
    mode-change mechanism is therefore the **`/perms <mode>`** slash
    command (`mode ∈ {default, accept_edits, plan}`). The AC-B6/AC-B7
    tests below drive the user-facing path: realistic printable-char
    key events that type `/perms <mode>` into the input editor followed
    by an Enter key event — exactly as a user submits a slash command.
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

    # Enter (Return) — termbox control-key shape: key=13, ch=0, mod=0.
    @enter_event {:event, %{key: 13, ch: 0, mod: 0}}

    # Type a string into the model via the real update/2 key path, one
    # printable-char event per codepoint — exactly as a user types. Space
    # is a termbox quirk (key=32, ch=0) and is handled accordingly.
    defp type_text(model, text) do
      text
      |> String.to_charlist()
      |> Enum.reduce(model, fn cp, m ->
        event =
          if cp == ?\s do
            key_event(%{key: 32, ch: 0})
          else
            key_event(%{ch: cp})
          end

        App.update(m, event)
      end)
    end

    # Type `/perms <mode>` then submit with Enter — the user-facing path
    # for the mode-change slash command.
    defp run_perms_command(model, arg) do
      command = if arg == "", do: "/perms", else: "/perms " <> arg

      model
      |> type_text(command)
      |> App.update(@enter_event)
    end

    # Stand in for the session FSM at a given `session_id`. The real
    # `Tau.Session.decide_permission/3` resolves the id through
    # `Tau.Sessions.Registry` (`:unique`) and then `:gen_statem.cast`s
    # `{:permission_decision, tool_call_id, verdict}` to the registered pid
    # (SPEC-PERMISSION-PROMPTS §4 B5 / D-096). `:gen_statem.cast/2` delivers
    # the payload as a `{:"$gen_cast", msg}` message. This stub registers
    # itself under that `session_id` and forwards every `:gen_statem` cast it
    # receives to the test process, so the test can `assert_receive` the
    # *actual verdict* that reached the session — not merely the popped queue.
    #
    # The stub's PID is registered as the session, so the cast genuinely
    # traverses the registry-lookup + cast path the production code uses.
    defp start_session_stub(session_id) do
      test_pid = self()

      stub =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Tau.Sessions.Registry, session_id, nil)
          send(test_pid, {:stub_registered, session_id})
          stub_loop(test_pid)
        end)

      # Block until the stub has registered, so `decide_permission/3` cannot
      # race ahead of the registration and observe `{:error, :not_found}`.
      receive do
        {:stub_registered, ^session_id} -> :ok
      after
        1_000 -> flunk("session stub failed to register under #{inspect(session_id)}")
      end

      stub
    end

    defp stub_loop(test_pid) do
      receive do
        {:"$gen_cast", payload} ->
          send(test_pid, {:session_cast, payload})
          stub_loop(test_pid)

        _other ->
          stub_loop(test_pid)
      end
    end

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
    #
    # The substantive half of this AC is the *verdict*: `y` MUST send
    # `:allow_once` to the session. Popping the queue is necessary but not
    # sufficient — a verdict-swapped implementation (`y` → `:deny_once`) also
    # pops the head. To make the verdict observable, a `start_session_stub/1`
    # process is registered under the model's `session_id`; the real
    # `Tau.Session.decide_permission/3` then casts the verdict to that stub,
    # which forwards it here. `assert_receive {:session_cast, ...}` therefore
    # fails iff the implementation sends anything other than `:allow_once`.
    # ------------------------------------------------------------------
    describe "AC-B2 — `y` allows the head request" do
      @tag :ac_b2
      test "AC-B2: `y` key sends :allow_once to the session and pops the head request" do
        session_id = "sess-ac-b2-#{System.unique_integer([:positive])}"
        _stub = start_session_stub(session_id)

        m =
          model(%{session_id: session_id})
          |> App.update(permission_request("tc-allow", "Bash"))

        assert length(m.pending_permissions) == 1,
               "precondition: one request queued; got #{inspect(m.pending_permissions)}"

        # Realistic printable key event for `y`.
        next = App.update(m, key_event(%{ch: ?y}))

        assert next.pending_permissions == [],
               "AC-B2: pressing `y` MUST resolve and pop the head request; " <>
                 "got: #{inspect(next.pending_permissions)}"

        # The substantive assertion: the verdict that reached the session is
        # `:allow_once`, carrying the head request's tool_call_id. This fails
        # if the implementation sends `:deny_once` (verdict swap) instead.
        assert_receive {:session_cast, {:permission_decision, "tc-allow", :allow_once}},
                       1_000,
                       "AC-B2: pressing `y` MUST send {:permission_decision, \"tc-allow\", " <>
                         ":allow_once} to the session via decide_permission/3; no such cast " <>
                         "was observed (a `:deny_once` verdict, or no cast at all, would " <>
                         "fail this assertion)."
      end
    end

    # ------------------------------------------------------------------
    # AC-B3 — `n` resolves the head request with :deny_once and pops it.
    #
    # Mirror of AC-B2: the substantive half is the verdict. `n` MUST send
    # `:deny_once` to the session. The `start_session_stub/1` process makes
    # the cast observable; the `assert_receive` below fails iff the
    # implementation sends anything other than `:deny_once` (in particular a
    # verdict swap `n` → `:allow_once`).
    # ------------------------------------------------------------------
    describe "AC-B3 — `n` denies the head request" do
      @tag :ac_b3
      test "AC-B3: `n` key sends :deny_once to the session and pops the head request" do
        session_id = "sess-ac-b3-#{System.unique_integer([:positive])}"
        _stub = start_session_stub(session_id)

        m =
          model(%{session_id: session_id})
          |> App.update(permission_request("tc-deny", "Write"))

        assert length(m.pending_permissions) == 1,
               "precondition: one request queued; got #{inspect(m.pending_permissions)}"

        next = App.update(m, key_event(%{ch: ?n}))

        assert next.pending_permissions == [],
               "AC-B3: pressing `n` MUST resolve and pop the head request; " <>
                 "got: #{inspect(next.pending_permissions)}"

        # The substantive assertion: the verdict that reached the session is
        # `:deny_once`, carrying the head request's tool_call_id. This fails
        # if the implementation sends `:allow_once` (verdict swap) instead.
        assert_receive {:session_cast, {:permission_decision, "tc-deny", :deny_once}},
                       1_000,
                       "AC-B3: pressing `n` MUST send {:permission_decision, \"tc-deny\", " <>
                         ":deny_once} to the session via decide_permission/3; no such cast " <>
                         "was observed (an `:allow_once` verdict, or no cast at all, would " <>
                         "fail this assertion)."
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
    # AC-B6 — typing `/perms <mode>` + Enter sets permissions_mode via
    # set_permissions_mode/2; an unknown/empty argument is a no-op that
    # reports the current mode + valid set (no crash, no mode change).
    # ------------------------------------------------------------------
    describe "AC-B6 — `/perms <mode>` sets the permissions mode" do
      @tag :ac_b6
      test "AC-B6: `/perms accept_edits` + Enter sets permissions_mode to :accept_edits" do
        m0 = model(%{permissions_mode: :default, status: :idle})

        next = run_perms_command(m0, "accept_edits")

        assert next.permissions_mode == :accept_edits,
               "AC-B6: typing `/perms accept_edits` + Enter MUST set permissions_mode " <>
                 "to :accept_edits via set_permissions_mode/2; " <>
                 "got: #{inspect(next.permissions_mode)}"
      end

      @tag :ac_b6
      test "AC-B6: `/perms plan` + Enter sets permissions_mode to :plan" do
        m0 = model(%{permissions_mode: :default, status: :idle})

        next = run_perms_command(m0, "plan")

        assert next.permissions_mode == :plan,
               "AC-B6: typing `/perms plan` + Enter MUST set permissions_mode to :plan; " <>
                 "got: #{inspect(next.permissions_mode)}"
      end

      @tag :ac_b6
      test "AC-B6: `/perms default` + Enter sets permissions_mode back to :default" do
        # Start from a non-default mode so the transition is observable.
        m0 = model(%{permissions_mode: :accept_edits, status: :idle})

        next = run_perms_command(m0, "default")

        assert next.permissions_mode == :default,
               "AC-B6: typing `/perms default` + Enter MUST set permissions_mode to :default; " <>
                 "got: #{inspect(next.permissions_mode)}"
      end

      @tag :ac_b6
      test "AC-B6: `/perms` with no argument is a no-op that reports the current mode + valid set" do
        m0 = model(%{permissions_mode: :accept_edits, status: :idle})

        next = run_perms_command(m0, "")

        assert is_map(next),
               "AC-B6: `/perms` with no argument MUST NOT crash the update loop"

        assert next.permissions_mode == :accept_edits,
               "AC-B6: `/perms` with no argument MUST NOT change the mode; " <>
                 "got: #{inspect(next.permissions_mode)}"

        # The no-arg form is not silent: it reports the current mode and the
        # valid set. The only user-visible sink on the pure update/2 path is
        # the transcript, so the report MUST land there.
        report = Enum.map_join(next.transcript, "\n", fn {text, _attrs} -> text end)

        assert String.contains?(report, "accept_edits"),
               "AC-B6: `/perms` (no arg) MUST report the current mode (accept_edits) " <>
                 "in the transcript; got transcript: #{inspect(next.transcript)}"

        assert String.contains?(report, "default") and String.contains?(report, "plan"),
               "AC-B6: `/perms` (no arg) MUST report the valid mode set " <>
                 "({default, accept_edits, plan}); got transcript: #{inspect(next.transcript)}"
      end

      @tag :ac_b6
      test "AC-B6: `/perms bogus` (invalid argument) is a no-op that reports the current mode + valid set" do
        m0 = model(%{permissions_mode: :default, status: :idle})

        next = run_perms_command(m0, "bogus")

        assert is_map(next),
               "AC-B6: `/perms bogus` MUST NOT crash the update loop"

        assert next.permissions_mode == :default,
               "AC-B6: `/perms bogus` (unknown mode) MUST NOT change the mode; " <>
                 "got: #{inspect(next.permissions_mode)}"

        # An unknown argument is reported, not silently swallowed: the report
        # names the current mode and the valid set.
        report = Enum.map_join(next.transcript, "\n", fn {text, _attrs} -> text end)

        assert String.contains?(report, "default"),
               "AC-B6: `/perms bogus` MUST report the current mode (default) " <>
                 "in the transcript; got transcript: #{inspect(next.transcript)}"

        assert String.contains?(report, "accept_edits") and String.contains?(report, "plan"),
               "AC-B6: `/perms bogus` MUST report the valid mode set " <>
                 "({default, accept_edits, plan}); got transcript: #{inspect(next.transcript)}"
      end
    end

    # ------------------------------------------------------------------
    # AC-B7 — `/perms <mode>` while streaming does NOT change the mode
    # (the FSM rejects set_permissions_mode :busy, D-096); it works again
    # once the turn ends.
    # ------------------------------------------------------------------
    describe "AC-B7 — `/perms <mode>` is inert mid-turn" do
      @tag :ac_b7
      test "AC-B7: `/perms accept_edits` while :streaming does not move the mode; works when :idle" do
        streaming = model(%{permissions_mode: :default, status: :streaming})

        mid_turn = run_perms_command(streaming, "accept_edits")

        assert mid_turn.permissions_mode == :default,
               "AC-B7: `/perms accept_edits` while :streaming MUST NOT change the mode " <>
                 "(FSM rejects set_permissions_mode :busy per D-096); " <>
                 "got: #{inspect(mid_turn.permissions_mode)}"

        # After the turn ends the command works again.
        idle = model(%{permissions_mode: :default, status: :idle})
        resumed = run_perms_command(idle, "accept_edits")

        assert resumed.permissions_mode == :accept_edits,
               "AC-B7: once status is :idle, `/perms accept_edits` MUST set the mode again; " <>
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

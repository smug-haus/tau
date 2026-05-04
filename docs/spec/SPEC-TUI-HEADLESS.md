# SPEC: Headless TUI testing

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-05-04 |
| **Scope** | Reliable, repeatable, CI-runnable verification of `tau tui` end-to-end against the prod Burrito binary, with no human-in-the-loop terminal. |
| **Method** | PSDH spike + design. Spike conducted 2026-05-04; results in §3 and Appendix A. |
| **Companion** | `docs/spec/SPEC-USER-TURN.md` — AC-1 / AC-2 / AC-3 / AC-4 / AC-7 from that SPEC are the contracts this one operationalises. |

## 0. Why this spec exists

The prior alignment doc (`docs/MISSION.md`) recorded an unproven claim
that "the TUI cannot be tested without a real terminal." A 2026-05-04
spike falsified that claim. Pseudo-terminal driving via `tmux` is
reliable, captures full ANSI output including alt-screen contents, and
delivers keystrokes that the Ratatouille runtime processes. Without a
specified harness, every "is the TUI working?" question is a
human-in-the-loop discovery; with one, AC-1..AC-4 become CI-blockable
gates.

This SPEC defines the harness, its API, and the acceptance contracts.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | tmpdir for `~/.tau` per run; PTY buffer; tmux pane state; binary's `data_dir` |
| 2 | Temporal coupling | 1 | bytes must arrive AFTER alt-screen activation; assertion must wait for re-render before sampling |
| 3 | Cross-process coordination | 1 | test process ↔ tmux server ↔ shell ↔ binary ↔ Ratatouille runtime ↔ session FSM |
| 4 | Feedback loops | 0 | one-shot test invocation; no loop on output |
| 5 | State accumulation | 1 | session JSONL written to test tmpdir; pane history in tmux |

**Triage score: 4/5. L0 indicated.**

## 2. Component decomposition

| # | Boundary | Operation |
|---|----------|-----------|
| H1 | ExUnit test ↔ harness helper | `start/2`, `send/2`, `await/3`, `capture/1`, `quit/1` |
| H2 | Helper ↔ tmux server | `tmux new-session`, `send-keys`, `capture-pane`, `kill-session` |
| H3 | tmux pane ↔ binary | PTY (line discipline off; raw input passthrough once Ratatouille subscribes) |
| H4 | Binary ↔ session FSM ↔ provider | exists in SPEC-USER-TURN scope; harness only observes via PTY rendering |
| H5 | Test ↔ filesystem | `TAU_DATA_DIR=<tmp>` to isolate session JSONL writes |

## 3. L0 — non-obvious constraints from the spike

★ marks non-obvious from a normal-speed read.

### Q1: What can be written by more than one actor?

- **★ [HC1-H5]** `~/.tau/sessions/<sid>.jsonl` is written by the binary's
  session FSM. Multiple concurrent harness runs in the same `cwd`
  collide on the same path hash bucket. Tests MUST set a unique
  `TAU_DATA_DIR` per run.
- **[HC2-H2]** tmux server is shared per user. Two parallel test runs
  using identical session names collide. MUST scope session names by
  PID + monotonic counter.

### Q2: What ordering assumptions are implicit?

- **★ [HC3-H3]** The binary takes ~2s after launch to reach the point
  where Ratatouille has installed its keyboard handler. Keystrokes sent
  before that moment are consumed by the line-disciplined parent shell,
  not the TUI. Spike confirmed: piping `hi\nq` over stdin echoed in the
  pane *before* alt-screen activated and was never seen as keystrokes.
  Harness MUST wait for an "alt-screen entered" signal (presence of
  `[?1049h` in pane output OR a fixed minimum delay) before the first
  `send-keys`.
- **★ [HC4-H3]** After a `send-keys`, the renderer's next frame cycle
  may be up to one tick interval (~250ms per `Tau.TUI.App.@tick_interval`).
  Assertions on rendered content MUST poll with a backoff up to a
  configurable max wait, not single-shot capture.

### Q3: What happens if a component fails silently?

- **★ [HC5-H4]** Spike observed: TUI rendered, accepted "hi", status
  transitioned to "sending" — but no assistant response appeared in the
  transcript pane and no error appeared either. This is the actual
  TUI-broken symptom and corresponds to SPEC-USER-TURN [C12]/[C19] (the
  `error_message` lost between Session and TUI render). Headless tests
  detect this by asserting that within `T_max` after submit, the
  transcript pane contains either a `[assistant] ...` line OR a line
  matching `Error|auth|expired`.
- **[HC6-H2]** A tmux session that exits cleanly via `q` cannot be
  capture-pane'd afterwards (the session is gone). Harness MUST capture
  immediately before sending the quit key, or use `tmux capture-pane`
  with `-S` history before sending.
- **★ [HC7-H4]** Ratatouille 0.5.1 + Elixir 1.18.1: render path emits
  `Range.new/2 default step -1` warnings from `Box.contains?/2`,
  `Canvas.merge_cells/2`, `Label.render/3`, `Line.render/5`,
  `Border.render/1`, `Panel.render/3`. The render still completes (the
  pane shows the expected layout in the spike), but stderr is noisy.
  This is a **separate dependency-side bug**, tracked independently;
  the headless harness MUST tolerate it (suppress stderr or filter
  expected warnings) but MUST NOT mask actual rendering errors.

### Q4: What information crosses a boundary, and what is lost?

- **★ [HC8-H3]** ANSI escape sequences carry layout. Stripping ANSI for
  text assertions loses cursor positioning; `tmux capture-pane -p`
  flattens pane state to plain text already. Use `-p` for textual
  assertions; use raw `script`-style logs only when the assertion
  requires escape-sequence verification (e.g., "alt-screen activated").
- **[HC9-H2]** `tmux capture-pane -p -S -<n>` returns the last n lines
  of pane history. Lines that scrolled off before n must be captured
  earlier — harness's `await/3` MUST sample at intervals, not one-shot
  at the end.

### Q5: What feedback loops exist?

- **[HC10-H4]** A bug in the renderer that loops without yielding
  (e.g., infinite re-render) would consume CPU forever. Harness
  enforces a hard timeout on every `start/2` invocation.

### Q6: What must be true before and after each phase?

| Transition | PRE | POST |
|---|---|---|
| `start/2 → ready` | tmux available; binary path exists; tmpdir created | session active; alt-screen detected; first `await/3` valid |
| `send/2 → delivered` | session in `ready`; key buffer not full | bytes injected; subsequent `await` may observe re-render |
| `await/3 → match` | session in `ready` | matched substring present; pane snapshot returned |
| `quit/1 → done` | session in `ready` | tmux session killed; tmpdir cleaned; binary exit code captured |

### Q7: Protocol — out-of-order arrival

- **★ [HC11-H3]** `send-keys` is non-blocking. Two `send-keys` calls in
  rapid succession can race the renderer's input read. Harness's `send/2`
  takes an optional `:settle_ms` (default 50ms) and sleeps after the
  send to let the renderer drain.
- **[HC12]** A test that sends a complete prompt then immediately quits
  may quit before the FSM has cast the user message. The send-quit
  sequence MUST observe at least one re-render between input and quit.

### Q8: Cross-cutting changes

- **[HC13]** Changes to `Tau.TUI.App.@tick_interval` invalidate
  harness's default poll cadence. Harness derives its poll interval
  from a centralized config so a future tick change cascades.

## 4. Boundary contracts

### H1 — ExUnit ↔ Harness helper

```elixir
@spec start(binary_path :: Path.t(), opts :: keyword()) :: {:ok, session()} | {:error, term()}
# opts:
#   :env             — env vars for the binary (e.g., TAU_DATA_DIR)
#   :args            — argv (default ["tui"])
#   :ready_timeout_ms — wait for alt-screen activation (default 5000)
#   :geometry        — {cols, rows} (default {200, 50})

@spec send(session(), input :: iodata() | atom()) :: :ok
# atoms: :enter, :escape, :ctrl_c, :tab, :backspace

@spec await(session(), match :: String.t() | Regex.t(), opts :: keyword()) ::
        {:ok, pane_text :: String.t()} | {:error, :timeout, last_pane :: String.t()}
# opts:
#   :timeout_ms      — total wait (default 10_000)
#   :poll_ms         — poll interval (default 250)

@spec capture(session()) :: {:ok, pane_text :: String.t()}
@spec quit(session()) :: {:ok, exit_code :: integer()} | {:error, term()}
```

PRE: every test MUST `start/2` before any other call. POST: every
`start/2` MUST be paired with `quit/1` or test cleanup, even on
assertion failure (use `on_exit/1`).

### H2 — Harness ↔ tmux

The harness shells out to `tmux` (subprocess via `System.cmd/3`). It
does NOT speak the tmux control-mode protocol. Rationale: shell
operations are simpler, no library dependency, easy to inspect manually
during failures.

INV: tmux session names are namespaced as `tau-tui-<pid>-<counter>` so
parallel test workers don't collide.

### H3 — tmux pane ↔ binary

PRE for `send-keys`: alt-screen has been entered (detected via
`capture-pane` returning ANSI `[?1049h` OR pane width matches the
binary's expected status bar). POST: bytes are pending delivery to the
binary — visibility happens on the next render tick.

## 5. PSDH catalog (D-xxx) — runtime invariants

Continuing the namespace from `SPEC-USER-TURN.md` (which holds D-001 –
D-019). New entries here:

| ID | Statement | Severity | Detection | Source |
|---|---|---|---|---|
| D-020 | Headless harness MUST wait for alt-screen activation before first `send-keys`; pre-activation bytes are silently dropped. | high | unit test: send before activation; assert pane does not contain those bytes after re-render | [HC3] |
| D-021 | Harness `await/3` MUST poll with backoff, not single-shot capture; renderer tick is up to 250ms. | medium | unit test: assert `await/3` succeeds when content appears after first poll | [HC4] |
| D-022 | Each harness session MUST run with a per-run `TAU_DATA_DIR`; default-data-dir collides across parallel tests. | high | unit test: two parallel harness starts; assert distinct session JSONL paths | [HC1] |
| D-023 | Harness MUST capture pane state before sending a quit-event keystroke; post-quit panes are unreadable. | medium | unit test: send quit; assert capture-pane after quit returns empty | [HC6] |
| D-024 | `tmux send-keys` callers MUST settle (≥50ms) before the next send-keys; back-to-back sends race the renderer's input read. | medium | unit test: rapid 5-key send; assert all keys observed in next render | [HC11] |
| D-025 | Harness MUST treat the Ratatouille 0.5.1 / Elixir 1.18.1 render warnings as expected stderr; assertions on stderr MUST filter them. | low | unit test: capture stderr; assert filtered output is empty when binary runs cleanly | [HC7] |

## 6. Acceptance criteria — what the harness lets us verify

These map directly to SPEC-USER-TURN AC-1..AC-4 and AC-7. Each becomes
a runnable ExUnit test using the harness from §4.

### AC-H1: First-run smoke (mirrors AC-1)

`start/2` against a fresh `TAU_DATA_DIR`. Within 5 seconds:
- Pane contains `session: <ulid-pattern>` in the status bar.
- Pane contains `transcript` panel header.
- Pane contains `> ` prompt at the bottom.

### AC-H2: Single turn round-trip (mirrors AC-2)

`start/2` with `--provider replay` plumbed through to TUI session start
(requires a code change — see §8 deferred). Then `send "hello"`,
`send :enter`, `await/3` for `\\(replay\\)` within 30s. Status returns
to `idle`.

### AC-H3: Provider error visibility (mirrors AC-3)

`start/2` with empty `~/.tau` and unset auth. `send "hi"`, `send
:enter`, `await/3` for `Error|auth|expired` within 5s. Pane MUST NOT be
empty after submit.

### AC-H4: Quit ergonomics (mirrors AC-4)

`start/2`. `send "abc"` then `send "q"` — the q is part of input, must
not quit. Capture pane: prompt should show `> abcq`.

Then `send :enter` to clear (or backspace until empty). Then `send "q"`
on empty prompt — TUI MUST exit. Verify `quit/1` returns exit 0.

### AC-H7: Resume render

After AC-H2, take the session id from status bar. `quit/1`, then
`start/2` again with `args: ["resume", session_id]`. Pane MUST contain
the prior turn in the transcript.

## 7. Implementation surface

- `test/support/tui_pty_helper.ex` — module implementing §4 API. Runtime
  dependency: `tmux` on `$PATH`. Optional fallback to `expect` (deferred).
- `test/tau/cli/tui_smoke_test.exs` — AC-H1..AC-H4, AC-H7 implementations.
  Tagged `@tag :tui_smoke` so it can be skipped on hosts without tmux.
- `mix tau.tui_smoke` — convenience task wrapping the test tag.

CI: GitHub Actions Linux runners have tmux installed by default. macOS
runners need `brew install tmux` step. The smoke suite runs on every
PR that touches files in SPEC-USER-TURN Appendix B's source map.

## 8. Out-of-scope / deferred

- **Replay provider in TUI session-start:** Today `Tau.TUI.App.init/1`
  hard-codes `Tau.start_session(session_id: session_id)` (no provider
  override). AC-H2 needs a provider flag plumbed through. File a
  separate issue; harness's other ACs work without it.
- **Ratatouille 0.5.1 ↔ Elixir 1.18.1 Range warnings:** dependency-side
  bug. Track separately. Harness tolerates via D-025.
- **Visual regression:** comparing pane snapshots byte-for-byte against
  a fixture is a possible follow-on. v1 uses substring/regex matching.
- **Macros / chord input:** for now, harness sends one logical keystroke
  per `send/2`. No multi-key chord helper.

## 9. The change-process rule

Any PR that touches `lib/tau/tui/`, `lib/tau/cli.ex`, or
`Tau.TUI.App.@tick_interval` MUST run the AC-H suite locally and
include the output in the PR description. Critic and reviewer prompts
extend `spec-before-code.md` with: "did this PR run the AC-H suite?
Did any AC-H regress?"

## Appendix A — Spike record (2026-05-04)

Three probes against `burrito_out/tau_linux_arm64`:

**Probe 1 — `script` with no stdin:** TUI launches, alt-screen ANSI
emitted, render warnings observed. Process held until timeout
(`SIGTERM` from `timeout 5`). Captured 2087 bytes including alt-screen,
status bar, render warnings. **Conclusion:** PTY emulation works;
binary launches reach the runtime layer.

**Probe 2 — `script` with piped stdin (`hi\\nq`):** Stdin bytes echoed
to PTY before alt-screen activation. Bytes consumed by line discipline,
not by Ratatouille's keyboard reader. **Conclusion:** Stdin redirection
is unsuitable for interactive driving — pre-activation bytes are lost
([HC3] / D-020).

**Probe 3 — tmux `send-keys` with delays:**
```sh
tmux new-session -d -s tau-spike -x 200 -y 50 './tau_linux_arm64 tui'
sleep 4                                 # wait for alt-screen
tmux send-keys -t tau-spike 'hi'        # text input
sleep 1
tmux send-keys -t tau-spike Enter       # submit
sleep 3
tmux capture-pane -t tau-spike -p -S -50
```
Result: pane shows status bar (`session: 019df3c8-... | status: sending
| <Enter> submit · <Esc> cancel · <Ctrl-C> quit`), transcript panel
with `> hi`. Status is `sending` — `Tau.send/2` was invoked, FSM
transitioned to `:provider_streaming`. **No assistant response appeared
in the 3-second window after submit and no error either** — the actual
broken behaviour the user reports, matching SPEC-USER-TURN [C12]/[C19]
(error_message lost in render path). **Conclusion:** harness is
viable; the bug to fix in the user-turn loop is downstream of this
SPEC.

`q` keystroke after capture closed the tmux session immediately
(quit_events match), confirming the quit path.

## Appendix B — Source map

Files this SPEC touches (or proposes touching) on landing:

| Element | Source |
|---|---|
| `Tau.TUI.App.@tick_interval` | `lib/tau/tui/app.ex:16` |
| `Tau.TUI.App.init/1` | `lib/tau/tui/app.ex:18-37` |
| `Tau.TUI.App.run/0` quit_events | `lib/tau/tui/app.ex:115-119` |
| `Tau.Settings.data_dir` | reads `TAU_DATA_DIR` env or default |
| `Tau.Persistence.Jsonl.path_for/2` | `lib/tau/persistence/jsonl.ex:168-175` |
| Helper (proposed) | `test/support/tui_pty_helper.ex` |
| Smoke (proposed) | `test/tau/cli/tui_smoke_test.exs` |

# SPEC: TUI Behaviour and UX Testing Protocol (M1.1)

| | |
|---|---|
| **Status** | Approved |
| **Date** | 2026-05-04 (revised 2026-05-21 for M1.1) |
| **Scope** | The `tau tui` UX surface end-to-end: behaviour contracts for every user-visible TUI feature, plus a repeatable, CI-runnable UX testing protocol that exercises those features via the proven tmux-drive + pane-capture + screen-interpretation harness. |
| **Method** | PSDH spike + design. Spike conducted 2026-05-04; results in §3 and Appendix A. UX surface analysis conducted 2026-05-21 (competitive analysis against Pi and Claude Code). |
| **Companion** | `docs/spec/SPEC-USER-TURN.md` — AC-1 / AC-2 / AC-3 / AC-4 / AC-7 / AC-8 from that SPEC are the session-FSM contracts this SPEC operationalises at the UX layer. |
| **D-NNN block** | D-066–D-075 (this SPEC's exclusive allocation; see §5). |
| **Spec home for** | #335 (sub-agent visibility), #338 (input editor), #340 (status surfaces + `context_window/1`), #345 (themes/keybindings). Acceptance criteria in those issues map to protocol steps here. |

## 0. Why this spec exists

### 0.1 Original rationale (2026-05-04)

The prior alignment doc (`docs/MISSION.md`) recorded an unproven claim that
"the TUI cannot be tested without a real terminal." A 2026-05-04 spike falsified
that claim. Pseudo-terminal driving via `tmux` is reliable, captures full ANSI
output including alt-screen contents, and delivers keystrokes that the
Ratatouille runtime processes. Without a specified harness, every "is the TUI
working?" question is a human-in-the-loop discovery; with one, AC-1..AC-4 become
CI-blockable gates.

### 0.2 M1.1 re-charter (2026-05-21)

M1 (self-hosting) is complete. The factory loop's current objective is **M1.1 —
Minimum viable UX**. The coordinator has demonstrated in practice that it can
drive `tau tui` via tmux — type input, capture panes, interpret the rendered
screen — and exercise the TUI like a human operator. The prior assumption that
UX testing needs the human is removed.

This SPEC is re-chartered from a test-harness spec (AC-1..AC-7 only) into the
**M1.1 TUI behaviour + UX-testing-protocol** spec. It:

1. Defines behaviour contracts for the full UX surface (§6 AC catalog).
2. Gives each UX feature a protocol step with explicit pass/fail assertions
   exercised via the tmux harness (§7 UX protocol).
3. Becomes the spec-before-code gate for all PRs touching `lib/tau/tui/`
   (per `spec-before-code.md`).
4. Is the spec home for M1.1 child issues #335, #338, #340, #345.

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | tmpdir for `~/.tau` per run; PTY buffer; tmux pane state; binary's `data_dir`; TUI render state |
| 2 | Temporal coupling | 1 | bytes must arrive AFTER alt-screen activation; assertion must wait for re-render before sampling; input editor state changes are tick-driven |
| 3 | Cross-process coordination | 1 | test process ↔ tmux server ↔ shell ↔ binary ↔ Ratatouille runtime ↔ session FSM ↔ sub-agent processes |
| 4 | Feedback loops | 1 | sub-agent dispatch creates a feedback loop: TUI ↔ Session FSM ↔ sub-agent stdout ↔ render |
| 5 | State accumulation | 1 | session JSONL; pane history; input editor buffer; command history ring; status counters |

**Triage score: 5/5. L0 indicated.**

## 2. Component decomposition

| # | Boundary | Operation |
|---|----------|-----------|
| H1 | ExUnit test ↔ harness helper | `start/2`, `send/2`, `await/3`, `capture/1`, `quit/1` |
| H2 | Helper ↔ tmux server | `tmux new-session`, `send-keys`, `capture-pane`, `kill-session` |
| H3 | tmux pane ↔ binary | PTY (line discipline off; raw input passthrough once Ratatouille subscribes) |
| H4 | Binary ↔ session FSM ↔ provider | exists in SPEC-USER-TURN scope; harness observes via PTY rendering |
| H5 | Test ↔ filesystem | `TAU_DATA_DIR=<tmp>` to isolate session JSONL writes |
| H6 | Input editor ↔ Ratatouille event loop | keystroke events → editor state → render tick |
| H7 | Session FSM ↔ sub-agent process | sub-agent spawned as child; progress events flow back to TUI via PubSub |
| H8 | TUI render ↔ status surfaces | model / token / cost / context-window data refreshed per turn and on demand |
| H9 | TUI ↔ slash-command registry | `/cmd` input dispatches to built-in or extension handler |

## 3. L0 — non-obvious constraints

★ marks non-obvious from a normal-speed read.

### Harness constraints (from 2026-05-04 spike)

- **★ [HC1-H5]** `~/.tau/sessions/<sid>.jsonl` is written by the binary's
  session FSM. Multiple concurrent harness runs in the same `cwd` collide on
  the same path hash bucket. Tests MUST set a unique `TAU_DATA_DIR` per run.
- **[HC2-H2]** tmux server is shared per user. Two parallel test runs using
  identical session names collide. MUST scope session names by PID + monotonic
  counter.
- **★ [HC3-H3]** The binary takes ~2s after launch to reach the point where
  Ratatouille has installed its keyboard handler. Keystrokes sent before that
  moment are consumed by the line-disciplined parent shell, not the TUI. Harness
  MUST wait for an "alt-screen entered" signal (presence of `[?1049h` in pane
  output OR a fixed minimum delay) before the first `send-keys`.
- **★ [HC4-H3]** After a `send-keys`, the renderer's next frame cycle may be
  up to one tick interval (~250ms per `Tau.TUI.App.@tick_interval`). Assertions
  on rendered content MUST poll with a backoff up to a configurable max wait, not
  single-shot capture.
- **★ [HC5-H4]** Spike observed: TUI rendered, accepted "hi", status
  transitioned to "sending" — but no assistant response appeared in the
  transcript pane and no error appeared either. Headless tests detect this by
  asserting that within `T_max` after submit, the transcript pane contains either
  a `[assistant] ...` line OR a line matching `Error|auth|expired`.
- **[HC6-H2]** A tmux session that exits cleanly via `q` cannot be
  capture-pane'd afterwards (the session is gone). Harness MUST capture
  immediately before sending the quit key, or use `tmux capture-pane` with `-S`
  history before sending.
- **★ [HC7-H4]** Ratatouille 0.5.1 + Elixir 1.18.1: render path emits
  `Range.new/2 default step -1` warnings. The render still completes (the pane
  shows the expected layout in the spike), but stderr is noisy. This is a
  **separate dependency-side bug** tracked as #337 (transcript rendering core —
  in-Ratatouille fix; subsumes #334, #190); the headless harness MUST tolerate it
  (suppress stderr or filter expected warnings) but MUST NOT mask actual rendering
  errors.
- **★ [HC8-H3]** ANSI escape sequences carry layout. Stripping ANSI for text
  assertions loses cursor positioning; `tmux capture-pane -p` flattens pane
  state to plain text already. Use `-p` for textual assertions; use raw
  `script`-style logs only when the assertion requires escape-sequence
  verification (e.g., "alt-screen activated").
- **[HC9-H2]** `tmux capture-pane -p -S -<n>` returns the last n lines of pane
  history. Lines that scrolled off before n must be captured earlier — harness's
  `await/3` MUST sample at intervals, not one-shot at the end.
- **[HC10-H4]** A bug in the renderer that loops without yielding would consume
  CPU forever. Harness enforces a hard timeout on every `start/2` invocation.
- **★ [HC11-H3]** `send-keys` is non-blocking. Two `send-keys` calls in rapid
  succession can race the renderer's input read. Harness's `send/2` takes an
  optional `:settle_ms` (default 50ms) and sleeps after the send to let the
  renderer drain.
- **[HC12]** A test that sends a complete prompt then immediately quits may quit
  before the FSM has cast the user message. The send-quit sequence MUST observe
  at least one re-render between input and quit.
- **[HC13]** Changes to `Tau.TUI.App.@tick_interval` invalidate harness's
  default poll cadence. Harness derives its poll interval from a centralized
  config so a future tick change cascades.

### Input editor constraints (#338)

- **★ [HC14-H6]** Multi-line input accumulates in an editor buffer. Arrow-up /
  arrow-down must navigate history, not cursor, when the buffer is empty. The
  boundary between "cursor navigation" and "history navigation" is the buffer
  boundary state — harness must send sequences carefully or it will trigger the
  wrong mode.
- **[HC15-H6]** readline kill-ring (`Ctrl-K`, `Ctrl-Y`) operates on an in-process
  ring buffer. Pasting via `Ctrl-Y` from the harness requires the kill-ring to
  have been populated in the SAME session; the ring is not persisted.
- **★ [HC16-H6]** External-editor escape (`Ctrl-X Ctrl-E` or equivalent) forks a
  subprocess with `$EDITOR`. In headless mode the forked process finds no tty
  and fails. The TUI MUST detect this and return to the input prompt with the
  buffer unchanged; the harness verifies this does not crash the TUI.

### Sub-agent visibility constraints (#335)

- **★ [HC17-H7]** Sub-agent progress arrives asynchronously via `Phoenix.PubSub`
  from `Tau.CodingAgent`. The TUI render tick may deliver a stale sub-agent state
  if the tick fires between two rapid progress events. Harness awaits a stable
  "done" signal, not an intermediate one.
- **[HC18-H7]** Sub-agent processes can be nested (an agent spawns an agent). The
  TUI MUST not deadlock or crash on nested sub-agent events even if it only
  renders one level of depth.

### Status surface constraints (#340)

- **★ [HC19-H8]** The `context_window/1` callback is a new `Tau.Provider`
  optional callback returning the provider's total context window size. Without
  it the status bar cannot show "used / total" context. Providers that omit it
  display "–/–" rather than crashing.
- **[HC20-H8]** Token and cost counters are updated per turn from `Tau.Cost.Tracker`
  via telemetry. If `Tau.Cost.Tracker` is not running (test isolation), the
  status bar must tolerate nil/zero counters without crashing.

### Theme / keybinding constraints (#345)

- **★ [HC21-H9]** Background-colour detection reads `$COLORFGBG` or issues
  `OSC 10`/`OSC 11` terminal queries. In a tmux session these environment
  variables may be unset. The TUI MUST fall back to a safe default (dark theme)
  when detection fails or is inconclusive.
- **[HC22-H9]** Custom keybinding configuration must be validated at load time;
  an invalid keybinding (e.g. duplicate assignment) MUST be logged and the
  default binding retained; it MUST NOT crash the TUI.

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
# atoms: :enter, :escape, :ctrl_c, :tab, :backspace, :up, :down, :left, :right,
#        :ctrl_k, :ctrl_y, :ctrl_a, :ctrl_e, :ctrl_u, :ctrl_l, :ctrl_r

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

### H7 — Session FSM ↔ sub-agent process

INV: sub-agent progress events MUST be published on `Tau.PubSub` under
topic `"session:<session_id>:sub_agent"`. The TUI subscribes on session
start and renders progress in the transcript pane. An absent or
crashed sub-agent MUST NOT crash the TUI's render loop.

### H8 — TUI render ↔ status surfaces

INV: the status bar MUST render `model | N tok | $C | K/W ctx` where:
- `model` is the current model atom rendered as a short string.
- `N tok` is the running session token count from `Tau.Cost.Tracker`.
- `$C` is the running session cost from `Tau.Cost.Tracker`.
- `K/W ctx` is `used_tokens / context_window_tokens`, with `context_window/1`
  from the active provider (display `–/–` when unavailable).

### H9 — TUI ↔ slash-command registry

INV: typing `/` in an empty input buffer MUST activate the command
autocomplete overlay. The overlay MUST be populated from the registered
built-in slash commands plus any active skill's commands. Pressing
`<Esc>` from the overlay MUST return to the input prompt with the
buffer cleared.

## 5. PSDH catalog (D-xxx) — runtime invariants

D-NNN allocation: this SPEC owns D-066–D-075 exclusively. D-001–D-065
are taken by prior SPECs (verify with `grep -rn 'D-0[0-9][0-9]'`).

| ID | Statement | Severity | Detection | Source |
|---|---|---|---|---|
| D-066 | Headless harness MUST wait for alt-screen activation before first `send-keys`; pre-activation bytes are silently dropped. | high | unit test: send before activation; assert pane does not contain those bytes after re-render | [HC3] |
| D-067 | Harness `await/3` MUST poll with backoff, not single-shot capture; renderer tick is up to 250ms. | medium | unit test: assert `await/3` succeeds when content appears after first poll | [HC4] |
| D-068 | Each harness session MUST run with a per-run `TAU_DATA_DIR`; default-data-dir collides across parallel tests. | high | unit test: two parallel harness starts; assert distinct session JSONL paths | [HC1] |
| D-069 | Harness MUST capture pane state before sending a quit-event keystroke; post-quit panes are unreadable. | medium | unit test: send quit; assert capture-pane after quit returns empty | [HC6] |
| D-070 | `tmux send-keys` callers MUST settle (≥50ms) before the next send-keys; back-to-back sends race the renderer's input read. | medium | unit test: rapid 5-key send; assert all keys observed in next render | [HC11] |
| D-071 | Harness MUST treat the Ratatouille 0.5.1 / Elixir 1.18.1 render warnings as expected stderr; assertions on stderr MUST filter them. | low | unit test: capture stderr; assert filtered output is empty when binary runs cleanly | [HC7] |
| D-072 | The `context_window/1` provider callback is optional. A TUI session MUST display `–/–` in the context-window status field (not crash) when the active provider omits this callback. | medium | unit test: mock provider with no `context_window/1`; assert status bar renders `–/–` in the ctx field | [HC19] |
| D-073 | Sub-agent progress events arriving on `Tau.PubSub` MUST NOT crash the TUI render loop, even when the sub-agent is nested or exits abnormally. | high | Two assertions required: (1) [HC17] abnormal-exit: spawn a sub-agent that exits with `{:error, :crashed}`; assert TUI continues to accept input and render after the crash. (2) [HC18] nested non-deadlock: spawn a sub-agent that itself spawns a child sub-agent; assert the TUI render loop does not deadlock or crash (i.e., it accepts a new input keystroke within the tick interval after both agents complete). | [HC17], [HC18] |
| D-074 | Theme background detection MUST fall back to the dark theme when `$COLORFGBG` is unset and OSC query returns no result. | low | unit test: unset env; assert theme selection returns `:dark` | [HC21] |
| D-075 | An invalid or duplicate keybinding in the user config MUST be logged via `Logger.warning/2` and the default binding MUST be retained; the TUI MUST NOT crash on startup. | medium | unit test: config with duplicate binding; assert TUI starts, logs a warning, and the default action is bound | [HC22] |

**Note:** D-020–D-025 (the original SPEC-TUI-HEADLESS invariants) are
superseded by D-066–D-071, which restate the same constraints with the
updated identifier allocation. D-020–D-025 are retired as of this
revision; do not reference them in new work.

## 6. Acceptance criteria — UX surface

These criteria define the M1.1 UX bar. Each maps to one or more protocol
steps in §7. The competitive bar (Pi parity minimum; Claude Code parity
for sub-agent features) is noted where applicable.

### Launch and render (carries over from original §6, updated references)

#### AC-H1: First-run smoke

`start/2` against a fresh `TAU_DATA_DIR`. Within 5 seconds:
- Pane contains `session: <ulid-pattern>` in the status bar.
- Pane contains `transcript` panel header.
- Pane contains `> ` prompt at the bottom.

#### AC-H2: Single turn round-trip

*(protocol step deferred to the implementing child issue)*

`start/2` with `--provider replay` plumbed through to TUI session start
(requires a code change — see §9 deferred). Then `send "hello"`,
`send :enter`, `await/3` for `\(replay\)` within 30s. Status returns
to `idle`.

#### AC-H3: Provider error visibility

`start/2` with empty `~/.tau` and unset auth. `send "hi"`, `send
:enter`, `await/3` for `Error|auth|expired` within 5s. Pane MUST NOT be
empty after submit.

#### AC-H4: Quit ergonomics

`start/2`. `send "abc"` then `send "q"` — the q is part of input, must
not quit. Capture pane: prompt should show `> abcq`.

Then `send :enter` to clear (or backspace until empty). Then `send "q"`
on empty prompt — TUI MUST exit. Verify `quit/1` returns exit 0.

#### AC-H7: Resume render

*(protocol step deferred to the implementing child issue)*

After AC-H2, take the session id from status bar. `quit/1`, then
`start/2` again with `args: ["resume", session_id]`. Pane MUST contain
the prior turn in the transcript.

### Input editor (#338)

#### AC-E1: Basic line editing

`send "hello world"`. Capture: prompt shows `> hello world`. `send
:ctrl_a`. Capture: cursor at start of buffer (pane shows cursor
indicator at `>`). `send :ctrl_e`. Cursor at end. `send :ctrl_k`.
Buffer is empty (kill-ring populated). `send :ctrl_y`. Buffer restored
to `hello world`.

#### AC-E2: History navigation

*(protocol step deferred to the implementing child issue)*

Submit "turn1" and "turn2" (two turns). After the second turn completes,
`send :up` twice. Buffer shows `turn1`. `send :down`. Buffer shows
`turn2`. Competitive bar: matches Pi and Claude Code readline behavior.

#### AC-E3: Reverse history search

*(protocol step deferred to the implementing child issue)*

`send :ctrl_r`. Pane shows reverse-search indicator. `send "turn"`. Pane
shows the most recent matching entry. `send :enter`. The matched entry
becomes the active buffer. Competitive bar: Claude Code ships this;
Pi does not (Tau matches Claude Code here).

#### AC-E4: External editor (headless fallback)

*(protocol step deferred to the implementing child issue)*

In headless/tmux mode, send the external-editor chord (configurable;
default `Ctrl-X Ctrl-E`). TUI MUST NOT crash. Pane returns to the
input prompt with the buffer unchanged. Log MUST contain a warning that
the editor launch failed (no tty).

#### AC-E5: Multi-line paste handling

*(protocol step deferred to the implementing child issue)*

`send "line1\nline2\nline3"` (literal newlines in send, simulating a
multi-line paste). Pane shows all three lines in the input buffer.
Pressing `:enter` submits the entire buffer as a single user message.

### Slash-command surface (#333, spec home: SPEC-TUI-COMPLETION)

Note: The full slash-command protocol (fuzzy autocomplete, `/help`,
command set) lives in SPEC-TUI-COMPLETION. The protocol steps here
cover the basic dispatch path that belongs to the TUI.

#### AC-S1: Slash-command activation

`send "/"`. Pane shows command autocomplete overlay. Overlay contains
at least `/help`, `/compact`, `/model`. `send :escape`. Overlay
dismissed; buffer cleared.

#### AC-S2: `/help` dispatch

*(protocol step deferred to the implementing child issue)*

`send "/help"`, `send :enter`. Pane shows command list or help content
(not a crash, not blank). Competitive bar: Claude Code shows 80+
commands; Tau must show at least the built-in set.

#### AC-S3: Unknown slash command

*(protocol step deferred to the implementing child issue)*

`send "/nonexistent"`, `send :enter`. Pane shows an error message (e.g.
`Unknown command: /nonexistent`) rather than crashing or silently failing.

### Sub-agent dispatch visibility (#335)

#### AC-A1: Sub-agent progress shown

*(protocol step deferred to the implementing child issue)*

Initiate a turn that causes the session to spawn a sub-agent (requires
a system prompt that uses the `Agent` tool). Within `T_max` after
submit, the transcript pane contains a progress indicator line (e.g.
`[agent] spawned` or a spinner). D-073 applies.

#### AC-A2: Sub-agent completion shown

*(protocol step deferred to the implementing child issue)*

After the sub-agent completes, the transcript pane shows the sub-agent's
final result inline (not lost, not duplicated). The TUI remains
interactive after sub-agent completion.

#### AC-A3: Sub-agent crash does not crash TUI

Send a turn that triggers a sub-agent which exits with an error. The
TUI MUST remain interactive. The transcript pane MUST show an error
line (not blank). Validates D-073.

### Cancellation and steering

#### AC-C1: `Esc` cancels in-progress turn

`start/2`. Submit a turn to a slow provider (or a stub that delays).
While status shows `sending`, `send :escape`. Status MUST return to
`idle` within 2 seconds. The transcript pane MUST NOT show a partial
assistant response as complete.

#### AC-C2: Cancel clears the stream

*(protocol step deferred to the implementing child issue)*

After AC-C1 completes, immediately submit a new turn. The TUI MUST
process the new turn independently (no state leak from the cancelled
turn). Competitive bar: Pi ships mid-turn cancel; Claude Code ships it.

### Status surfaces (#340)

#### AC-T1: Model indicator

*(protocol step deferred to the implementing child issue)*

Status bar shows the active model name. After a `/model <new-model>`
command (AC-8 in SPEC-USER-TURN), status bar updates to the new model
name.

#### AC-T2: Token and cost counters

*(protocol step deferred to the implementing child issue)*

After one completed turn, status bar shows non-zero token count and
a cost figure (may be `$0.00` for the replay provider). Counters
accumulate across turns.

#### AC-T3: Context-window display

Status bar shows `K/W ctx` field. When provider exposes `context_window/1`,
the `W` value is a non-zero integer. When it does not, the display is
`–/–`. Validates D-072.

### Themes and keybindings (#345)

#### AC-K1: Default theme loads

*(protocol step deferred to the implementing child issue)*

TUI starts without setting `$COLORFGBG`. No crash. Pane renders
(dark theme is default). Validates D-074.

#### AC-K2: Invalid keybinding tolerated

Start with a config file that contains a duplicate keybinding. TUI starts.
Log contains `warning` for the duplicate. The default action for that
key is still bound. Validates D-075.

### Transcript rendering and scrollback

#### AC-R1: Long content scrollback

*(protocol step deferred to the implementing child issue)*

Submit a turn that produces a response longer than the visible pane
height. The transcript pane MUST be scrollable (page-up / page-down or
configurable keybindings). The user MUST be able to return to the bottom
(latest message). Competitive bar: Claude Code, Pi both ship this.

#### AC-R2: Wide content wrapping

*(protocol step deferred to the implementing child issue)*

Submit a turn whose response contains a line longer than the pane width.
The pane MUST wrap at word boundaries without truncation. Competitive bar:
Pi and Claude Code both handle wide content correctly.

#### AC-R3: Syntax-highlighted code blocks

*(protocol step deferred to the implementing child issue)*

Submit a turn whose response contains a fenced code block with a language
tag. The code block MUST render with syntax highlighting if the terminal
supports colours. Falls back gracefully on monochrome terminals.

#### AC-R4: Streaming render

*(protocol step deferred to the implementing child issue)*

During a streaming provider response, the transcript pane MUST update
progressively (not batch the full response then display). The user MUST
see tokens arriving in real time. Competitive bar: both Pi and Claude
Code render streaming tokens progressively.

### Terminal resize

#### AC-Z1: Resize handled without crash

While the TUI is idle, change the tmux pane geometry (`tmux resize-pane`).
The TUI MUST re-render within one tick interval. Pane MUST show no
corrupted layout.

## 7. UX testing protocol

Each protocol step corresponds to one or more AC entries above. A protocol
step PASS requires:
1. The `await/3` call returns `{:ok, pane_text}` (not `{:error, :timeout, ...}`).
2. The assertion on `pane_text` holds.
3. The binary has not exited abnormally (exit code checked by `quit/1`).

A FAIL on any step is a CI-blocking failure for the tagged test.

Steps are organised by UX surface area. Each step names the AC, the
harness sequence, and the pass assertion.

### Protocol step 1 — Launch smoke (AC-H1)

```
start(binary_path, env: [TAU_DATA_DIR: tmpdir])
await(session, ~r/session: [0-9A-Z]{26}/)
assert pane =~ "transcript"
assert pane =~ "> "
```

Tag: `@tag :tui_smoke`

### Protocol step 2 — Quit ergonomics (AC-H4)

```
start(binary_path, env: [TAU_DATA_DIR: tmpdir])
await(session, "> ")
send(session, "abc")
send(session, "q")
{:ok, pane} = capture(session)
assert pane =~ "abcq"
send(session, :enter)           # clear or submit
send(session, :backspace * N)   # drain if needed
send(session, "q")
await(session, :quit)           # harness detects session exit
{:ok, 0} = quit(session)
```

Tag: `@tag :tui_smoke`

### Protocol step 3 — Provider error surface (AC-H3)

```
start(binary_path, env: [TAU_DATA_DIR: tmpdir, TAU_ANTHROPIC_API_KEY: "invalid"])
await(session, "> ")
send(session, "hi")
send(session, :enter)
await(session, ~r/Error|auth|expired/, timeout_ms: 5_000)
```

Tag: `@tag :tui_smoke`

### Protocol step 4 — Basic line editing (AC-E1)

```
start(binary_path, ...)
await(session, "> ")
send(session, "hello world")
send(session, :ctrl_k)
await(session, "> ")            # buffer cleared
{:ok, pane} = capture(session)
refute pane =~ "hello world"
send(session, :ctrl_y)
{:ok, pane} = capture(session)
assert pane =~ "hello world"
```

Tag: `@tag :tui_ux`

### Protocol step 5 — Slash-command overlay (AC-S1)

```
start(binary_path, ...)
await(session, "> ")
send(session, "/")
await(session, ~r"/help|/compact|/model")
send(session, :escape)
{:ok, pane} = capture(session)
refute pane =~ "overlay"        # overlay dismissed
```

Tag: `@tag :tui_ux`

### Protocol step 6 — Sub-agent crash does not crash TUI (AC-A3, D-073)

```
start(binary_path, env: [TAU_DATA_DIR: tmpdir, TAU_SYSTEM_PROMPT: failing_agent_prompt])
await(session, "> ")
send(session, "go")
send(session, :enter)
await(session, ~r/Error|failed|agent/, timeout_ms: 15_000)
send(session, "ping")           # TUI still accepts input
send(session, :enter)
await(session, ~r/Error|auth|expired/, timeout_ms: 5_000)
```

Tag: `@tag :tui_ux`

### Protocol step 7 — Context-window `–/–` fallback (AC-T3, D-072)

```
start(binary_path, env: [TAU_DATA_DIR: tmpdir, TAU_PROVIDER: "replay"])
await(session, "> ")
{:ok, pane} = capture(session)
# replay provider has no context_window/1
assert pane =~ "–/–"
```

Tag: `@tag :tui_ux`

### Protocol step 8 — Terminal resize (AC-Z1)

```
start(binary_path, ..., geometry: {200, 50})
await(session, "> ")
tmux_resize(session, {120, 30})
Process.sleep(500)              # wait ≥ 2 ticks
{:ok, pane} = capture(session)
assert String.length(pane) > 0
refute pane =~ ~r/corrupt|error/i
```

Tag: `@tag :tui_ux`

### Protocol step 9 — Invalid keybinding tolerated (AC-K2, D-075)

```
config_with_duplicate = write_tmp_config(%{keybindings: %{ctrl_k: ["kill_line", "clear"]}})
start(binary_path, env: [TAU_CONFIG: config_with_duplicate])
await(session, "> ")            # starts successfully
# log assertion done in ExUnit via Logger.capture_log/1 wrapping start/2
assert log =~ "warning"
assert log =~ ~r/duplicate|invalid/i
```

Tag: `@tag :tui_ux`

### Protocol step 10 — Esc cancellation (AC-C1)

```
# Requires a delay-stub provider or a real provider with a slow response.
# In CI, use a stub that parks the response for 5s.
start(binary_path, env: [TAU_DATA_DIR: tmpdir, TAU_PROVIDER: "delay_stub"])
await(session, "> ")
send(session, "hi")
send(session, :enter)
await(session, ~r/sending/)
send(session, :escape)
await(session, ~r/idle/, timeout_ms: 2_000)
```

Tag: `@tag :tui_ux`

## 8. Implementation surface

- `test/support/tui_pty_helper.ex` — module implementing §4 H1 API. Runtime
  dependency: `tmux` on `$PATH`. Extended with `tmux_resize/2` for AC-Z1.
- `test/tau/cli/tui_smoke_test.exs` — protocol steps 1–3 (`:tui_smoke` tag).
- `test/tau/cli/tui_ux_test.exs` — protocol steps 4–10 (`:tui_ux` tag).
- `mix tau.tui_smoke` — convenience task for the `:tui_smoke` tag.
- `mix tau.tui_ux` — convenience task for the `:tui_ux` tag.

CI: GitHub Actions Linux runners have tmux installed by default. macOS
runners need `brew install tmux` step. The `:tui_smoke` suite runs on
every PR that touches files in Appendix B's source map. The `:tui_ux`
suite runs on every PR that touches `lib/tau/tui/`.

## 9. Out-of-scope / deferred

- **Replay provider in TUI session-start:** Today `Tau.TUI.App.init/1`
  hard-codes `Tau.start_session(session_id: session_id)` (no provider
  override). AC-H2 needs a provider flag plumbed through. Filed as a
  separate issue. Other ACs work without it.
- **Ratatouille 0.5.1 ↔ Elixir 1.18.1 Range warnings:** dependency-side
  bug tracked as #337 (transcript rendering core — in-Ratatouille fix; subsumes #334, #190). Harness
  tolerates via D-071.
- **Visual regression:** comparing pane snapshots byte-for-byte against
  a fixture is a possible follow-on. v1 uses substring/regex matching.
- **Macros / chord input:** harness sends one logical keystroke per
  `send/2`. No multi-key chord helper (except the external-editor sequence).
- **SPEC-TUI-COMPLETION** (new SPEC, #333 + #344): fuzzy autocomplete,
  `@`-mention autocomplete, full slash-command set. AC-S1..AC-S3 here
  cover only the TUI dispatch path.
- **SPEC-PERMISSION-PROMPTS** (#341): how headless `tau run` resolves
  `:ask`. Out of scope for this SPEC.
- **Session management / branching** (#343): SPEC-SESSION-MANAGEMENT.
- **Checkpoint / rewind** (#346): deferred; needs explicit user sign-off.
- **Inline image rendering** (Kitty/iTerm2): deferred to a future
  differentiator milestone.

## 10. The change-process rule

Any PR that touches `lib/tau/tui/`, `lib/tau/cli.ex`, or
`Tau.TUI.App.@tick_interval` MUST run at minimum the `:tui_smoke`
protocol steps locally and include the output in the PR description.
Critic and reviewer prompts extend `spec-before-code.md` with:
"Did this PR run the AC-H suite? Did any AC-H or UX protocol step
regress?"

PRs whose scope is in §6 (one of the M1.1 child issues) MUST additionally
run the relevant UX protocol steps and include their output.

## Appendix A — Spike record (2026-05-04)

Three probes against `burrito_out/tau_linux_arm64`:

**Probe 1 — `script` with no stdin:** TUI launches, alt-screen ANSI
emitted, render warnings observed. Process held until timeout
(`SIGTERM` from `timeout 5`). Captured 2087 bytes including alt-screen,
status bar, render warnings. **Conclusion:** PTY emulation works;
binary launches reach the runtime layer.

**Probe 2 — `script` with piped stdin (`hi\nq`):** Stdin bytes echoed
to PTY before alt-screen activation. Bytes consumed by line discipline,
not by Ratatouille's keyboard reader. **Conclusion:** Stdin redirection
is unsuitable for interactive driving — pre-activation bytes are lost
([HC3] / D-066).

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
| `Tau.TUI.InputEditor` (proposed, #338) | `lib/tau/tui/input_editor.ex` |
| `Tau.TUI.SubAgentPanel` (proposed, #335) | `lib/tau/tui/sub_agent_panel.ex` |
| `Tau.TUI.StatusBar` (proposed, #340) | `lib/tau/tui/status_bar.ex` |
| `Tau.Provider.context_window/1` (proposed, #340) | `lib/tau/provider.ex` |
| `Tau.TUI.Theme` (proposed, #345) | `lib/tau/tui/theme.ex` |
| `Tau.TUI.Keybindings` (proposed, #345) | `lib/tau/tui/keybindings.ex` |
| `Tau.Settings.data_dir` | reads `TAU_DATA_DIR` env or default |
| `Tau.Persistence.Jsonl.path_for/2` | `lib/tau/persistence/jsonl.ex:168-175` |
| Helper (exists) | `test/support/tui_pty_helper.ex` |
| Smoke tests (proposed) | `test/tau/cli/tui_smoke_test.exs` |
| UX protocol tests (proposed) | `test/tau/cli/tui_ux_test.exs` |

# SPEC: User Turn Loop

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-05-03 |
| **Scope** | The end-to-end loop: binary launch → TUI render → user input → provider stream → tool execution → response render → next turn or quit |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + L1 + boundary contracts. L2 deferred. |
| **Self-hosting target** | Working TUI is the prerequisite for Tau replacing the vendored claude-harness as the dev tool for Tau itself (see memory: `project_1_0_self_hosting.md`). |

**Changelog:** WI-C / #202: D-009 reworded — visible-content guarantee unified into `Assembler.finalize/3`. #211: C53, D-040 — plain-release CLI dispatch via `TAU_CLI_ARGV`; B2 contract amended with three argv sources. #179: C54, D-041 — mid-session model swap via `/model`; AC-8 added; D-002 amended to name the sanctioned swap path; B4 boundary contract note added. #227: C55, D-042 — built-in slash-command registry + inline dispatch; B4 amended with built-in outcome INV; D-042 added. #178 PR2b: C67, D-016 (implemented), D-048, D-049, AC-9 — async `/compact` built-in; `:compacting` FSM state; B4 amended with `{:async_compact, binary}` outcome; [C26] partially resolved; Appendix B updated. #181 PR2: C68 — OpenAI-compatible provider failure surface (synchronous missing-key vs. in-stream HTTP error); Appendix B updated.

## 0. Why this spec exists

Three days of activity (May 1–3 2026) produced 110 commits and a binary that
launches a TUI shell that cannot complete a turn. PR #154 fixed boot-time
crashes, achieving "TUI renders." That stops short of "working TUI." The
diagnosis on file (`project_state_2026_05_03_evening.md`) attributes the
deficit to: no plan-of-record, untested delivery layer, and review gates
tuned for OTP correctness rather than product state.

This document is the corrective. It applies L0 of the PSDH method to the
user-turn loop, surfaces ~30 constraints, expresses them as boundary
contracts, and converts each into either a runtime invariant (D-xxx
heuristic), an enforced rule, or an acceptance test. **No code that
touches the user-turn loop merges until acceptance criteria below pass on
the prod binary.**

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | session FSM `data`, message list, persistence JSONL, settings persistent_term, supervision tree, registries, MCP server status, vault entries |
| 2 | Temporal coupling | 1 | boot order (`Tau.Telemetry.Supervisor` → `Phoenix.PubSub` → ... → `Tau.Sessions.Supervisor`); PubSub subscribe-before-publish; provider stream event order; rate-limiter half-open |
| 3 | Cross-process coordination | 1 | TUI Task ↔ Session FSM ↔ Provider Task ↔ Tool Tasks ↔ Settings.Cache ↔ Persistence ↔ MCP transports |
| 4 | Feedback loops | 1 | provider stream → assembler → broadcast → TUI → render → submit → provider; tool result → next turn; fallback chain; rate-limiter 429 → half-open |
| 5 | State accumulation | 1 | message history; JSONL; FSM state derived from history; compactor triggers on size; skill activation persists per turn/session |

**Triage score: 5/5. L0 + L1 indicated.**

## 2. Component decomposition

The user-turn loop spans eight boundaries. Naming each precisely so that
contracts in §4 attach to a specific operation.

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | OS ↔ `Tau.Application` | binary launch + supervision tree boot |
| B2 | `Tau.Application` ↔ `Tau.CLI.main/1` | argv dispatch (Burrito or escript path) |
| B3 | `Tau.CLI` ↔ `Tau.TUI.App.run/0` | TUI runtime start under `Tau.TUI.Supervisor` |
| B4 | `Tau.TUI.App` ↔ `Tau.Session` | start session, send user message, receive PubSub events |
| B5 | `Tau.Session` ↔ `Tau.Provider` (impl) | `provider.stream/3` call and event consumption |
| B6 | `Tau.Session` ↔ `Tau.Tool` (impl, per-call) | tool dispatch, permissions, tool result fold-back |
| B7 | `Tau.Settings.Cache` ↔ session/provider/permissions | settings cascade reads |
| B8 | `Tau.Providers.Anthropic` ↔ Auth resolver | API-key OR Claude Code OAuth credential resolution and request-header construction |

## 3. L0 — eight questions

Each question lists raw constraints. Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious (not visible from a normal-speed read of the architecture description).

### Q1: What can be written by more than one actor?

- **★ [C1-B7]** `~/.tau/settings.local.json` is written by `tau init` and `tau config set`. Two `tau` processes running concurrently in different terminals can race the write — last-write-wins corrupts the cascade silently. No file lock.
- **★ [C2-B4]** `~/.tau/sessions/<sid>.jsonl` is written by the running session FSM. **Within a single BEAM**, `Tau.resume(sid)` on a still-running session is safe (returns the live pid, lib/tau/session.ex:148-150). **Across BEAMs** (two `tau` invocations in different terminals targeting the same session id) there is no exclusivity check — both writers append concurrently. The Burrito binary makes this scenario plausible: a user opens two windows.
- **[C3-B1]** Burrito cache directory `~/.local/share/.burrito/...` extracted on first run. Two simultaneous binary invocations on a fresh install race on extraction. (Plausibly idempotent if extraction is atomic; verify.)
- **[C4-B6]** Vault entries (OS keychain) — concurrent `Vault.put/2` from two sessions on the same key races at the OS level. Backend-dependent.
- **★ [C5-B7]** `Tau.Settings.Cache` (`:persistent_term`) is updated on every `Settings.Watcher` reload. Subscribers to the settings PubSub topic re-read mid-turn. A turn that started with model X may finalize against model Y if a reload landed mid-stream.

### Q2: What ordering assumptions are implicit?

- **★ [C6-B4]** `Tau.TUI.App.init/1` calls `Phoenix.PubSub.subscribe(Tau.PubSub, "session:" <> session_id)` AFTER `Tau.start_session([])` returns. `Session.init/1` broadcasts `%Events.SessionStart{}` synchronously inside FSM init — by the time `start_session` returns, that event is already published. The TUI subscribes too late and **misses SessionStart on every launch**. Currently invisible because the TUI doesn't render anything from SessionStart, but a bug.
- **★ [C7-B3]** `Tau.TUI.App.run/0`'s Ratatouille runtime quit_events include `{:ch, ?q}`. Ratatouille consumes events at the runtime layer BEFORE `update/2` sees them. Typing the literal letter `q` in any input field quits the TUI. Severe ergonomic bug.
- **★ [C8-B1]** `Tau.Settings.Watcher` depends on `file_system` worker; if `inotify-tools` is missing the worker fails to start and watcher silently degrades. Settings file edits during runtime are not picked up. No telemetry, no log on degraded operation. (Issue #146 names the warning but not the silent-degrade behavior.)
- **★ [C9-B5]** Provider stream events are assumed to arrive in the order `Start → TextStart → TextDelta* → TextEnd → ToolUseStart → ToolUseDelta* → ToolUseEnd → Done`. Anthropic SSE delivers in order; not all providers necessarily do. The `Tau.Message.Assembler` fails silently on out-of-order events (interleaved blocks with same `block_id`).
- **★ [C10-B5]** `provider_done` arriving before all `provider_event` deltas are processed is theoretically possible if the provider task pipeline has buffering (it doesn't currently — `Enum.each` is synchronous). Implicit assumption.
- **[C11-B1]** Boot order in `Tau.Application`: `:rest_for_one`. `Tau.Telemetry.Supervisor` first (everyone emits), `Phoenix.PubSub` second (Settings.Cache broadcasts on init, ADR-0004). Adding a child between two existing ones silently changes restart-cascade semantics for everything below.

### Q3: What happens if a component fails silently?

- **★ [C12-B5]** `provider.stream/3` returns `{:error, reason}` synchronously → FSM emits `MessageEnd` with `Assistant{stop_reason: :error, error_message: "...", content: []}` → TUI's `on_message_end` (`lib/tau/tui/app.ex:183`) iterates `msg.content` (empty) → nothing rendered. **This is the actual user-facing bug behind "TUI does nothing."** The `error_message` field is invisible to the render path.
- **★ [C13-B5]** Provider task crashes mid-stream → `{:provider_failed, ref, msg}` arrives at the FSM. Handler exists; need to verify it broadcasts a visible event the TUI can render (not just internal log).
- **[C14-B5]** Provider returns `Done{usage: nil}` → cost calc has no usage to bill. Currently silent in cost tracker. Constraint, lower priority for "working TUI."
- **★ [C15-B4]** `Tau.send/2` returns `:ok | {:error, term()}`. `Tau.TUI.App.submit/1` ignores the return. If the session is dead, the cast is swallowed and the user's input vanishes from the FSM perspective — only "> text" appears in the local transcript. Silent dispatch failure.
- **★ [C16-B6]** Tool execution errors: `ToolEnd{result: %{is_error: true, content: c}}`. TUI renders `✗ <c[0..160]>`. If `c` is a structured error term, `inspect()` produces opaque output. Information loss.
- **[C17-B1]** Telemetry handler crashes — Erlang detaches the handler from the bus. Subsequent emissions silently drop. No mechanism to detect a missing handler.
- **★ [C18-B7]** `Settings.Cache.get/1` falls back to defaults if the key is absent. A typo in a settings.local.json key produces silent default behavior — debugging requires manually reading the merged cascade.
- **★ [C46-B8]** `Tau.Providers.Anthropic.api_key/1` only resolves the API-key path (settings → env → vault) and `headers/1` only sends `x-api-key` (lib/tau/providers/anthropic.ex:350-380). **Claude Pro/Max users do not have API keys** — they authenticate via OAuth tokens that Claude Code stores at `~/.claude/.credentials.json` (top-level key `claudeAiOauth`, fields `accessToken`, `refreshToken`, `expiresAt`, `scopes`, `subscriptionType`). Without OAuth support, the entire Pro/Max user population gets `{:error, :missing_api_key}` on every turn — silent for them, since they never see the env var.
- **★ [C47-B8]** Header dispatch: API-key requests use `x-api-key: <key>`; OAuth requests use `Authorization: Bearer <accessToken>` AND require `anthropic-beta: oauth-2025-04-20` for the Messages API to accept the token. The current single-shape `headers/1` cannot serve OAuth even if the token is provided. Confirmed empirically: `~/.claude/.credentials.json` accessToken format is `sk-ant-oat01-...` (vs API key `sk-ant-api03-...`).
- **★ [C48-B8]** OAuth `accessToken` has `expiresAt` (ms epoch). When expired, Anthropic returns 401. Without a refresh path, the user sees a generic auth error and has to know to run `claude /login` to renew. Refresh requires writing back to `.credentials.json`, which races with Claude Code itself if it's running — single-writer constraint.
- **[C49-B8]** OAuth `scopes` must include `user:inference` for the Messages API. Tau should validate this at config-load time and surface a clear error if missing.
- **★ [C51-B3]** The TUI prompt MUST render a visible cursor glyph at the end of `model.input`. Without it, an empty input field is indistinguishable from a frozen or blank render — the user cannot tell whether the TUI is waiting for input or has hung. Silent-failure category: the render path produces output, but the output is ambiguous to the human observer. Detection: tmux `capture-pane` must contain the cursor glyph character after a render-settle delay.
- **★ [C53-B2]** The CLI argv for a plain `mix release` MUST come from the explicit `TAU_CLI_ARGV` env marker (US-separated tokens), never inferred from positional VM arguments. The marker MUST NOT be inherited by `tau`-spawned subprocesses: `cli_argv/0` deletes it (via `System.delete_env/1`) immediately after reading, before returning the decoded argv. A plain-release boot with no marker resolves to `:no_cli`; the OTP app stays up with no `System.halt`. Positional VM args passed to the release launcher (`bin/tau start`) MUST NOT influence dispatch. (Closes D-040.)
- **★ [C54-B4]** `data.model` in `Tau.Session` FSM data MUST have a single mutation site: `do_swap_model/2` (a pure function). All paths that update `data.model` — the `{:swap_model}` synchronous call handler, the `/model` slash-command path, and the `{:reconfigure}` cast — MUST route through `do_swap_model/2`. Direct `Map.put(data, :model, ...)` outside of `do_swap_model/2` is forbidden. `Tau.Session.swap_model/2` is the only public surface; `update_provider/2`'s `:reconfigure` path routes model through `do_swap_model/2` but MUST NOT emit a `model_swap` event — it emits a single `reconfigure` event preserving today's contract. (Closes D-041.)
- **★ [C55-B4]** Built-in slash commands run inline in the session FSM and return a typed `Tau.Commands.Builtin.outcome()`. The `{:notice, _}`, `{:mutate, _, _}`, and `{:error, _}` outcome branches MUST terminate in `:awaiting_user` without calling `process_user_message/2` — no provider or coding-agent turn is started (D-042). Built-in resolution via `Tau.Commands.Parser.lookup_builtin/1` MUST precede the extension-registry lookup (`Tau.Commands.Parser.lookup/1`) so built-ins shadow same-named extensions. The `{:mutate, fun, _}` fun is a pure `data -> data` transform; it MUST NOT start side-effecting processes. (Closes D-042.)
- **★ [C67-B4]** Any built-in outcome that triggers an async worker MUST: (a) use a supervised+monitored mechanism (`Task.Supervisor.async_nolink/3`); (b) arm a session-scoped timeout via `Process.send_after/3`; (c) clear worker fields (`compaction_task: nil, compaction_monitor: nil`) on EVERY terminal clause — worker success, worker crash, timeout, and `:cancel`; (d) guard every `Process.demonitor/2` and `Process.exit/2` call on the corresponding field being non-nil (unguarded `demonitor(nil)` crashes the FSM); and (e) return the FSM to `:awaiting_user` on every terminal clause. `{:async_compact, binary}` is the first outcome of this kind; D-048, D-049 enforce the invariants. (Closes [C26] partially — the silent-drop is fixed; D-016 implements the failure counter.)
- **[C68-B5]** OpenAI-compatible providers (e.g. `Tau.Providers.DeepSeek`) share the wire-format helpers in `OpenAIChatWire`. Their failure surface has two distinct shapes that the FSM MUST handle: (a) missing or nil API key → `stream/3` returns `{:error, :missing_api_key}` *synchronously* before any network call (subset of D-018's "hard configuration error" path); (b) upstream 401/429 → the stream starts (`{:ok, stream}` is returned) and the error arrives *in-stream* as `%Event.Error{reason: {:http_status, N, _}}` with `retryable?: false` for 401 and `retryable?: true` for 429. The FSM MUST handle both shapes; callers MUST NOT assume a non-`{:error, _}` return means the stream will contain only well-formed content events.

### Q4: What information crosses a boundary, and what is lost?

- **★ [C19-B5]** `error_message` field on `Assistant` is set in the synchronous-error path but the `MessageEnd` event delivers `message: msg` whose only TUI-visible fields are `content` and `stop_reason`. `error_message` is lost between Session and TUI render. (Same root as [C12].)
- **[C20-B4]** `Tau.send(sid, text)` carries the user's input as a `User{content: text}`. The TUI's editing context (cursor, multiline buffer if added later) is not transmitted — fine for v1.
- **★ [C21-B7]** `Settings.Cache.get/1` returns merged values without provenance. Debugging "why is `model` X" requires manually walking `~/.tau/settings.local.json` ↔ user-global ↔ defaults. No `Settings.explain/1`.
- **[C22-B5]** `Provider → Session` event stream lacks "request id" trace correlation. If a provider call retries via the fallback chain, telemetry events from both attempts share the session_id but not a per-attempt id, complicating diagnosis.
- **[C23-B5]** `provider.stream/3` ctx carries `session_id` and `cancel_flag` but not `is_fallback_attempt: bool`. Providers can't differentiate first-try from fallback for log/billing purposes.
- **★ [C52-B5]** Assistant text content from `%Provider.Event.TextDelta{}` is concatenated and appended to the TUI transcript verbatim (`lib/tau/tui/app.ex` `on_message_end/2`). CommonMark / GFM table markup that round-trips fine through JSONL persistence becomes visually inert in the rendered pane. The text-content boundary loses its structure on display.

### Q5: What feedback loops exist, and can they diverge?

- **★ [C24-B6]** Tool-call iteration in a single turn is **unbounded**. `Tau.Session` (lib/tau/session.ex:1056-1066) loops while `tool_calls != []`. A model that always emits a tool call (e.g., a buggy persona that loops on `Bash`) consumes API calls and tokens without limit. No `max_tool_iterations` guard visible in the FSM.
- **[C25-B5]** Rate limiter on 429: halves both buckets and arms a fixed 60-second floor (lib/tau/providers/rate_limiter.ex:50, 198). NOT exponential, no max-retry. Per-call bound is `acquire/3` timeout (default 30s) → FSM falls back to `:awaiting_user` with a rate_limit_timeout error. Persistent 429 produces continuous 60s holds; user sees repeated "rate_limit_timeout" errors with no escalation. Acceptable for v1, but [C25] flag remains for a future "max consecutive 429s" guard.
- **★ [C26-B5]** Compactor failure: `compactor.compact(...)` returns `{:error, _}` and the FSM silently drops it (`{:error, _} -> data`, lib/tau/session.ex:1094). No telemetry, no log. `should_compact?` refires next turn → silent loop on a persistent failure. Confirmed via OQ-4 reading.
- **★ [C50-B6]** Tool-call iteration cap value is read from `opts[:max_tool_iterations]` at session init, falling back to `get_in(Settings.Cache.get(), [:session, :max_tool_iterations])`, then defaulting to 20. The cap is snapshotted at session start, not re-read each turn (D-007 consistency). A new session inherits any settings change, but in-flight sessions use their init-time cap. This is the correct behaviour for D-007 compliance; naming it as a constraint so future callers know the precedence order.
- **[C27-B5]** Fallback chain is bounded by chain length (ADR-0012). OK.
- **[C28-B4]** Session resume replays JSONL. Fork chains (ADR-0007) reference parent events; cycle in fork chain would diverge replay. Verify acyclic invariant.

### Q6: What must be true before and after each phase transition?

| Transition | PRE | POST | Gap |
|---|---|---|---|
| `:awaiting_user → :provider_streaming` | model non-nil; provider non-nil; messages non-empty | provider_task started OR sync error → back to awaiting_user; cancel_flag fresh; assembler initialized; MessageStart broadcast | **★ [C29-B5]** What if model is nil? Currently passes nil to provider, which may default OR error. Behavior provider-dependent. `Tau.start_session([])` allows nil model. |
| `:provider_streaming → :tool_executing` | assembler emitted tool_call; permissions evaluated `:allow` | tool task spawned; provider_task may still be alive (interleaved) | **★ [C30-B6]** Permissions returns `:ask`. CLI/TUI has no current "ask" UI. What does FSM do — block forever? Use default? Audit. |
| `:tool_executing → :provider_streaming` (next iter) | tool result attached to messages | new provider stream started | [C31] No max-iteration guard (see [C24]). |
| any → `:stopped` | stop signal OR session_end broadcast | persistence flushed; subscribers notified; FSM exits :normal | **★ [C32-B4]** Persistence flush guarantee on abnormal exit (SIGKILL, BEAM crash) — partial JSONL written without a terminating event. Replay must tolerate. |

### Q7: What is the protocol between these components, and what happens if a message arrives out of order?

- **★ [C33-B4]** TUI ↔ Session: cast `:user_message` is fire-and-forget. No ack. If the user types two prompts quickly, both queue (ADR-0009). Per ADR-0009 the second is buffered until the current turn ends. **The TUI has no rendering for "queued" state** — user thinks the second prompt was ignored.
- **★ [C34-B5]** Stale stream events: ADR-0012 introduces `stream_ref` to drop events from a killed predecessor. Implementation correct; the constraint is that **any future code path** that emits a `provider_event`/`provider_done`/`provider_failed` MUST tag with the current ref or it will be silently dropped (or worse, mismatched).
- **★ [C35-B4]** TUI-side: `on_session_end/2` updates the model but does NOT call `Phoenix.PubSub.unsubscribe/2`. After session end, a new SessionStart for a fresh session would route events to the dead TUI Task's mailbox. Currently irrelevant (TUI exits when Ratatouille runtime exits) but a leak waiting to happen if "new session" is added without restart.

### Q8: If you change component X, what properties of connected components Y and Z must be re-verified?

- **★ [C36]** Boot order in `Tau.Application` (`:rest_for_one`): adding/reordering children silently changes restart-cascade semantics. Every PR that adds a child MUST justify its position relative to existing children and re-verify the restart envelope.
- **[C37]** Settings cascade key rename: every consumer reading the old key path silently uses defaults. No compile-time check.
- **[C38]** `Tau.Provider` behaviour callback addition: breaks all four providers + Replay. Compile-time check via `@callback` exists.
- **[C39]** PubSub event struct fields: `Events.MessageEnd` field changes break TUI render, persistence, Replay, and any future LiveView (#42).
- **[C40]** Default model in `Tau.Providers.Anthropic.@default_model`: changes affect every `start_session([])` call AND every test asserting on default.
- **★ [C41]** Rate limiter parameters: `cooldown`, `retry_after`, `half_open_window`, `max_concurrent` form a coupled set per ADR-0011. Changing one without re-verifying the others has caused an outage (#129).
- **★ [C42]** Burrito options shape: PR #144 fixed `release.options[:burrito]` placement. Any future Burrito upgrade requires re-verifying the options key path; the failure mode is silent (no Burrito wrap occurs).

### L0 yield

**45 raw constraints**, of which **25 are non-obvious (★)**. Threshold (5–12) exceeded — appropriate for a 5/5 triage component.

## 4. Boundary contracts (from L0)

Compact form. Every `★` constraint maps to at least one clause. Constraints inflate boundary count when they sit between two not yet enumerated; in those cases new boundaries are added.

### B1 — OS ↔ `Tau.Application` (binary launch)

```
PRE
  - Erlang VM started; release vm.args/sys.config applied.
  - `:tau` listed as :permanent in release applications.
POST
  - Tau.Supervisor running with all children up.
  - `[:tau, :app, :ready]` telemetry emitted.
  - For Burrito invocation: argv from `Burrito.Util.Args.get_arguments/0` available.
INV
  - Boot order: rest_for_one ensures Telemetry, PubSub, Registries are up
    before any subsystem that depends on them.
  - file_system worker absence MUST emit a telemetry event AND a Logger.warn,
    not just print [error] to stdout. (Closes [C8].)
```

### B2 — `Tau.Application` ↔ `Tau.CLI.main/1` (argv dispatch)

```
PRE
  - Tau.Supervisor up.
  - argv resolved from exactly one of three ordered, mutually exclusive sources:
      A (Burrito)       — Burrito.Util.Args.get_bin_path/0 != :not_in_burrito;
                          argv = Burrito.Util.Args.get_arguments/0 || [].
      B (escript)       — direct escript invocation (not used in prod release path).
      C (plain release) — TAU_CLI_ARGV env marker present and non-empty;
                          tokens are US-separated (\x1f); marker is deleted
                          immediately after read so it is NOT inherited by
                          tau-spawned subprocesses.
  - No marker (source C absent) AND not in Burrito (source A absent) → :no_cli;
    OTP app stays up, no System.halt.
POST
  - For empty argv (or `tui` subcommand): tui_cmd/0 invoked; halt(0|1).
  - For `run`/`resume`/`config`/etc: corresponding command run; halt(exit_code).
INV
  - tui_cmd/0 MUST surface non-OK return from Tau.TUI.start/0 to stderr
    AND set non-zero exit. (Closes [C12]'s downstream half: even if the TUI
    error didn't render in-UI, the binary exits with a diagnostic.)
  - Positional VM arguments passed to a plain `mix release` launcher MUST NOT
    influence dispatch. A :no_cli resolution MUST leave the OTP app running
    with no System.halt. (Closes [C53-B2].)
```

### B3 — `Tau.CLI` ↔ `Tau.TUI.App.run/0` (TUI runtime start)

```
PRE
  - Ratatouille modules loaded (Code.ensure_loaded?(Ratatouille.Runtime) == true).
  - Tau.TUI.Supervisor alive.
POST
  - On TTY: Ratatouille runtime supervisor up; Window+EventManager+Runtime
    children started; TUI render loop active until quit.
  - On no-TTY: returns {:error, reason}; emits [:tau, :tui, :exception] telemetry;
    Logger.error called.
INV
  - Quit happens only on `{:key, 3}` (Ctrl-C) at any time, OR `{:ch, ?q}` AT THE
    EMPTY PROMPT only. Typing `q` as input character must NOT quit. (Closes [C7].)
PROMPT INV
  - The prompt bar MUST append a solid block cursor glyph ("█", U+2588) after
    `model.input` on every render. No animation or timer required in v1; a static
    glyph is sufficient. The glyph must survive terminal width truncation — if the
    input line is close to the terminal width, prefer the glyph over trailing input
    characters (current implementation: Ratatouille `label` clips at the right edge,
    so the glyph is always present when input is short enough to display). (Closes
    [C51-B3]; see D-026.)
```

### B4 — `Tau.TUI.App` ↔ `Tau.Session` (session lifecycle)

```
PRE (start_session)
  - Tau.Sessions.Supervisor alive.
  - opts may be empty; session must resolve its own provider/model defaults.
POST (start_session)
  - Returns {:ok, session_id}.
  - SessionStart broadcast on "session:<id>" topic — and the TUI must have
    subscribed BEFORE this broadcast. (Closes [C6]: TUI MUST pre-generate
    session_id and subscribe before calling Tau.start_session.)
INV (Tau.send/2)
  - Caller MUST pattern-match on the return; silent ignore is forbidden.
    (Closes [C15].) When return is {:error, _}, TUI renders an in-transcript
    error line.
INV (PubSub render path)
  - For every Assistant message with stop_reason == :error, the TUI MUST
    render the Assistant.error_message field as a transcript line, not
    iterate empty content. (Closes [C12], [C19].)
INV (queued message visibility)
  - When Tau.send is called during :provider_streaming, the TUI status bar
    MUST reflect "queued" — currently silent. (Closes [C33].)
INV (cleanup)
  - on_session_end MUST Phoenix.PubSub.unsubscribe before mutating model.
    (Closes [C35].)
INV (built-in outcome)
  - A built-in slash command resolved via Tau.Commands.Parser.lookup_builtin/1
    returns one of: {:notice, binary | [binary]}, {:mutate, fun/1, binary | nil},
    {:error, binary}, {:async_compact, binary}, or :passthrough.
    The {:notice}, {:mutate}, and {:error} branches MUST NOT call
    process_user_message/2.  Only :passthrough may start a provider turn.
    {:async_compact, binary} is the sole outcome that changes FSM state — it
    transitions to :compacting and does NOT call process_user_message/2 (D-042,
    [C67-B4]).  Built-in resolution precedes extension lookup.  (Closes [C55-B4],
    D-042.)
```

### B5 — `Tau.Session` ↔ `Tau.Provider` (stream)

```
PRE (Session → provider.stream/3)
  - data.model not nil (Session resolves nil to provider.default_model() at
    start_session time, NOT at stream call time). (Closes [C29].)
  - data.provider implements the Tau.Provider behaviour.
  - ctx carries session_id and cancel_flag.
POST (sync result)
  - {:ok, stream} → stream produces Tau.Provider.Event structs in order:
    Start, then any of (TextStart, TextDelta, TextEnd, ToolUseStart, ToolUseDelta,
    ToolUseEnd) zero or more times, then Done.
  - {:error, reason} → Session emits MessageEnd with stop_reason: :error and
    error_message: inspect(reason). The Assistant message MUST also have
    content == [%Tau.Message.TextBlock{type: :text, text: "Error: " <>
    inspect(reason)}] so existing TUI render iterates non-empty content.
    (Closes [C12], [C19] structurally — no TUI change required for the
    common error path.)
INV (event ordering)
  - Stream events arrive in canonical order per provider. The Assembler MUST
    detect out-of-order arrivals (e.g., TextDelta before TextStart) and emit
    a telemetry warning. (Closes [C9].)
INV (stale event tagging)
  - Any new code path that sends provider_event/provider_done/provider_failed
    to the FSM MUST tag with the current stream_ref. (Closes [C34].)
```

### B6 — `Tau.Session` ↔ `Tau.Tool` (per-call dispatch)

```
PRE (per call)
  - Permissions evaluator returned :allow (concrete, not :ask, in headless mode).
  - Tool module implements the Tau.Tool behaviour.
POST
  - ToolEnd broadcast with %{name, result: %{content, is_error}}.
  - On is_error: true, content is a printable error string (NOT a raw struct).
    (Closes [C16].)
INV (iteration cap)
  - A single user-turn MUST complete at most N tool-call iterations
    before either (a) the model emits stop_reason: :end_turn (clean
    exit) or (b) the FSM aborts with stop_reason: :tool_loop_aborted
    (cap reached). "At most N" means N dispatches may complete; the
    (N+1)th attempt triggers the abort path. The check is
    `data.tool_iterations >= cap` evaluated before each dispatch.
    (default N=20, configurable via Tau.Settings or per-session opt).
    Cap precedence: opts[:max_tool_iterations] > Settings.Cache
    [:session, :max_tool_iterations] > default 20. Cap snapshotted at
    session init (D-007 compliance — mid-session settings reloads do
    NOT change the cap for in-flight sessions). ([C50])
    On overflow: emit [:tau, :session, :tool_iteration_cap] telemetry
    with measurements %{iterations: N, cap: K} (N = completed dispatches
    in the aborted turn, equals K at abort boundary) and metadata
    %{session_id: id}, append and persist an Assistant message with
    stop_reason: :tool_loop_aborted, broadcast MessageEnd, return to
    :awaiting_user. (Closes [C24], implements D-027 / AC-6.)
INV (permissions :ask in headless)
  - When permissions evaluator returns :ask and no UI subscriber answered
    within timeout: treat as :deny, emit telemetry. The current FSM behavior
    must be audited. (Closes [C30].)
```

### B7 — `Tau.Settings.Cache` ↔ consumers

```
PRE
  - Settings.Cache up; persistent_term populated.
POST (Settings.Cache.get/1)
  - Returns merged cascade value or default.
  - Provenance is recoverable via Settings.explain/1 (TO BE ADDED).
    (Closes [C21].)
INV (concurrent settings.local.json writes)
  - Tau.CLI.Config.set/3 MUST acquire an OS-level file lock (flock) before
    writing settings.local.json. (Closes [C1].)
INV (settings reload mid-turn)
  - Settings.Cache values consumed inside a turn (model, provider, rate
    limits) MUST be snapshotted at :start_provider time and reused for the
    duration of that stream. Mid-stream cache reload MUST NOT change the
    in-flight call. (Closes [C5].)
```

## 5. L1 — state enumeration on highest-risk interactions

Per the protocol, applied selectively to the three coordination-densest
points. Format: actor states, then combinations that should not be
reachable but currently are.

### L1-1: FSM state × Provider task lifecycle × Cancel flag

| FSM | Provider task | Cancel flag | Reachable? | Should be? |
|---|---|---|---|---|
| awaiting_user | none | nil | yes | yes |
| awaiting_user | DOWN-pending | counter set | possible mid-cleanup | NO — cleanup must complete before transition |
| provider_streaming | running | counter set | yes | yes |
| provider_streaming | crashed | counter set | yes | YES, FSM handles {:provider_failed, ref, _} |
| provider_streaming | DOWN | counter cleared | possible if cancel races termination | indeterminate — verify ADR-0017 |
| tool_executing | running (interleaved) | counter set | yes (intentional) | yes |
| stopped | running | counter set | should be impossible | NO — stop must terminate provider task |

**New constraint surfaced [L1-C43]:** stopped state with a still-running provider task. Current code: when the FSM exits :stopped, does it explicitly terminate `data.provider_task`? Must verify; if not, a stopped session leaks a Task.

### L1-2: Settings.Cache × Settings.Watcher × Permissions.RuleSet

| Cache | Watcher | RuleSet | Reachable? | Should be? |
|---|---|---|---|---|
| populated | up | up (matches cache) | yes | yes |
| populated | DOWN (no inotify) | up (stale) | yes (silent) | NO — degraded mode must be visible |
| populated | up | DOWN (compile failure) | yes | YES — RuleSet restart from :rest_for_one |
| stale | up (event missed) | stale | possible if Watcher restarts | undefined — must reconcile from disk on Watcher boot |

**New constraint surfaced [L1-C44]:** Watcher restart does not reconcile against on-disk file state — only future events. If a settings change happened during the Watcher's downtime, it's lost.

### L1-3: Supervisor restart × in-flight session

`Tau.Sessions.Supervisor` is `:one_for_one`. A single session FSM crash restarts that session — but the FSM's process state (messages, in-flight provider task) is lost. Recovery currently reads JSONL from disk if `Tau.resume/1` is called.

| Sessions.Supervisor | Tau.TUI.Supervisor | TUI Task | Reachable? | Should be? |
|---|---|---|---|---|
| up | up | running | yes | yes |
| restarting (whole tree) | restarting | killed | yes (rest_for_one cascade from above) | YES, by design |
| up | up | running with stale session_id (FSM crashed and restarted with same id) | possible after FSM crash | NO — TUI must re-subscribe or reset on session crash |

**New constraint surfaced [L1-C45]:** TUI does not monitor the session FSM pid. If the FSM crashes and restarts, the TUI keeps publishing to the old session_id but the new FSM doesn't know about the TUI. Silent disconnection.

## 6. PSDH catalog (D-xxx) — runtime invariants

Each entry: id, statement, severity, detection_method, source_constraint.

| ID | Statement | Severity | Detection | Source |
|---|---|---|---|---|
| D-001 | TUI MUST render `Assistant.error_message` for `stop_reason: :error` messages | high | property test: feed Replay error → TUI render fixture; assert non-empty render | [C12], [C19] |
| D-002 | `Tau.start_session/1` MUST resolve a non-nil model before reaching `:start_provider`. `data.model` is resolved at session init (from `opts[:model]` → last persisted `model_swap` → `provider.default_model()`). The ONLY sanctioned between-turn mutation is `Tau.Session.swap_model/2`, gated to `:awaiting_user` state (D-041). | high | property test: start_session([]) ; assert data.model != nil | [C29], [C54] |
| D-003 | `Ratatouille.run` quit_events MUST NOT include bare `{:ch, ?q}` — quit must be context-aware | medium | source-level: refute regex match; manual-test gate | [C7] |
| D-004 | TUI MUST `Phoenix.PubSub.subscribe/2` BEFORE `Tau.start_session/1` returns | high | property test: capture SessionStart event from TUI side | [C6] |
| D-005 | _Superseded by D-027 (same invariant, fully specified there). Retained as placeholder; references to D-005 in code comments and commit history point here._ | — | _see D-027_ | [C24] |
| D-006 | When `Tau.send/2` returns non-:ok, TUI MUST surface to user | medium | review criterion + property test on submit/1 | [C15] |
| D-007 | `Settings.Cache` values consumed in a turn are snapshotted at `:start_provider` | medium | property test: mutate settings during a Replay turn; assert in-flight uses old | [C5] |
| D-008 | Watcher degraded mode emits `[:tau, :settings, :watcher_degraded]` telemetry | low | unit test: start watcher without inotify; assert telemetry | [C8] |
| D-009 | The visible-content guarantee — every finalized `%Assistant{}` carries a non-empty `content` block so no render path drops it silently — is implemented exactly once, in `Tau.Message.Assembler.ensure_visible_content/1`, and reached by every finalize path (provider and coding-agent) via `Tau.Message.Assembler.finalize/3`. No consumer-side or path-specific mirror is permitted. | high | unit + property test on `Assembler.finalize/3`; coding-agent finalize test | [C12] structural fix |
| D-010 | TUI MUST monitor the Session FSM pid; on `:DOWN`, surface "session crashed" line | medium | unit test simulating FSM crash | [L1-C45] |
| D-011 | Stopped FSM MUST terminate `data.provider_task` before exiting | high | unit test: stop session during streaming; assert task pid !alive after stop | [L1-C43] |
| D-012 | `Settings.Watcher` reconciles disk state on (re)boot | medium | unit test: edit settings while watcher down; restart; assert cache reflects edit | [L1-C44] |
| D-013 | `Tau.CLI.Config.set/3` writes via `flock` | medium | concurrent-write test in headless | [C1] |
| D-014 | Resume of a still-running session refused with `{:error, :session_running}` | medium | unit test | [C2] |
| D-015 | Permissions `:ask` outcome in headless context resolves to `:deny` after timeout | high | unit test | [C30] |
| D-016 | **Implemented.** Compactor `{:error, reason}` MUST emit `[:tau, :compaction, :exception]` telemetry AND increment `data.compaction_failures`, a per-session consecutive-failure counter; on N>=3 consecutive failures, FSM aborts with `stop_reason: :compaction_failed`. Counter is SHARED across the sync post-turn path (`maybe_compact/2`) and the async worker path — NOT path-tagged. A broken compactor is a session-level fault; tagging would allow alternating-path evasion. Consequence: an async failure can push the count so the next sync compaction aborts an otherwise-healthy turn — accepted, surfaces a real fault. The sync-path abort message MUST name "repeated or background compaction failure" as the cause. | medium | `test/tau/session/compaction_test.exs`: D-016 sync abort (3 consecutive errors); D-016 cross-path (1 async + 2 sync → 3rd aborts) | [C26] (OQ-4), [C67-B4] |
| D-017 | `Tau.Providers.Anthropic` MUST support both API-key auth (`x-api-key` header) AND Claude Code OAuth auth (`Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20` header). OAuth credentials sourced from `~/.claude/.credentials.json` (top-level key `claudeAiOauth.accessToken`). Auth precedence (first non-nil wins): explicit `:api_key` opt → `Application.get_env` API key → `ANTHROPIC_API_KEY` env (vault) → Claude Code OAuth file. | high | unit test: stub each source; assert correct header shape; integration test with a Bypass server checking both code paths | [C46], [C47] |
| D-018 | Expired OAuth token (`expiresAt < now`) MUST surface a clear, actionable error to the user — "Your Claude Code OAuth token expired; run `claude /login` to renew" — NOT a generic 401 or silent failure. Tau v1 does NOT refresh tokens itself (avoids the race with Claude Code's own refresh). | medium | unit test: stub credentials with past `expiresAt`; assert error message contains "expired" and the renewal command | [C48] |
| D-019 | `tau doctor` MUST report which auth path is configured (api_key vs oauth vs none) and, for OAuth, the `subscriptionType` and time-to-expiry. | low | unit test on doctor output | [C46] (debuggability) |
| D-026 | The TUI prompt bar MUST render a solid block cursor glyph ("█", U+2588) appended after `model.input` on every render frame. The glyph indicates the active insertion point and distinguishes an idle, waiting-for-input state from a frozen or blank render. No animation required in v1. | medium | tmux smoke test (`test/tau/cli/tui_smoke_test.exs` AC-H1): `tmux capture-pane` output after a 150 ms render-settle MUST contain "█"; absence indicates the render path is broken or the glyph is being stripped | [C51-B3] |
| D-027 | Session FSM MUST cap tool-call iterations per turn at `max_tool_iterations` (default 20, readable from `opts[:max_tool_iterations]` or `Settings.Cache.get()[:session][:max_tool_iterations]`). When the cap is exceeded, the FSM MUST emit `[:tau, :session, :tool_iteration_cap]` telemetry with measurements `%{iterations: N, cap: K}` — where `N` is the count of completed dispatches in the aborted turn (equals `K` at the abort boundary; resets to 0 at the start of the next turn) — and metadata `%{session_id: id}`, then abort the turn with `stop_reason: :tool_loop_aborted`. The per-turn counter resets to 0 on every return to `:awaiting_user`. | high | property test `test/tau/session/tool_iteration_cap_property_test.exs`: drives a session backed by bespoke `AlwaysToolCallProvider` (a `Tau.Provider` behaviour implementation that always emits a `tool_call` event stream, independent of Replay); asserts turn terminates within `max_tool_iterations` with `stop_reason: :tool_loop_aborted` and that the telemetry event fires with `iterations == cap` | [C24], [C50] |
| D-028 | Assistant text content rendered to the TUI transcript MUST be parsed as CommonMark with GFM tables (`Tau.Markdown.render/1`) before display. Raw markdown source MUST NOT appear in the rendered pane for valid CommonMark input. Output MUST be ASCII-only: tables use `\|` / `-` / `+` (NOT Unicode box-drawing — Ratatouille 0.5.1's `Renderer.Cells.to_char/1` crashes on multi-byte UTF-8 in label content; see Ratatouille tracking issue). Bold and italic markers are STRIPPED (Ratatouille labels render flat text with no inline attributes); inline-code backticks preserved as visual cue. On parse error, a `[markdown-parse-error]` prefix surfaces the failure rather than silently dropping the content. | medium | unit test on `Tau.Markdown.render/1` over a markdown fixture containing a table + bold + inline code + fenced code; assert the output list contains ASCII pipe-and-plus tables and no Unicode box-drawing chars | [C52-B5] |
| D-040 | A plain (non-Burrito) `mix release` boot with no explicit CLI-dispatch marker (`TAU_CLI_ARGV`) MUST NOT dispatch the Tau CLI and MUST NOT call `System.halt`. Positional VM arguments passed to the release launcher (`bin/tau start`) MUST NOT be consulted for dispatch. The `TAU_CLI_ARGV` marker is consumed-and-deleted (`System.delete_env/1`) by `Tau.Application.cli_argv/0` immediately after reading so it is NOT inherited by tau-spawned subprocesses. Encoding: tokens are joined by ASCII Unit Separator (`\x1f`); `Tau.Application.encode_cli_argv/1` is the single source of truth — no other code path may duplicate the separator literal. | high | `test/tau/application/cli_argv_test.exs` (all six tests); `test/tau/cli/tui_smoke_test.exs` AC-H1 and AC-H2 against `_build/prod/rel/tau/bin/tau` | [C53-B2] |
| D-041 | `data.model` in the session FSM MUST be treated as immutable within a provider turn. `Tau.Session.swap_model/2` is the sole sanctioned mid-session mutation of `data.model`, gated to `:awaiting_user` state with `command_task == nil`; any other state MUST return `{:error, :busy}`. `do_swap_model/2` is the single `data.model` mutation site ([C54-B4]). On success the FSM MUST emit `[:tau, :session, :model_swapped]` telemetry and persist a `model_swap` JSONL event. The persisted event is folded back into `data.model` on resume/fork via `model_from_preload/1` in `init/1`. | high | `test/tau/session/swap_model_test.exs` — 7 cases covering success, busy, JSONL persistence, not_found, idempotent, invalid_model (empty + whitespace) | [C54-B4], [C29] |
| D-042 | A built-in slash command MUST NOT drive a provider or coding-agent turn. When `Tau.Commands.Parser.lookup_builtin/1` resolves a command name, the FSM dispatches `mod.run(args, data)` and handles the typed outcome inline: `{:notice, _}`, `{:mutate, _, _}`, and `{:error, _}` branches return `{:keep_state, data}` or `{:keep_state, data2}` — they MUST NOT call `process_user_message/2`. Only `:passthrough` may proceed to `process_user_message/2`. On every dispatch the FSM MUST emit `[:tau, :session, :builtin_command]` telemetry with metadata `%{session_id: id, command: name, outcome: tag}`. Built-in lookup precedes extension lookup (`[C55-B4]`). The `{:async_compact, binary}` outcome (new) changes FSM state to `:compacting` — the single exception to the stateless-builtin rule, governed by [C67-B4]. | high | `test/tau/session/builtin_command_dispatch_test.exs` — D-042 proof: drive `/ping` into a session backed by `RecordingProvider` that records `stream/3` calls; assert zero provider calls, a `SystemNotice` with `"pong"` is broadcast, FSM snapshot is responsive; assert `[:tau, :session, :builtin_command]` telemetry fires with correct metadata | [C55-B4] |
| D-048 | **:compacting-state exit invariant (C67-B4).** Every exit edge from the `:compacting` gen_statem state MUST land in `:awaiting_user` with both `data.compaction_task` and `data.compaction_monitor` set to `nil`. Five terminal clauses cover all exit paths: (1) worker success `{ref, result}`; (2a) benign `{:DOWN, :normal}` (keep-state, result pending); (2b) crash `{:DOWN, reason}`; (3) live timeout; (4) stale timeout (no-op). `{:next_state, :awaiting_user, data}` is the return form for clauses 1, 2b, 3; clause 2a uses `{:keep_state, data}` because the result message is still pending. | high | `test/tau/session/compaction_test.exs`: happy path; postpone-and-flush; stale-result-drop after cancel; `:swap_model` busy during `:compacting` | [C67-B4] |
| D-049 | **Compaction worker crash/timeout/cancel recovery (C67-B4).** The session FSM MUST NOT wedge when the compaction worker crashes, times out, or is cancelled — it MUST return to `:awaiting_user`. It MUST NOT trigger a spurious crash-recovery notice when `{ref,result}` and `{:DOWN, :normal}` arrive back-to-back (the double-message race). Achieved by: Clause 2a (`{:DOWN, :normal}`) is a `{:keep_state}` that preserves the pending result, so Clause 1 still processes it; all five typed clauses clear worker fields, so stale messages fail guards and reach the catch-all no-op. | high | `test/tau/session/compaction_test.exs`: worker-crash recovery (session not wedged); race test `{ref,result}` + `{:DOWN}` × 50 (NO spurious crash recovery); late-timeout-after-success (no FSM crash); `/cancel` outside `:compacting` (no FSM crash) | [C67-B4] |

29 D-xxx entries. Each is enforceable. None require speculation.

## 7. Acceptance criteria — "working TUI"

These are the bar for closing the umbrella issue (#153/#149) and unblocking the next milestone.

### AC-1: First-run smoke (BOTH auth paths)

`MIX_ENV=prod mix release tau` then `BURRITO_TARGET=<host> mix release tau` produces the binary. With **no** `~/.tau/settings*.json` and **no** `.tau/settings*.json` in cwd, running the binary in a real terminal renders the TUI within 3 seconds in EACH of the following auth scenarios:

- **AC-1a (API key user):** `ANTHROPIC_API_KEY=sk-ant-api03-...` in env, no Claude Code login.
- **AC-1b (Claude Pro/Max user):** no `ANTHROPIC_API_KEY` in env, but `~/.claude/.credentials.json` exists with a valid (non-expired) `claudeAiOauth.accessToken`. This is the dominant case — Pro and Max subscribers do not have API keys.
- **AC-1c (no auth):** neither — the TUI MUST render and the first turn MUST surface an actionable error ("set ANTHROPIC_API_KEY or run `claude /login`"), per D-018.

### AC-2: Single turn round-trip (BOTH auth paths)
- Type "say hello", press Enter.
- Within 30 seconds, the transcript pane shows an assistant response containing at least one non-whitespace character.
- Status bar transitions `idle → sending → streaming → idle`.
- **Both AC-1a (API key) and AC-1b (Claude Code OAuth) paths must satisfy this.**

### AC-3: Provider error visibility
- Unset `ANTHROPIC_API_KEY` AND ensure `~/.claude/.credentials.json` is absent or expired. Launch TUI. Submit "hi".
- Within 5 seconds, the transcript pane renders a line containing "Error" or "auth" (case-insensitive) AND mentions BOTH renewal paths ("set `ANTHROPIC_API_KEY`" or "run `claude /login`"). The TUI does NOT freeze or silently swallow.

### AC-4: Quit ergonomics
- Typing the literal letter `q` as part of a prompt does NOT quit.
- Pressing `Ctrl-C` always quits.
- Pressing `q` at an empty prompt (no input pending) quits.
- Quit returns to shell with exit 0.

### AC-5: Replay-driven CI smoke
- A test exists at `test/tau/cli/binary_smoke_test.exs` that invokes `_build/prod/rel/tau/bin/tau run "ping" --provider replay` (after wiring `Tau.Providers.Replay` into the CLI provider resolver — see issue #155) and asserts:
  - Exit code 0.
  - stdout contains a known token from the Replay fixture.
  - stderr is silent of `[error]`, `(EXIT)`, `:noproc`.
- This test runs in CI on every PR and is a blocking gate.

### AC-6: Tool-iteration safety
- A property test runs a session backed by a bespoke `AlwaysToolCallProvider` (a `Tau.Provider` behaviour implementation that always emits a `tool_call` event stream). The session terminates within `max_tool_iterations` (default 20) with `stop_reason: :tool_loop_aborted`.

### AC-7: Resume sanity
- After AC-2, `tau sessions list` shows the session. `tau sessions show <id>` prints the JSONL events. `tau resume <id>` opens a TUI for the resumed session whose transcript pane includes the prior turn.

### AC-8: Mid-session model swap
- `/model` with no argument broadcasts a `SystemNotice` showing the current model; no provider turn starts.
- `/model <id>` mutates `data.model`, broadcasts a `SystemNotice` confirming the change, and the immediately following turn uses the new model string. The FSM MUST return `{:error, :busy}` if the swap is attempted while streaming or running a command task. The swap is persisted as a `model_swap` JSONL event and survives `Tau.resume/1`. Empty or whitespace-only model ids return `{:error, :invalid_model}`.
- Tests: `test/tau/session/swap_model_test.exs` (7 cases) and `test/tau/session/slash_model_command_test.exs` (2 cases).

### AC-9: Async `/compact` built-in (D-048, D-049, D-016, C67-B4)

- `/compact` on a non-trivial message list transitions the FSM to `:compacting`, broadcasts a "Compacting conversation…" notice, and returns to `:awaiting_user` after the worker completes (success or failure).
- A user message submitted during `:compacting` is postponed and delivered once the FSM returns to `:awaiting_user`.
- Worker crash: FSM returns to `:awaiting_user` without wedging; a failure notice is broadcast (D-049).
- No spurious crash-recovery notice when `{ref,result}` and `{:DOWN,:normal}` race (× 50 repetitions, D-049).
- Late `{:compaction_timeout}` arriving after the worker already completed MUST NOT crash the FSM (Clause 4 no-op, D-048).
- `/cancel` outside `:compacting` MUST NOT crash the FSM (guarded demonitor, C67-B4).
- 3 consecutive compaction failures (sync or async, shared counter): FSM aborts the next sync turn with `stop_reason: :compaction_failed` (D-016).
- Tests: `test/tau/session/compaction_test.exs` (all cases) and `test/tau/commands/builtin/compact_test.exs`.

## 8. Out-of-scope hazards (explicitly deferred)

These constraints are real but NOT required for "working TUI." Each gets a follow-up issue, not a blocker.

- [C3] Burrito cache extraction race on first run.
- [C4] Vault concurrent writes (depends on backend).
- [C14] Provider Done with usage: nil → unknown cost.
- [C16] Tool error content opaque-inspect output.
- [C17] Telemetry handler crash detachment.
- [C22, C23] Per-attempt request id correlation in fallback chain.
- [C25] Rate limiter backoff ceiling verification (issue #129 may have closed; reverify).
- [C26] Compactor failure handling — **partially resolved** by D-016 (failure counter + abort) and D-048/D-049 (async path); silent-drop is fixed. Remaining: `should_compact?` refires on a permanently-broken compactor (bounded by the abort at 3 failures, so no longer an infinite silent loop).
- [C28] Fork chain acyclicity.
- [C32] Persistence flush guarantee on abnormal exit.
- [C42] Burrito options upgrade re-verification (already burned us; track in CONTRIBUTING).

## 9. The change-process rule

A new rule lives at `.claude/rules/spec-before-code.md` (drafted alongside this spec). Summary:

- Any PR that touches the user-turn loop MUST reference this SPEC in its description and identify which acceptance criterion it advances or which D-xxx invariant it enforces.
- Adding new state to the user-turn loop without a corresponding L0 pass against this spec is forbidden.
- The critic gate's review prompt is amended to ask: "does this PR move an acceptance criterion or a D-xxx, and which one?"

## 10. Open questions — resolved

| # | Question | Resolution |
|---|---|---|
| OQ-1 | Does `Tau.Providers.Anthropic.stream/3` accept `model: nil`? | **Yes:** falls back to `@default_model` ("claude-opus-4-7") in `build_body/3` (lib/tau/providers/anthropic.ex:257). BUT `data.model` stays `nil` in telemetry, persistence header, and assembler — that is the bug D-002 fixes by resolving at session init, not stream call. |
| OQ-2 | Does `Tau.Sessions.Registry` enforce one-FSM-per-id? | **Within a BEAM, yes:** Registry is `:unique`; `Session` uses `{:via, Registry, ...}` (lib/tau/session.ex:353). `Tau.resume(id)` returns the existing pid if alive (lib/tau/session.ex:148-150). **Cross-BEAM: no enforcement** — [C2] amended below. |
| OQ-3 | Replay provider shape? | `Tau.Providers.Replay` fully wired through `Tau.CLI.resolve_provider/1`'s `Module.concat` path. `default_events/0` produces "(replay) hello". Verified live: `burrito_out/tau_linux_arm64 run "ping" --provider replay --model replay` writes `(replay) hello\n` and exits 0. AC-5 is implementable today with no CLI changes. |
| OQ-4 | Compactor failure handling? | **Silently swallowed** at lib/tau/session.ex:1094 — `{:error, _} -> data`. No telemetry, no log. `should_compact?` will refire next turn, looping the failure. [C26] now confirmed and elevated; new D-016 added. |
| OQ-5 | Rate-limiter ceiling? | **Fixed 60s floor + bucket halving** on 429, no exponential backoff. `@default_429_floor_ms = 60_000` (lib/tau/providers/rate_limiter.ex:50). Each 429 resets the floor; persistent 429 produces continuous 60s holds. Bounded per-call by `acquire/3` timeout (default 30s), then FSM returns to `:awaiting_user`. [C25] amended below. |

## 11. What this spec does not pretend to be

- A complete spec of Tau. Only the user-turn loop. Other components (MCP, hooks, extensions, sub-agents) get their own SPEC documents when their triage scores ≥2.
- Static. L0 is a discovery process; new constraints will surface as the AC suite is implemented. The catalog and contracts are versioned with this file.
- A milestone substitute. PROJECT.md still owes us GitHub milestones (#119). This is what M0 acceptance looks like; subsequent SPECs define M1+.

## Appendix A — Method discipline

If a future PR touches the user-turn loop and surfaces a constraint not in §3:
1. Add it to §3 with a fresh `[Cn]` id and the right boundary tag.
2. If it is non-obvious (★), check whether the PR introduced the gap or merely surfaced it. Either way, update the boundary contract in §4.
3. If a contract changes, regenerate the affected D-xxx entries in §6.
4. If acceptance criteria need to change, that is a spec amendment, not a silent slip — note it in the changelog at the top of this file.

## Appendix B — Source map

For each constraint, the file:line where it lives in the current codebase:

| Constraint | Source |
|---|---|
| C6 | `lib/tau/tui/app.ex:18-21` (init order) |
| C7 | `lib/tau/tui/app.ex:76` (`quit_events`) |
| C8 | `lib/tau/settings/watcher.ex` (on file_system absence) |
| C12, C19 | `lib/tau/session.ex:650-654` (sync error branch) + `lib/tau/tui/app.ex:183-200` (on_message_end) |
| D-009 | `lib/tau/message/assembler.ex` (`ensure_visible_content/1` + `finalize/3` — the single source-agnostic terminal fold) |
| C15 | `lib/tau/tui/app.ex:156-165` (submit ignores Tau.send return) |
| C24 | `lib/tau/session.ex:1056-1066` (no iteration cap) |
| C29 | `lib/tau/session.ex:362-363` (model: opts[:model], no default) |
| C33 | `lib/tau/session.ex` queue path (ADR-0009) + TUI no-render |
| C35 | `lib/tau/tui/app.ex:228-237` (on_session_end no unsubscribe) |
| L1-C43 | `lib/tau/session.ex` :stopped transition |
| L1-C45 | `lib/tau/tui/app.ex:18-21` (no monitor on FSM pid) |

| C50 | `lib/tau/session.ex` init/1 — `max_tool_iterations` resolution (opts → Settings.Cache → 20) |
| C53 | `lib/tau/application.ex` — `cli_argv/0` (env-marker read → delete → decode); `test/support/tui_pty_helper.ex` — `start/2` plain-release branch; `test/tau/application/cli_argv_test.exs` |
| C54 | `lib/tau/session.ex` — `do_swap_model/2` (pure mutation core), `apply_model_swap/2` (shared helper with telemetry+persist), `handle_event({:call, from}, {:swap_model, _}, ...)` (gated call handler), `handle_slash_model_swap/2` (/model slash path), `reconfigure_model/2` ({:reconfigure} cast routing); `lib/tau/session/events.ex` — `%SystemNotice{}`; `lib/tau/tui/app.ex` — `%SystemNotice{}` dispatch clause; `test/tau/session/swap_model_test.exs`; `test/tau/session/slash_model_command_test.exs` |
| C55 | `lib/tau/commands/builtin.ex` — `Tau.Commands.Builtin` behaviour + `table/0`; `lib/tau/commands/builtin/ping.ex` — `Tau.Commands.Builtin.Ping` seed entry; `lib/tau/commands/parser.ex` — `lookup_builtin/1`; `lib/tau/session.ex` — `classify_slash_command/2` (builtin arm before extension lookup), `handle_event` `{:builtin, mod, args, msg}` arm, `handle_builtin_command/4`, `outcome_tag/1`; `test/tau/commands/builtin_test.exs`; `test/tau/session/builtin_command_dispatch_test.exs` |
| C67 | `lib/tau/commands/builtin.ex` — `{:async_compact, binary}` in `outcome()` typespec + `@moduledoc`; `lib/tau/commands/builtin/compact.ex` — `Tau.Commands.Builtin.Compact` (pure predicate); `lib/tau/session.ex` — `handle_builtin_command/4` `{:async_compact, notice}` arm (FSM transition to `:compacting`), `outcome_tag({:async_compact, _})`, five terminal `:compacting` clauses (Clauses 1/2a/2b/3/4), guarded `:cancel` demonitor/exit, `init/1` `compaction_task/compaction_monitor/compaction_failures` fields; `docs/spec/SPEC-USER-TURN.md` — D-048, D-049, AC-9, this Appendix B entry; `test/tau/session/compaction_test.exs`; `test/tau/commands/builtin/compact_test.exs` |

| (wire helpers) | `lib/tau/providers/shared/openai_chat_wire.ex` — extracted from `OpenAI.Chat` (PR 1 of #181); `build_body/4`, `decode/2`, `headers/1` are the canonical wire helpers for OpenAI Chat-compatible endpoints. No new D-id or §3 constraint; behaviour-neutral refactor. |

| C68 | `lib/tau/providers/deepseek.ex` — `Tau.Providers.DeepSeek` (`@behaviour Tau.Provider`); `lib/tau/providers/shared/tool_spec.ex` — OpenAI-compatible shape clauses for `DeepSeek`, `Groq`, `Mistral`, `AzureOpenAI`, `Custom`; `lib/tau/cli.ex` — `resolve_provider("deepseek")` + `doctor_cmd` DeepSeek key report; `docs/spec/SPEC-USER-TURN.md` — C68; `docs/providers/deepseek.md`; `test/tau/providers/deepseek_test.exs` |

Other constraints map to sites named in their text.

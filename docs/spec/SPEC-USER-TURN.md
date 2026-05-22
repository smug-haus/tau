# SPEC: User Turn Loop

| | |
|---|---|
| **Status** | Draft |
| **Date** | 2026-05-03 |
| **Scope** | The end-to-end loop: binary launch → TUI render → user input → provider stream → tool execution → response render → next turn or quit |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + L1 + boundary contracts. L2 deferred. |
| **Self-hosting target** | Working TUI is the prerequisite for Tau replacing the vendored claude-harness as the dev tool for Tau itself (see memory: `project_1_0_self_hosting.md`). |

**Changelog:** #339: D-077..D-083 — two-tier message queue (steering/follow-up); `Tau.steer/2` added to public API; `%QueueRestored{}` event added to `Tau.Session.Events`; ADR-0009's user-message-postpone decision partially superseded (ADR-0021; ADR-0008's slash-command-task postpone unaffected); `snapshot/1` exposes `queues: %{steering: [...], followup: [...]}`. Appendix B updated. #339: AC-7 amended — status-bar keybinding hints are now state-aware (idle vs busy) per D-078 and D-082. WI-C / #202: D-009 reworded — visible-content guarantee unified into `Assembler.finalize/3`. #211: C53, D-040 — plain-release CLI dispatch via `TAU_CLI_ARGV`; B2 contract amended with three argv sources. #179: C54, D-041 — mid-session model swap via `/model`; AC-8 added; D-002 amended to name the sanctioned swap path; B4 boundary contract note added. #227: C55, D-042 — built-in slash-command registry + inline dispatch; B4 amended with built-in outcome INV; D-042 added. #178 PR2b: C67, D-016 (implemented), D-048, D-049, AC-9 — async `/compact` built-in; `:compacting` FSM state; B4 amended with `{:async_compact, binary}` outcome; [C26] partially resolved; Appendix B updated. #181 PR2: C68 — OpenAI-compatible provider failure surface (synchronous missing-key vs. in-stream HTTP error); Appendix B updated. #181 PR5: C80 — Azure OpenAI auth/URL shape constraint (api-key header, deployment-based URL); Appendix B updated. #181 PR6: C81 — Custom configure-by-URL provider; nil api_key valid (omits Authorization header); synchronous error only on missing_base_url; Appendix B updated. #182 PR-A: C82, D-056 — Copilot OAuth auth subsystem + API token refresh contract; Appendix B updated. #252: C83, D-058, AC-10 — headless FSM-backed `tau run`; B2 contract amended with headless run path INV; D-058 added; AC-10 added; Appendix B updated. Closes #213 (tau run bypassed the Session FSM). #252 (f-1 fix): D-058, B2 headless INV, AC-10 amended — drain loop now enumerates failure stop_reasons (exit 1 for `:error/:tool_loop_aborted/:aborted/:compaction_failed`); all other terminal atoms → exit 0; `:tool_use` continuation and `:stop_sequence` regression tests added. #252 (f-2 fix): D-058, B2 headless INV, AC-10 amended — content-first rule: a MessageEnd whose content carries `%{type: :tool_call}` blocks is a continuation regardless of `stop_reason`; this fixes Gemini/Bedrock which emit `stop_reason: :stop` even on tool-call turns. `run_cmd/1` made `@doc false` public; f-4 end-to-end tests added via `run_cmd/1`. #267: C84, D-059, AC-10 amended, B5 active-skill tool-exposure INV — `tau run --system-prompt-file` (and any caller that sets `:active_skill` on `Tau.start_session/1`) was handing the model only the synthetic `__activate_skill__` tool, so the coordinator persona could not call `Bash`/`Read`/`Edit`/`Write`/`Agent`. `Tau.Session` now derives the model-visible tool list from `data.active_skill.allowed_tools` (empty ⇒ all built-ins; named ⇒ subset), preserving `__activate_skill__` when other model-invokable skills are discoverable. `priv/skills/{tau-coordinator,implementer,critic,reviewer}/SKILL.md` declare their `allowed-tools:` frontmatter. Appendix B updated. #293: D-060 — identical-args tool-call brake; sibling circuit-breaker to D-027 catching the narrow 'model wedged repeating the SAME failing call' failure mode (verbatim Agent({}) 5x rejection in 2026-05-20 coordinator transcript). B6 INV added; Appendix B updated. #303: D-061 — single-provider mid-stream-error retry; closes the gap where a session configured against a single provider (no fallback chain) terminated immediately on any `%Event.Error{retryable?: true}` (e.g. transient Mint transport timeout against Anthropic), killing a long-running coordinator turn. B5 INV added; Appendix B updated. #310: D-062 — compactor split boundary preserves tool_use/tool_result pairing; `realign_split_at_tool_boundary/1` moves leading `%ToolResult{}` messages from the recent half into the old half after the 60% length split, preventing HTTP 400 from Anthropic on post-compact histories. Appendix B updated. #183: C94, D-076 — user-defined prompt templates with named-variable substitution; C94 added to §3 Q3 (annotated [C94-B4]); D-076 added to §6 (pure-total substituter invariant); Appendix B updated. #337: D-028 amended — the ASCII-only / markers-stripped constraint on TUI markdown output is removed; the grapheme-aware `smug-haus/ratatouille` fork (PR #190) eliminates the upstream 0.5.1 `Renderer.Cells.to_char/1` multi-byte UTF-8 crash that made it necessary. The TUI path (`Tau.TUI.Render.Markdown`) now emits `{content, attrs}` tuples with Unicode glyphs and styling; the headless path (`Tau.Markdown`) is unchanged. D-028 now also requires a `{"", []}` blank-line spacer between consecutive block-level nodes.

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
- **★ [C83-B2]** `tau run` (headless mode) calls `Tau.stop/1` to trigger JSONL flush and `%SessionEnd{}`. If `Tau.stop/1` is not called on all exit paths (including timeout), the JSONL file may be incomplete and the session FSM process leaks until the BEAM exits. The FSM is `:transient` under `Tau.Sessions.Supervisor`; a supervisor restart would clean it, but the user-facing symptom is a persisted session with a truncated transcript. Detection: the JSONL stream for a completed `tau run` must contain both `user_message` and `assistant_message` event kinds.

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
- **★ [C80-B5]** Azure OpenAI reuses `OpenAIChatWire.build_body/4` and `OpenAIChatWire.decode/2` (same wire format), but has a distinct auth and URL shape. Auth MUST use `api-key: <key>` HTTP header (NOT `Authorization: Bearer <key>`); `OpenAIChatWire.headers/1` MUST NOT be called for Azure requests. The request URL is composed at call-time from three configured values: `{endpoint}/openai/deployments/{deployment}/chat/completions?api-version={api-version}`. Missing any of `api_key`, `endpoint`, or `deployment` → `stream/3` returns a synchronous tagged error (`{:error, :missing_api_key}`, `{:error, :missing_endpoint}`, `{:error, :missing_deployment}`) before any network call. The `deployment` name acts as the model identifier. `api_version` defaults to `"2024-12-01-preview"` when absent.
- **[C81-B5]** `Tau.Providers.Custom` is a configure-by-URL OpenAI-Chat-compatible provider. A nil `api_key` is **valid** — local endpoints (Ollama, vLLM) need no key; when nil the `Authorization` header MUST be omitted entirely (MUST NOT emit `Authorization: Bearer `). The one synchronous hard-config error is `{:error, :missing_base_url}` when `base_url` is absent or empty. Upstream 401/429 arrive in-stream as `%Event.Error{}` per C68(b). Extra headers configured under `:headers` in app env are merged after the base set.
- **★ [C82-B8]** GitHub Copilot API tokens are short-lived (~30 min). `Tau.Providers.Copilot.Auth.token/1` MUST NOT return an API token with fewer than 5 minutes remaining — it refreshes proactively when `expires_at - now < 5 min`. Refresh is a `POST https://api.github.com/copilot_internal/v2/token` call exchanging the long-lived OAuth token (from `~/.config/github-copilot/hosts.json` or env) for a new short-lived token. Refresh failure MUST surface as `{:error, :oauth_refresh_failed}` with a user-actionable message naming the `gh auth login --scopes copilot` renewal path — never a silent 401 on the next stream call. The short-lived token is stored in `Tau.Providers.Copilot.TokenStore` (a supervised GenServer), never in module-level mutable state. (D-056.)
- **★ [C84-B5]** When `data.active_skill` is set at session start (e.g. headless `tau run --system-prompt-file <path>`, a pinned sub-agent persona via `Tau.Tools.Builtin.Agent`, or any caller that supplies `:active_skill` to `Tau.start_session/1`), the model-visible tool list passed to `provider.stream/3` (`stream_opts.tools`) MUST include the active skill's `allowed_tools` as discrete tool specs — not just the synthetic `__activate_skill__` tool. Empty `allowed_tools` means "no whitelist declared" (matches `Tau.Tools.Builtin.Agent.whitelist_from/1` semantics) ⇒ every registered built-in (`Tau.Tool.list/0`) MUST appear; a non-empty list ⇒ only the listed-and-registered names. Pre-fix symptom (issue #267): the headless coordinator persona — and any session driven through `tau run --system-prompt-file` — saw only `__activate_skill__` and could not call `Bash`, `Read`, `Edit`, `Write`, or `Agent`. Silent because the assistant simply has no toolbox to emit calls from; nothing crashes, no error surfaces, the persona just appears inert. The fix lives in `Tau.Session`'s `:start_provider` assembly (`model_visible_tool_specs/1` + `active_skill_tool_specs/1` + `tool_spec_for/1`) — building tool specs anywhere else would re-introduce the silent surface. (D-059.)
- **★ [C94-B4]** Prompt templates MUST resolve at slash-command time in `classify_slash_command/4` (`lib/tau/session.ex`). Collision precedence is `builtin > extension > file-command > skill > template`: a template named identically to a built-in or skill is shadowed by the higher-precedence entry. Resolution is a pure prompt-rewrite — `Tau.PromptTemplates.render/3` performs a single, non-recursive named-variable substitution pass on the template body, then rewrites `%Tau.Message.User{}.content` to the rendered body and returns the existing `{:sync, msg}` shape. The rendered message enters the session turn as an ordinary user turn; no new FSM state, no new process, no new cast handler is introduced. Discovery (`Tau.PromptTemplates.discover/1`) runs once at `Session.init/1` time and the result is stored on `data.prompt_templates` (plain FSM data, exactly as `data.skills`). (D-076.)

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
- **★ [C50-B6]** Tool-call iteration cap value is read from `opts[:max_tool_iterations]` at session init, falling back to `get_in(Settings.Cache.get(), [:session, :max_tool_iterations])`, then defaulting to 100. The cap is snapshotted at session start, not re-read each turn (D-007 consistency). A new session inherits any settings change, but in-flight sessions use their init-time cap. This is the correct behaviour for D-007 compliance; naming it as a constraint so future callers know the precedence order.
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

**47 raw constraints**, of which **27 are non-obvious (★)**. Threshold (5–12) exceeded — appropriate for a 5/5 triage component.

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
INV (headless run — D-058 / #252 / Closes #213)
  - `tau run <prompt>` MUST drive a full Tau.Session FSM (start_session → send
    → PubSub event drain → stop), NOT call provider.stream/3 directly. The FSM
    provides: tool registration (Agent, Bash, all builtins), JSONL persistence,
    PubSub lifecycle events, and permissions enforcement. A headless run that
    bypasses the FSM cannot support the Agent tool (M1 self-hosting requirement).
  - The headless run loop MUST subscribe to "session:<id>" PubSub BEFORE calling
    Tau.start_session/1 (D-004 compliance — SessionStart is broadcast
    synchronously inside FSM init and would be lost if subscription comes after).
  - The drain loop MUST decide continuation vs. termination in this order:
    1. CONTENT-FIRST (f-2 fix): if msg.content contains ANY %{type: :tool_call}
       block, CONTINUE regardless of stop_reason. This is required because Gemini
       and Bedrock emit stop_reason: :stop even on tool-call turns (finishReason:
       "STOP" for all turns). The Session FSM itself dispatches tools by content
       (session.ex ~line 1806: Enum.filter(msg.content, &match?(%{type: :tool_call}, &1)));
       the drain loop MUST mirror that decision. Exiting on a Gemini tool-call
       turn (stop_reason :stop, tool_call content present) kills the session
       before the FSM dispatches the tool — tau run --provider gemini cannot
       complete any tool-using turn. The :tool_use stop_reason (Anthropic/OpenAI)
       is subsumed by this check; those providers always populate tool_call content
       blocks alongside :tool_use, so step 1 catches them.
    2. FAILURE stop_reasons → exit 1. The explicit failure set:
         :error            — session-level error
         :tool_loop_aborted — tool iteration cap reached
         :aborted          — coding-agent subprocess exited with status -2
         :compaction_failed — 3 consecutive compaction failures
    3. Everything else (:stop, :length, :stop_sequence, :end_turn,
       :content_filter, and any future provider atom) MUST be treated as a
       completed turn → exit 0. This inversion ensures new provider atoms
       default to success rather than misreporting as crashes.
  - On MessageEnd with tool_call content: continue waiting (step 1 above). Do NOT exit.
  - On MessageEnd with stop_reason in the failure set: print to stderr,
    call Tau.stop/1, await SessionEnd. Exit code 1.
  - On MessageEnd with any other stop_reason (and no tool_call content): print
    assistant text to stdout, call Tau.stop/1 to flush JSONL, await SessionEnd.
    Exit code 0.
  - Tau.stop/1 MUST be called on every exit path INCLUDING the timeout branch so
    JSONL is flushed. After calling Tau.stop/1, drain_session_end/2 MUST be
    awaited (bounded 10 s) before returning — the timeout branch is NOT exempt.
    (Closes [C83-B2].)
  - --system-prompt <text> (and --system-prompt-file <path>) inject the text
    as a %Tau.Skill{} with :persona_lifetime :session. The skill is prepended
    to data.skills in Session.init/1 (before prepend_skill_messages/2 runs) so
    the body reaches the model-visible system blob. Setting only active_skill
    (without adding to data.skills) is NOT sufficient — active_skill gates
    permissions only, not system blob content. No new injection mechanism is
    introduced; the skill enters via the existing prepend_skill_messages/2 path.
    The seam is intentionally minimal — coordinator persona is a separate concern.
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
INV (active-skill tool exposure — D-059 / #267 / Closes [C84-B5])
  - When data.active_skill is set at :start_provider time, stream_opts.tools
    MUST include the active skill's allowed_tools as discrete tool specs,
    not just the synthetic __activate_skill__ tool. Semantics mirror
    `Tau.Tools.Builtin.Agent.whitelist_from/1`:
      * allowed_tools == []   ⇒ every registered built-in (Tau.Tool.list/0)
                                 is exposed (the "unrestricted persona" case
                                 that build_headless_skill/1 produces);
      * allowed_tools == [..] ⇒ only the listed-and-registered names.
  - The __activate_skill__ tool MUST still be present whenever
    model_invokable_skills(data.skills) is non-empty, so the model retains
    the skill-swap UX inside an active persona.
  - The assembly site is `Tau.Session.model_visible_tool_specs/1`
    (consuming `skill_activation_tool_spec/1` + `active_skill_tool_specs/1`
    + `tool_spec_for/1`); replicating the logic elsewhere is forbidden —
    a divergent caller is how C84 surfaced in the first place.
INV (single-provider mid-stream-error retry — D-061 / #303)
  - When a mid-stream `%PEvent.Error{retryable?: true}` arrives AND
    `fallback_chain_remaining == []` (ADR-0012 fallback inapplicable —
    session configured against a single provider OR chain exhausted),
    the FSM MUST re-issue `:start_provider` on the SAME provider up
    to `provider_retry_max` times before surfacing a terminal error.
    The backoff between attempts MUST be `provider_retry_base_delay_ms
    * 2^count` (exponential), implemented non-blockingly via
    `Process.send_after/3` so the FSM mailbox stays serviceable for
    `:cancel` and other inbound events during the wait. Each retry
    MUST emit `[:tau, :session, :provider_retry]` telemetry with
    measurements `%{count: N, delay_ms: D}` and metadata
    `%{session_id, provider, reason, max}`, and broadcast a
    `%SystemNotice{}` whose text names the wedged provider, the
    reason, and the `N/max` count. The retry counter MUST reset to
    zero on (a) every clean return to `:awaiting_user`, (b) every
    successful Done finalization, (c) every iteration-cap or
    brake-abort, and (d) every cancel. Exhaustion (count == max) MUST
    fall through to the existing terminal-error path (the generic
    `:provider_event` clause finalizing with `stop_reason: :error`).
    The ADR-0012 fallback clause MUST take precedence when a chain
    is still present — same-provider retry is the fallback-of-last-
    resort, not a primary recovery mechanism. Threshold MUST be
    configurable; precedence: `opts[:provider_retry_max]` > Settings.
    Cache `[:session, :provider_retry_max]` > default 3. Base delay
    likewise: `opts[:provider_retry_base_delay_ms]` > Settings.Cache
    `[:session, :provider_retry_base_delay_ms]` > default 1000ms.
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
    (default N=100, configurable via Tau.Settings or per-session opt;
    bumped from 20 in #312 — real factory cycles legitimately exceed 20).
    Cap precedence: opts[:max_tool_iterations] > Settings.Cache
    [:session, :max_tool_iterations] > default 100. Cap snapshotted at
    session init (D-007 compliance — mid-session settings reloads do
    NOT change the cap for in-flight sessions). ([C50])
    On overflow: emit [:tau, :session, :tool_iteration_cap] telemetry
    with measurements %{iterations: N, cap: K} (N = completed dispatches
    in the aborted turn, equals K at abort boundary) and metadata
    %{session_id: id}, append and persist an Assistant message with
    stop_reason: :tool_loop_aborted, broadcast MessageEnd, return to
    :awaiting_user. (Closes [C24], implements D-027 / AC-6.)
INV (identical-args tool-call brake — D-060 / #293)
  - Sibling circuit-breaker to the iteration cap: within one turn,
    `tool_loop_brake_threshold` consecutive `is_error: true` results
    for the SAME `{tool_name, args_hash, error_message}` triple MUST
    abort the turn with `stop_reason: :tool_loop_aborted`, emit
    `[:tau, :session, :tool_loop_brake]` telemetry, and broadcast a
    `%SystemNotice{}` whose text names the wedged tool, the count,
    and the verbatim error string. Different args OR a different
    error message MUST NOT compound the count. A successful tool
    result MUST clear the WHOLE per-turn brake map (the model has
    un-wedged). Default threshold 3; configurable via
    `opts[:tool_loop_brake_threshold]` or Settings.Cache
    `[:session, :tool_loop_brake_threshold]`. (D-060.)
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
| D-027 | Session FSM MUST cap tool-call iterations per turn at `max_tool_iterations` (default 100 — bumped from 20 in #312 because real factory cycles legitimately exceed 20, D-060 + D-061 cover the runaway-loop class; readable from `opts[:max_tool_iterations]` or `Settings.Cache.get()[:session][:max_tool_iterations]`). When the cap is exceeded, the FSM MUST emit `[:tau, :session, :tool_iteration_cap]` telemetry with measurements `%{iterations: N, cap: K}` — where `N` is the count of completed dispatches in the aborted turn (equals `K` at the abort boundary; resets to 0 at the start of the next turn) — and metadata `%{session_id: id}`, then abort the turn with `stop_reason: :tool_loop_aborted`. The per-turn counter resets to 0 on every return to `:awaiting_user`. | high | property test `test/tau/session/tool_iteration_cap_property_test.exs`: drives a session backed by bespoke `AlwaysToolCallProvider` (a `Tau.Provider` behaviour implementation that always emits a `tool_call` event stream, independent of Replay); asserts turn terminates within `max_tool_iterations` with `stop_reason: :tool_loop_aborted` and that the telemetry event fires with `iterations == cap` | [C24], [C50] |
| D-028 | Assistant text content rendered to the TUI transcript MUST be parsed as CommonMark with GFM tables before display. Raw markdown source MUST NOT appear in the rendered pane for valid CommonMark input. **TUI path** (`Tau.TUI.Render.Markdown`): output is a list of `{content, attrs}` tuples rendered as styled Ratatouille labels. Unicode box-drawing glyphs (e.g. `▌` for blockquotes, `─` for horizontal rules) and inline styling attrs (bold for headings/strong, underline for em) ARE permitted — the grapheme-aware `smug-haus/ratatouille` fork (merged via #190) replaces the upstream 0.5.1 `Renderer.Cells.to_char/1` which crashed on multi-byte UTF-8 label content; the ASCII-only + markers-stripped constraint was a workaround for that crash and is removed by this PR. Block-level nodes (paragraphs, headings, lists, code blocks, blockquotes, hr) MUST be separated by a blank `{"", []}` spacer entry so multi-paragraph prose does not collapse into a single wall of text. On parse error, a `[markdown-parse-error]` prefix surfaces the failure rather than silently dropping the content. **Headless path** (`Tau.Markdown`): unchanged — ASCII-only output with bold/italic markers stripped and inline-code backticks preserved; this path is unaffected by the Ratatouille fork. | medium | unit tests on `Tau.TUI.Render.Markdown.render/1`: styled heading produces `{text, [attributes: [:bold]]}` tuple; multi-paragraph input produces a `{"", []}` spacer between paragraphs; blockquote line begins with `▌`; hr line is `─` repeated; unit test on `Tau.Markdown.render/1` over a fixture with table + bold + inline code + fenced code asserting ASCII pipe-and-plus tables and no Unicode box-drawing chars (headless path unchanged) | [C52-B5] |
| D-040 | A plain (non-Burrito) `mix release` boot with no explicit CLI-dispatch marker (`TAU_CLI_ARGV`) MUST NOT dispatch the Tau CLI and MUST NOT call `System.halt`. Positional VM arguments passed to the release launcher (`bin/tau start`) MUST NOT be consulted for dispatch. The `TAU_CLI_ARGV` marker is consumed-and-deleted (`System.delete_env/1`) by `Tau.Application.cli_argv/0` immediately after reading so it is NOT inherited by tau-spawned subprocesses. Encoding: tokens are joined by ASCII Unit Separator (`\x1f`); `Tau.Application.encode_cli_argv/1` is the single source of truth — no other code path may duplicate the separator literal. | high | `test/tau/application/cli_argv_test.exs` (all six tests); `test/tau/cli/tui_smoke_test.exs` AC-H1 and AC-H2 against `_build/prod/rel/tau/bin/tau` | [C53-B2] |
| D-041 | `data.model` in the session FSM MUST be treated as immutable within a provider turn. `Tau.Session.swap_model/2` is the sole sanctioned mid-session mutation of `data.model`, gated to `:awaiting_user` state with `command_task == nil`; any other state MUST return `{:error, :busy}`. `do_swap_model/2` is the single `data.model` mutation site ([C54-B4]). On success the FSM MUST emit `[:tau, :session, :model_swapped]` telemetry and persist a `model_swap` JSONL event. The persisted event is folded back into `data.model` on resume/fork via `model_from_preload/1` in `init/1`. | high | `test/tau/session/swap_model_test.exs` — 7 cases covering success, busy, JSONL persistence, not_found, idempotent, invalid_model (empty + whitespace) | [C54-B4], [C29] |
| D-042 | A built-in slash command MUST NOT drive a provider or coding-agent turn. When `Tau.Commands.Parser.lookup_builtin/1` resolves a command name, the FSM dispatches `mod.run(args, data)` and handles the typed outcome inline: `{:notice, _}`, `{:mutate, _, _}`, and `{:error, _}` branches return `{:keep_state, data}` or `{:keep_state, data2}` — they MUST NOT call `process_user_message/2`. Only `:passthrough` may proceed to `process_user_message/2`. On every dispatch the FSM MUST emit `[:tau, :session, :builtin_command]` telemetry with metadata `%{session_id: id, command: name, outcome: tag}`. Built-in lookup precedes extension lookup (`[C55-B4]`). The `{:async_compact, binary}` outcome (new) changes FSM state to `:compacting` — the single exception to the stateless-builtin rule, governed by [C67-B4]. | high | `test/tau/session/builtin_command_dispatch_test.exs` — D-042 proof: drive `/ping` into a session backed by `RecordingProvider` that records `stream/3` calls; assert zero provider calls, a `SystemNotice` with `"pong"` is broadcast, FSM snapshot is responsive; assert `[:tau, :session, :builtin_command]` telemetry fires with correct metadata | [C55-B4] |
| D-048 | **:compacting-state exit invariant (C67-B4).** Every exit edge from the `:compacting` gen_statem state MUST land in `:awaiting_user` with both `data.compaction_task` and `data.compaction_monitor` set to `nil`. Five terminal clauses cover all exit paths: (1) worker success `{ref, result}`; (2a) benign `{:DOWN, :normal}` (keep-state, result pending); (2b) crash `{:DOWN, reason}`; (3) live timeout; (4) stale timeout (no-op). `{:next_state, :awaiting_user, data}` is the return form for clauses 1, 2b, 3; clause 2a uses `{:keep_state, data}` because the result message is still pending. | high | `test/tau/session/compaction_test.exs`: happy path; postpone-and-flush; stale-result-drop after cancel; `:swap_model` busy during `:compacting` | [C67-B4] |
| D-049 | **Compaction worker crash/timeout/cancel recovery (C67-B4).** The session FSM MUST NOT wedge when the compaction worker crashes, times out, or is cancelled — it MUST return to `:awaiting_user`. It MUST NOT trigger a spurious crash-recovery notice when `{ref,result}` and `{:DOWN, :normal}` arrive back-to-back (the double-message race). Achieved by: Clause 2a (`{:DOWN, :normal}`) is a `{:keep_state}` that preserves the pending result, so Clause 1 still processes it; all five typed clauses clear worker fields, so stale messages fail guards and reach the catch-all no-op. | high | `test/tau/session/compaction_test.exs`: worker-crash recovery (session not wedged); race test `{ref,result}` + `{:DOWN}` × 50 (NO spurious crash recovery); late-timeout-after-success (no FSM crash); `/cancel` outside `:compacting` (no FSM crash) | [C67-B4] |
| D-056 | **Copilot API token refresh contract (C82-B8).** `Tau.Providers.Copilot.Auth.token/1` MUST refresh the short-lived API token when `expires_at - now < 5 min` (300,000 ms). The refresh path is: (1) call `resolve_oauth/1` to obtain the long-lived OAuth token; (2) `POST https://api.github.com/copilot_internal/v2/token` with `Authorization: token <oauth_token>`; (3) parse `{"token": "...", "expires_at": "ISO8601"}` from the 200 response; (4) store the result in `Tau.Providers.Copilot.TokenStore` (supervised GenServer, NOT module-level state). Any non-200 response or network error MUST return `{:error, :oauth_refresh_failed}` and emit `[:tau, :copilot, :auth, :refresh_failed]` telemetry. Missing OAuth token MUST return `{:error, :no_auth}`. All errors MUST surface a user-actionable message via `Auth.describe_error/1` naming the `gh auth login --scopes copilot` renewal path. | high | `test/tau/providers/copilot/auth_test.exs`: hosts.json parsing; apps.json fallback; env-var override; refresh/1 success (Bypass stub); refresh/1 non-200 → `:oauth_refresh_failed`; token/1 proactive-refresh when nearing expiry; token/1 skips refresh when token is fresh; missing file → `:no_auth`; malformed JSON → `:oauth_malformed` | [C82-B8] |
| D-059 | **Active-skill tool exposure (C84-B5).** When `data.active_skill != nil` at `:start_provider` time, `stream_opts.tools` MUST include the active skill's `allowed_tools` as discrete tool specs — never just the synthetic `__activate_skill__` tool. Empty `allowed_tools` MUST be treated as "no whitelist declared" and expose every registered built-in via `Tau.Tool.list/0` (mirroring `Tau.Tools.Builtin.Agent.whitelist_from/1`); a non-empty list MUST expose only the listed-and-registered names (unknown names are silently skipped, matching `Tau.Permissions.Evaluator`'s posture). The `__activate_skill__` tool MUST still be present when other model-invokable skills exist on `data.skills`, so the persona-swap UX survives. The single assembly site is `Tau.Session.model_visible_tool_specs/1`; duplicating the logic at a second site (provider adapter, transformer, etc.) is forbidden. | high | `test/tau/session/active_skill_tool_exposure_test.exs`: unrestricted skill exposes every built-in by name (not just `__activate_skill__`); restricted skill (`allowed_tools: ["Bash"]`) exposes `Bash` and refutes `Read/Write/Edit/Agent`; unknown names in `allowed_tools` are silently skipped | [C84-B5] |
| D-058 | **Headless FSM-backed `tau run` (C83-B2).** `tau run <prompt>` MUST start a full `Tau.Session` FSM via `Tau.start_session/1`, send the prompt via `Tau.send/2`, and consume the PubSub event stream until `%SessionEnd{}`. It MUST NOT call `provider.stream/3` directly (which bypasses tools, JSONL persistence, and permissions). The PubSub subscription MUST be established BEFORE `Tau.start_session/1` returns (D-004). `Tau.stop/1` MUST be called on every exit path (failure, success, timeout) to flush JSONL before the process exits; the timeout path MUST also await `drain_session_end/2` (bounded 10 s) before returning. **Turn-completion is decided by content, not `stop_reason` (f-2 fix):** a `MessageEnd` whose `msg.content` contains any `%{type: :tool_call}` block MUST be treated as a continuation regardless of `stop_reason` — Gemini/Bedrock emit `stop_reason: :stop` on tool-call turns. The drain loop checks content first (mirroring session.ex ~line 1806), then failure stop_reasons, then defaults to completed-turn. Exit code: 1 iff the stop_reason is in the explicit failure set `[:error, :tool_loop_aborted, :aborted, :compaction_failed]` or `%SessionEnd{reason: :error}` arrives (and no tool_call content was present); 0 for every other completed turn (`:stop`, `:length`, `:stop_sequence`, `:content_filter`, and any future provider atom). This inversion ensures new provider atoms default to success rather than misreporting as crashes. `--system-prompt <text>` and `--system-prompt-file <path>` inject the text as `%Tau.Skill{}` with `:persona_lifetime :session`; the skill is prepended to `data.skills` in `Session.init/1` BEFORE `prepend_skill_messages/2` runs so it reaches the model-visible system blob — setting only `active_skill` is NOT sufficient. | high | `test/tau/cli/headless_run_test.exs` (AC-10): replay run exits 0; JSONL persisted; :length → exit 0; :tool_loop_aborted → exit 1; :error → exit 1; :stop_sequence → exit 0; :tool_use continuation; tool_call-content+:stop (Gemini shape) → continuation (f-3); run_cmd/1 end-to-end (f-4); --system-prompt body in session messages; helper unit tests; CLI option parser | [C83-B2] |

| D-060 | **Identical-args tool-call brake (#293).** Sibling circuit-breaker to D-027 (iteration cap). The session FSM MUST track, per turn, a map keyed by `{tool_name, args_hash}` where `args_hash` is a SHA-256 of the canonical JSON encoding of the call arguments (keys recursively sorted; semantically-equal maps collide regardless of insertion order). On every `is_error: true` `%ToolResult{}` the FSM MUST bump that key's counter iff the result content matches the previously-recorded `error` string for the same key; a different error string MUST reset the counter to 1 and re-seed the cell with the new error. A successful (`is_error: false`) result MUST clear the WHOLE per-turn brake map. When any cell's counter reaches `tool_loop_brake_threshold` (default 3, readable from `opts[:tool_loop_brake_threshold]` or `Settings.Cache.get()[:session][:tool_loop_brake_threshold]`) the FSM MUST: (1) emit `[:tau, :session, :tool_loop_brake]` telemetry with measurements `%{count: N}` and metadata `%{session_id, tool_name, args_hash, error}`; (2) broadcast a `%SystemNotice{}` whose text names the wedged tool, the count, the verbatim error string, and ends with "Halting this turn."; (3) append and persist an `%Assistant{stop_reason: :tool_loop_aborted, content: [%{type: :text, text: <notice>}]}` message; (4) broadcast `%MessageEnd{}` and return to `:awaiting_user` with `tool_loop_state` and `tool_loop_call_lookups` cleared. The brake key includes BOTH tool name AND args hash — legitimate retries with DIFFERENT arguments MUST NOT trip it. The error message is part of the key in effect (a different error resets the count) — a transient network error followed by a schema error MUST NOT compound. Threshold MUST be configurable; default 3. | high | `test/tau/qa/tool_loop_brake_test.exs`: positive case (3 identical empty-args calls to a tool with `required: ["description"]` → brake fires, SystemNotice text contains "identical arguments 3x in a row", `:tool_loop_brake` telemetry fires, FSM returns to `:awaiting_user`); negative case (3 calls with varied `{n}` args → brake stays silent, the iteration-cap (D-027) is what terminates the turn instead) | #293 |
| D-061 | **Single-provider mid-stream-error retry (#303).** The session FSM MUST recover from a `%PEvent.Error{retryable?: true}` even when `data.fallback_chain_remaining == []` (the common single-provider case, or an exhausted ADR-0012 chain). Within one turn, the FSM MUST re-issue `:start_provider` on the SAME provider up to `provider_retry_max` times (default 3, readable from `opts[:provider_retry_max]` or `Settings.Cache.get()[:session][:provider_retry_max]`) with exponential backoff `provider_retry_base_delay_ms * 2^count` (default base 1000ms, readable from `opts[:provider_retry_base_delay_ms]` or `Settings.Cache.get()[:session][:provider_retry_base_delay_ms]`). The backoff MUST be implemented non-blockingly via `Process.send_after/3` posting a `{:provider_retry, count}` info message back to the FSM, NOT `:timer.sleep/1`, so the FSM mailbox remains serviceable for `:cancel` during the wait. Each retry attempt MUST: (1) emit `[:tau, :session, :provider_retry]` telemetry with measurements `%{count: N, delay_ms: D}` and metadata `%{session_id, provider, reason, max}`; (2) broadcast a `%SystemNotice{}` whose text names the wedged provider, the reason, and the `N/max` count; (3) brutally kill the prior `provider_task` (mirroring the ADR-0012 fallback path) AND emit `[:tau, :provider, :request, :brutal_kill]` (via `emit_provider_request_terminal/2`) so the OTel reporter closes the open span; (4) increment `provider_retry_state.count` BEFORE scheduling the retry (so concurrent in-flight errors cannot push the count past `max`); (5) clear `provider_task`, `assembler`, `stream_ref`, and `provider_span_ref` before scheduling. The counter MUST reset to zero on EVERY return to `:awaiting_user` (clean Done, iteration-cap abort, brake-abort, compaction abort, and cancel). Exhaustion (`count == max`) MUST fall through to the generic `:provider_event` clause which finalizes with `stop_reason: :error` — the existing terminal-error path is unchanged. The same-provider retry clause MUST precede the ADR-0012 fallback clause in source order; both head-match `%PEvent.Error{retryable?: true}` but discriminate on `fallback_chain_remaining` (empty vs `[next \| rest]`), and the source-order precedence keeps the fallback path winning when a chain exists. | high | `test/tau/session/provider_retry_test.exs`: positive case (stub emits `Error{retryable?: true}` × 2 then `Done{stop_reason: :stop}` → session reaches `:awaiting_user` with NO `:error`, `:provider_retry` telemetry fires twice with counts 1 and 2); exhaustion case (stub emits `Error{retryable?: true}` × 4 with `max: 3` → `:error` stop_reason after exactly 3 retries; SystemNotice text contains retry-exhaustion language); non-retryable boundary (stub emits `Error{retryable?: false}` once → immediate `:error`, no `:provider_retry` telemetry) | #303 |
| D-062 | **Compactor split boundary preserves tool_use/tool_result pairing (#310).** `Tau.Compactor.SummarizeTail.compact/2` MUST NOT produce a post-compact conversation history whose first preserved (recent) message is a `%Tau.Message.ToolResult{}` with no preceding `%Tau.Message.Assistant{}` carrying the matching `tool_use` block. The 60%-length split cutoff is a heuristic that can land between an `%Assistant{stop_reason: :tool_use}` and its corresponding `%ToolResult{}` messages; the Anthropic API (and Anthropic-shaped APIs) reject such histories with HTTP 400. After `Enum.split(conv, cutoff)`, any leading `%ToolResult{}` messages in the `recent` half MUST be moved into the `old` half before `summarise/2` is called. This is implemented as `realign_split_at_tool_boundary/1` applied to the `{old, recent}` tuple. The invariant is: for every `%ToolResult{tool_call_id: id}` in the preserved (recent) portion, there MUST be a `%Assistant{}` in that same portion whose `content` list contains a block matching `%{type: :tool_call, id: id}`. | high | `test/tau/compactor/summarize_tail_test.exs`: "split boundary is realigned to avoid orphan tool_results (D-062 / #310)" — constructs a 5-message conversation whose pure 60%-split puts a `ToolResult` first in `recent`; asserts post-compact recent does NOT begin with `ToolResult` and that every `ToolResult` in recent has a matching `Assistant` tool_call block; "split at an already-clean boundary is unaffected by realignment (D-062)" — 10-message conversation whose 60%-split is already clean; asserts same pairing invariants hold and no messages are misrouted | #310 |
| D-076 | **Prompt-template variable substitution is a pure, total function (#183 / C94-B4).** `Tau.PromptTemplates.render/3` MUST perform static text + named-variable replacement only — a single, non-recursive substitution pass. It MUST NOT invoke a shell, read a file, evaluate embedded code, or re-scan substituted text. An unknown or unbound `{{var}}` token MUST render as the literal `{{var}}` and emit `[:tau, :prompt_template, :unknown_variable]` telemetry rather than raising. The function MUST return `{:ok, rendered_body}` for all inputs (total). **Rationale:** D-076 constrains the *substituter*, not the *body* — an untrusted template body remains a prompt-injection surface equivalent to an untrusted skill body. D-076 closes the substituter as a code-execution vector; it does not make the body safe from prompt injection. | high | `test/tau/prompt_templates_test.exs`: render with known variables substituted; unknown variable renders as literal and emits telemetry (`:telemetry_test`); surplus args ignored with `:info` telemetry; `{{args}}` receives raw pre-tokenisation tail; single-pass (a value containing `{{x}}` is not re-substituted); function never raises on any input (property test over random bodies + args) | [C94-B4] |
| D-077 | **Two-tier message queue contract (#339).** The session FSM MUST maintain two explicit FIFO queues on its data struct: `steering_queue` (messages tagged `:steering`, intended for delivery at the next tool-round boundary) and `followup_queue` (messages tagged `:followup`, intended for delivery on the next `:awaiting_user` entry). Both queues are OTP `:queue` FIFO structures. `Tau.steer/2` routes to `:steering`; `Tau.send/2` routes to `:followup`. When the session is already in `:awaiting_user` and has no `command_task` in flight, both tiers deliver immediately (the queuing path is bypassed). The queues are separate from ADR-0008's `command_task != nil` postpone mechanism, which is unaffected by this change. **Rationale (ADR-0021):** the ADR-0009 postpone primitive is replaced by explicit queues for the non-command_task path; explicit queues make tier semantics testable, capped, and introspectable via `snapshot/1`. | high | `test/tau/session/message_queue_tiers_test.exs`: D-077/D-078 tier routing tests; property test for FIFO order (D-080/D-081). | #339 |
| D-078 | **`Tau.steer/2` public API contract (#339).** `Tau.steer/2` is the sanctioned way to route a user message to the steering tier. It is behaviorally identical to `Tau.send/2` when the session is idle (`:awaiting_user` with no command task): both deliver immediately. When the session is busy, `Tau.steer/2` enqueues to `steering_queue`; `Tau.send/2` enqueues to `followup_queue`. Both functions return `:ok` (cast semantics). The TUI MUST use `Tau.steer/2` for `Enter`-while-busy and `Tau.send/2` for `Alt+Enter`-while-busy. Status-bar keybinding hints MUST reflect the current state (idle vs busy), naming the correct action for each key. | high | `test/tau/session/message_queue_tiers_test.exs`: AC-10 idle-steer test. `test/tau/tui/app_test.exs`: status bar hint per state. | #339 |
| D-079 | **Steering queue drain at the tool-round boundary and at turn-end (#339 / FIX-4).** When the session FSM completes a tool round (`map_size(tools_in_flight) == 0` in the `{:tool_done}` handler), it MUST drain exactly ONE message from `steering_queue` (if non-empty) by calling `drain_steering_queue_one/1` BEFORE re-entering `:start_provider`. The drained message is appended to `data.messages` via `append_message/2` and persisted as a `user_message` JSONL event. This guarantees that a steering message sent while tools are executing appears in the conversation history AFTER all tool_call/tool_result pairs from that round and BEFORE the next provider call — the AC-8 ordering invariant. **Turn-end steering drain (FIX-4):** If a pure-text turn (no tool calls) completes and `steering_queue` is non-empty, the remaining steering messages MUST be merged into the front of `followup_queue` (so they drain first via `:drain_followups`) and `steering_queue` MUST be cleared to `:queue.new()`. This prevents stale steering context from bleeding into the next unrelated turn's tool-round boundary. A steering message MUST NOT survive into a later turn that was not the one it was queued for. | high | `test/tau/session/message_queue_tiers_test.exs`: D-079/AC-8 steering-at-tool-round-boundary test; D-079/D-082 pure-text-turn steering drain test (FIX-4: steer runs at turn-end, steering_queue empty after). | #339 |
| D-080 | **Follow-up queue drain on `:awaiting_user` entry (#339).** On EVERY `{:next_state, :awaiting_user, next_data, actions}` transition, the FSM MUST append `{:next_event, :internal, :drain_followups}` to `actions` when `followup_queue` is non-empty (D-080). The `:drain_followups` internal handler dequeues one message from `followup_queue` and routes it through the full `handle_event(:cast, {:user_message, msg, :followup}, :awaiting_user, data)` dispatch path — including `classify_slash_command/4` — so slash commands queued as follow-ups are correctly dispatched. The drain is one-at-a-time; each follow-up turn's natural completion re-fires `drain_followups` if the queue is still non-empty. **Rationale:** routing through the full dispatch path (not `process_user_message/2`) ensures slash commands in the follow-up queue are classified, not silently sent to the provider as plain text. | high | `test/tau/session/message_queue_tiers_test.exs`: D-080/D-081 FIFO property test (n follow-up messages delivered in cast order). `test/tau/session/lifecycle_builtin_dispatch_test.exs`: `/reload` queued as follow-up is correctly dispatched (not passed to provider). | #339 |
| D-081 | **Follow-up FIFO ordering invariant (#339).** `followup_queue` is an OTP `:queue` FIFO. Messages dequeued via `:drain_followups` MUST arrive at the session in the order they were enqueued by `Tau.send/2` calls. The JSONL transcript MUST list `user_message` events for follow-up messages in enqueue order. | high | `test/tau/session/message_queue_tiers_test.exs`: D-080/D-081 FIFO property test (verifies JSONL ordering for 2..5 follow-up messages across 6 random runs). `test/tau/session/user_message_queue_test.exs`: existing ordering property. | #339 |
| D-082 | **Cancel drains steering queue via `%QueueRestored{}` (#339).** When `Tau.cancel/1` is called, the FSM MUST: (1) convert `steering_queue` to a list via `:queue.to_list/1`; (2) if the list is non-empty, broadcast `%Tau.Session.Events.QueueRestored{session_id: id, messages: list}` on the session's PubSub topic; (3) clear `steering_queue` to `:queue.new()`; (4) preserve `followup_queue` unchanged (follow-up messages survive a cancel and are drained on the post-cancel `:awaiting_user` entry). The TUI MUST handle `%QueueRestored{}` by repopulating the input editor from `messages` (joining with newline), allowing the user to review, edit, or re-submit the intercepted steer. Receivers MUST treat `%QueueRestored{}` as idempotent. | high | `test/tau/session/message_queue_tiers_test.exs`: D-082 cancel-with-steering test (QueueRestored received, steering cleared, followup preserved); D-082 cancel-without-steering test (QueueRestored NOT broadcast). | #339 |
| D-083 | **Two-tier queue hard cap (#339).** Each queue (steering and followup) is capped at 32 messages. A message that would push either queue past the cap MUST be dropped (no crash, no wedge). The drop MUST emit a `%SystemNotice{}` on the session's PubSub topic so the user knows the message was not queued, AND emit `[:tau, :session, <tier>, :dropped]` telemetry. Callers that need programmatic feedback can also observe `snapshot/1.queues` to detect a full queue. The cap is enforced in the `state != :awaiting_user` queue-routing clause before the enqueue. `snapshot/1` MUST expose the current queue contents as `queues: %{steering: [...], followup: [...]}` where each list contains the `%Tau.Message.User{}` structs in FIFO order. | medium | `test/tau/session/message_queue_tiers_test.exs`: D-083/AC-9 followup-cap test (35 messages → queue ≤ 32, FSM alive); D-083/AC-9 steering-cap test (35 steers → queue ≤ 32, cancel succeeds). | #339 |

42 D-xxx entries. Each is enforceable. None require speculation.

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
- A property test runs a session backed by a bespoke `AlwaysToolCallProvider` (a `Tau.Provider` behaviour implementation that always emits a `tool_call` event stream). The session terminates within `max_tool_iterations` (default 100) with `stop_reason: :tool_loop_aborted`.

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

### AC-10: Headless FSM-backed run (D-058, C83-B2, #252, Closes #213)

- `tau run "prompt" --provider replay --model replay` MUST:
  - Start a full `Tau.Session` FSM (not a bare provider.stream/3 call).
  - Print the assistant text response to stdout.
  - Exit with code 1 iff stop_reason is in the explicit failure set
    `[:error, :tool_loop_aborted, :aborted, :compaction_failed]`.
  - Exit with code 0 for every other completed turn (`:stop`, `:length`,
    `:stop_sequence`, `:content_filter`, and any future provider atom).
    This inversion ensures new provider atoms default to success rather than
    misreporting as crashes.
  - Continue looping (not exit) when `msg.content` contains any `%{type: :tool_call}` block,
    regardless of `stop_reason` (f-2 fix — content-first rule). Gemini and Bedrock emit
    `stop_reason: :stop` on tool-call turns; keying on `stop_reason` alone exits the session
    before the FSM can dispatch the tool. The `:tool_use` stop_reason case is subsumed:
    Anthropic/OpenAI always populate tool_call content alongside `:tool_use`.
  - Persist the session to JSONL; `tau sessions list` shows the session after the run.
- `tau run "prompt" --system-prompt "text"` injects the text into the model-visible
  system blob; the skill body MUST appear in `data.messages` as a system-role
  skill message after `Session.init/1` completes.
- `tau run "prompt" --system-prompt-file <path>` reads the file and applies it the same way.
- **D-059 (tool exposure under an active skill).** A `tau run` invocation whose
  active skill carries `allowed_tools: []` (the `build_headless_skill/1`
  default — e.g. `--system-prompt-file` for an unrestricted persona like
  `tau-coordinator`) MUST receive every registered built-in tool
  (`Tau.Tool.list/0`) in `stream_opts.tools` on the first provider call.
  An active skill with `allowed_tools: [names]` MUST receive only those
  listed-and-registered tools. The synthetic `__activate_skill__` tool
  MUST coexist with the discrete tool specs whenever other model-invokable
  skills are discoverable. Without this, the headless coordinator persona —
  and any sub-agent persona pinned via `Tau.Tools.Builtin.Agent` — is inert:
  the model has no callable tool but the skill-activation entry point and
  cannot drive the M1 self-hosting loop. Tested in
  `test/tau/session/active_skill_tool_exposure_test.exs` (#267).
- The timeout exit path MUST also call `Tau.stop/1` and await `drain_session_end/2`
  (bounded 10 s) before returning exit code 1 (B3 fix).
- Tests: `test/tau/cli/headless_run_test.exs` — replay run, JSONL persistence,
  stop_reason matrix (:stop/:length/:tool_loop_aborted/:error/:tool_use continuation/
  :stop_sequence), tool_call-content+:stop Gemini shape → continuation (f-3),
  run_cmd/1 end-to-end via real @doc-false entry (f-4, including resolve_system_prompt
  {:error,_} → exit 1), system-prompt body in messages, helper unit tests, CLI option parser.
  Tests exercise `Tau.CLI`'s real public/@doc-false functions, not private duplicates.
- This test runs in CI on every PR and is a blocking gate.

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

| C50 | `lib/tau/session.ex` init/1 — `max_tool_iterations` resolution (opts → Settings.Cache → 100) |
| C53 | `lib/tau/application.ex` — `cli_argv/0` (env-marker read → delete → decode); `test/support/tui_pty_helper.ex` — `start/2` plain-release branch; `test/tau/application/cli_argv_test.exs` |
| C54 | `lib/tau/session.ex` — `do_swap_model/2` (pure mutation core), `apply_model_swap/2` (shared helper with telemetry+persist), `handle_event({:call, from}, {:swap_model, _}, ...)` (gated call handler), `handle_slash_model_swap/2` (/model slash path), `reconfigure_model/2` ({:reconfigure} cast routing); `lib/tau/session/events.ex` — `%SystemNotice{}`; `lib/tau/tui/app.ex` — `%SystemNotice{}` dispatch clause; `test/tau/session/swap_model_test.exs`; `test/tau/session/slash_model_command_test.exs` |
| C55 | `lib/tau/commands/builtin.ex` — `Tau.Commands.Builtin` behaviour + `table/0`; `lib/tau/commands/builtin/ping.ex` — `Tau.Commands.Builtin.Ping` seed entry; `lib/tau/commands/parser.ex` — `lookup_builtin/1`; `lib/tau/session.ex` — `classify_slash_command/2` (builtin arm before extension lookup), `handle_event` `{:builtin, mod, args, msg}` arm, `handle_builtin_command/4`, `outcome_tag/1`; `test/tau/commands/builtin_test.exs`; `test/tau/session/builtin_command_dispatch_test.exs` |
| C67 | `lib/tau/commands/builtin.ex` — `{:async_compact, binary}` in `outcome()` typespec + `@moduledoc`; `lib/tau/commands/builtin/compact.ex` — `Tau.Commands.Builtin.Compact` (pure predicate); `lib/tau/session.ex` — `handle_builtin_command/4` `{:async_compact, notice}` arm (FSM transition to `:compacting`), `outcome_tag({:async_compact, _})`, five terminal `:compacting` clauses (Clauses 1/2a/2b/3/4), guarded `:cancel` demonitor/exit, `init/1` `compaction_task/compaction_monitor/compaction_failures` fields; `docs/spec/SPEC-USER-TURN.md` — D-048, D-049, AC-9, this Appendix B entry; `test/tau/session/compaction_test.exs`; `test/tau/commands/builtin/compact_test.exs` |

| (wire helpers) | `lib/tau/providers/shared/openai_chat_wire.ex` — extracted from `OpenAI.Chat` (PR 1 of #181); `build_body/4`, `decode/2`, `headers/1` are the canonical wire helpers for OpenAI Chat-compatible endpoints. No new D-id or §3 constraint; behaviour-neutral refactor. |

| C68 | `lib/tau/providers/shared/openai_chat_wire.ex` — wire helpers shared by all OpenAI-compatible providers; `lib/tau/providers/shared/tool_spec.ex` — OpenAI-compatible shape clauses for `DeepSeek`, `Groq`, `Mistral`, `AzureOpenAI`, `Custom`; `lib/tau/providers/deepseek.ex` — `Tau.Providers.DeepSeek` (`@behaviour Tau.Provider`); `lib/tau/providers/groq.ex` — `Tau.Providers.Groq` (`@behaviour Tau.Provider`); `lib/tau/providers/mistral.ex` — `Tau.Providers.Mistral` (`@behaviour Tau.Provider`); `lib/tau/cli.ex` — `resolve_provider/1` clauses for `"deepseek"`, `"groq"`, `"mistral"` + `doctor_cmd` key reports for all three; `docs/spec/SPEC-USER-TURN.md` — C68; `docs/providers/deepseek.md`; `docs/providers/groq.md`; `docs/providers/mistral.md`; `test/tau/providers/deepseek_test.exs`; `test/tau/providers/groq_test.exs`; `test/tau/providers/mistral_test.exs` |

| C80 | `lib/tau/providers/azure_openai.ex` — `Tau.Providers.AzureOpenAI` (`@behaviour Tau.Provider`; `azure_headers/1` builds `api-key` header; `build_url/3` composes deployment URL); `lib/tau/providers/shared/tool_spec.ex` — `shape/2` clause for `Tau.Providers.AzureOpenAI`; `lib/tau/cli.ex` — `resolve_provider("azure")` + `resolve_provider("azure-openai")` + `doctor_cmd` Azure key/endpoint/deployment report; `docs/providers/azure_openai.md`; `test/tau/providers/azure_openai_test.exs` |
| C81 | `lib/tau/providers/custom.ex` — `Tau.Providers.Custom` (`@behaviour Tau.Provider`; `build_headers/2` omits `Authorization` when `api_key` nil; `resolve_config/0` returns `{:error, :missing_base_url}` as sole synchronous hard-config error); `lib/tau/providers/shared/tool_spec.ex` — `shape/2` clause for `Tau.Providers.Custom`; `lib/tau/cli.ex` — `resolve_provider("custom")` + `doctor_cmd` Custom base_url/api_key report; `docs/providers/custom.md`; `docs/spec/SPEC-USER-TURN.md` — C81, this Appendix B entry; `test/tau/providers/custom_test.exs` |

| C82 | `lib/tau/providers/copilot/auth.ex` — `Tau.Providers.Copilot.Auth` (`resolve_oauth/1`, `token/1`, `refresh/2`, `describe_error/1`); `lib/tau/providers/copilot/token_store.ex` — `Tau.Providers.Copilot.TokenStore` (supervised GenServer; `get/0`, `put/1`, `clear/0`); `lib/tau/application.ex` — `Tau.Providers.Copilot.TokenStore` child spec; `lib/tau/cli.ex` — `doctor_cmd` Copilot auth-status report; `docs/spec/SPEC-USER-TURN.md` — C82, D-056; `test/tau/providers/copilot/auth_test.exs` |

| C83, D-058 | `lib/tau/cli.ex` — `run_cmd/1` (FSM-backed headless path: `Tau.start_session`, `Tau.send`, `drain_run_loop`, `drain_session_end`, `extract_assistant_text`, `extract_error_text`, `resolve_system_prompt`, `build_headless_skill`, `put_if_not_nil`); `spec/0` `run` subcommand amended with `--system-prompt` and `--system-prompt-file` options; `alias Tau.Session.Events` replaces `alias Tau.Provider.Event`; `docs/spec/SPEC-USER-TURN.md` — C83, D-058, AC-10, B2 headless-run INV, Appendix B; `test/tau/cli/headless_run_test.exs` |
| C84, D-059 | `lib/tau/session.ex` — `:start_provider` `stream_opts` assembly (the `maybe_put_tools(model_visible_tool_specs(data))` call site), `model_visible_tool_specs/1`, `active_skill_tool_specs/1` (three clauses: `nil`, empty whitelist, named whitelist), `tool_spec_for/1`, and the extended `maybe_put_tools/2` arities that accept a list of specs; `priv/skills/tau-coordinator/SKILL.md`, `priv/skills/implementer/SKILL.md`, `priv/skills/critic/SKILL.md`, `priv/skills/reviewer/SKILL.md` — `allowed-tools:` frontmatter added (parsed by `Tau.Skills.Frontmatter` / `Tau.Skills.Loader.parse_tools_field/1` as whitespace-separated names); `docs/spec/SPEC-USER-TURN.md` — C84, D-059, AC-10 amendment, B5 active-skill tool-exposure INV, Appendix B; `test/tau/session/active_skill_tool_exposure_test.exs` |

| D-060, #293 | `lib/tau/session.ex` — `dispatch_tools/2` (lookup-table build + hook-rewrite refresh + merge into `data.tool_loop_call_lookups`), `handle_event(:info, {:tool_done, ...}, :tool_executing, _)` (brake check), `maybe_apply_tool_loop_brake/3` (counter logic), `emit_tool_loop_brake_abort/2` (notice + MessageEnd + return to `:awaiting_user`), `tool_args_hash/1` + `canonicalize_for_hash/1` (canonical JSON SHA-256), `tool_loop_state` + `tool_loop_brake_threshold` + `tool_loop_call_lookups` fields in `init/1`; all four `tool_iterations: 0` reset sites also reset `tool_loop_state: %{}` and `tool_loop_call_lookups: %{}`; `snapshot/1` exposes both; `docs/spec/SPEC-USER-TURN.md` — D-060, B6 INV (identical-args tool-call brake), Appendix B; `test/tau/qa/tool_loop_brake_test.exs` |
| D-061, #303 | `lib/tau/session.ex` — new `handle_event(:info, {:provider_event, ref, %PEvent.Error{retryable?: true}}, :provider_streaming, %{fallback_chain_remaining: [], stream_ref: ref, provider_retry_state: %{count: c}})` clause (re-issues `:start_provider` on the same provider with exponential backoff via `Process.send_after/3`; SOURCE-ORDERED BEFORE the ADR-0012 fallback clause), `handle_event(:info, {:provider_retry, count}, ...)` (deferred-trigger clause + stale-message no-op), `provider_retry_state` + `provider_retry_max` + `provider_retry_base_delay_ms` fields in `init/1`, every `tool_iterations: 0` reset site (5 sites: cancel, compaction-abort, clean Done, iteration-cap abort, brake-abort) also resets `provider_retry_state: %{count: 0}`; `snapshot/1` exposes `provider_retry_state` + `provider_retry_max`; `docs/spec/SPEC-USER-TURN.md` — D-061, B5 INV (single-provider mid-stream-error retry), Appendix B; `test/tau/session/provider_retry_test.exs` |
| D-062, #310 | `lib/tau/compactor/summarize_tail.ex` — `realign_split_at_tool_boundary/1` (moves leading `%Message.ToolResult{}` from `recent` into `old` after the 60% length split); `compact/2` updated to pipe the `Enum.split/2` result through `realign_split_at_tool_boundary/1` before calling `summarise/2`; `docs/spec/SPEC-USER-TURN.md` — D-062, Appendix B, Changelog; `test/tau/compactor/summarize_tail_test.exs` — two new tests: "split boundary is realigned" (5-msg orphan scenario) and "clean boundary unaffected" (10-msg idempotent scenario) |
| C94, D-076, #183 | `lib/tau/prompt_template.ex` — `Tau.PromptTemplate` struct (`name`, `body`, `path`, `description`, `variables`, `reserved/0`); `lib/tau/prompt_templates.ex` — `Tau.PromptTemplates` pure module (`discover/1`, `discover/2` (home-injectable for testing), `render/3`, `build_template_context/1`, private `scan_dir/1`, `parse/1`, `extract_variables_from_body/1`, `do_render/3`); `lib/tau/session.ex` — `prompt_templates: Tau.PromptTemplates.discover(cwd)` field in `init/1`; `classify_slash_command/4` (arity promoted from 2 to 4 with `templates` + `cwd`; template branch after skill lookup; `build_template_context/1` helper); `lib/tau/commands/builtin/reload.ex` — `Tau.PromptTemplates.discover/1` added alongside skill re-discovery (AC-7); `lib/tau/command.ex` — moduledoc corrected (stale `Tau.Commands.Files` reference); `docs/adr/0008-user-code-never-runs-synchronously-in-the-fsm.md` — `Tau.Commands.Files` reference updated; `docs/spec/SPEC-USER-TURN.md` — C94 (§3 Q3), D-076 (§6), Changelog, Appendix B; `test/tau/prompt_templates_test.exs` |

| D-077..D-083, #339 | `lib/tau/session.ex` — `@queue_cap 32`; `steering_queue: :queue.new()` and `followup_queue: :queue.new()` fields in `init/1`; queue-routing clause (`state != :awaiting_user, command_task == nil` → enqueue by tier); ADR-0008 postpone clause updated from 2-arity to 3-arity `{:user_message, _, _tier}` pattern (preserves D-048/D-049 compaction postpone for `command_task != nil`); immediate-deliver clause updated to `{:user_message, msg, _tier}, :awaiting_user, %{command_task: nil}`; `handle_event(:internal, :drain_followups, :awaiting_user, %{command_task: nil})` — routes through `handle_event(:cast, {:user_message, msg, :followup}, ...)` (not `process_user_message/2`) so slash commands classify correctly; `handle_event(:internal, :drain_followups, _state, data)` — no-op fallback; every `{:next_state, :awaiting_user, ...}` site appended with `drain_followups` action when queue non-empty; `drain_steering_queue_one/1` — called in `{:tool_done}` handler's `{:continue, data}` arm when `map_size(tools) == 0`, before re-entering `:start_provider`; cancel handlers (general cancel + `:awaiting_permission` cancel) drain and broadcast `%QueueRestored{}`; `snapshot/1` exposes `queues: %{steering: [...], followup: [...]}`; `send/2` updated to 3-arity `:followup` cast; `steer/2` added with 3-arity `:steering` cast. `lib/tau/session/events.ex` — `%QueueRestored{session_id, messages}` struct. `lib/tau.ex` — `steer/2` delegating to `Session.steer/2`; `send/2` docstring updated. `lib/tau/tui/app.ex` — `handle_event` passes `key` field to `handle_alt/3` (3-arity); `handle_key/3` busy-Enter clause routes to `steer/1`; idle-Esc → `clear_input/1`, busy-Esc → `cancel/1`; `handle_alt/3` with `(model, 0, 13)` clause for Alt+Enter → `followup/1`; `update/2` handles `%QueueRestored{}` by restoring editor from message contents; `status_bar_hint/1` per-state dispatch (idle vs busy). `docs/adr/0021-two-tier-message-queue.md` — ADR-0021 (partially supersedes ADR-0009). `test/tau/session/message_queue_tiers_test.exs` — D-077..D-083 unit and property tests. |

Other constraints map to sites named in their text.

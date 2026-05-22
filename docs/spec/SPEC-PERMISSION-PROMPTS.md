# SPEC: Permission Prompts

| | |
|---|---|
| **Status** | PR-A merged. PR-B (#373) implemented — gate pending. |
| **Date** | 2026-05-21 |
| **Scope** | Interactive permission prompts for `:ask`-verdict tool calls; the `:awaiting_permission` FSM state; non-interactive fail-closed `:deny` resolution; the `interactive?` session property; the `decide_permission/3` and `set_permissions_mode/2` public API. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); L0 + boundary contracts. |
| **Disposition** | **Core correctness fix.** `:default` mode's `:ask` verdict currently falls through into the allowed batch, silently treating unmatched tools as `:allow`. This SPEC closes that gap. |
| **Tracking issue** | #341 |
| **D-NNN block** | D-090..D-099 (PR-A, per `docs/MISSION.md` M1.1 registry); D-170..D-179 (PR-B TUI surface) |

---

## 0. Why this spec exists

`Tau.Permissions.Evaluator` returns three values: `:allow`, `:deny`, `:ask`. The
permission gate in `lib/tau/session.ex` (`dispatch_tools/2`, ~line 2251) performs
a two-way `:deny`/allow split via `Enum.split_with`. An `:ask` verdict falls into
the *allowed* batch — the tool runs without user consent.

`:default` mode (the default for every session) returns `:ask` for any tool call
that does not match an explicit rule. The practical result: **`:default` mode
silently behaves like `:bypass` minus deny-rules**. This is a correctness gap, not
a UX gap.

This SPEC fixes the gate (three-way partition), adds the
`:awaiting_permission` `:gen_statem` state that suspends an interactive turn
pending user consent, and defines the fail-closed non-interactive path so the
headless `tau run` substrate (the factory-loop backbone) is never deadlocked.

---

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 1 | `data.pending_permission_requests` is session-scoped; concurrent `{:permission_decision}` casts must be serialised through the FSM |
| 2 | Temporal coupling | 1 | `:awaiting_permission` defers the whole tool-dispatch round; a `{:permission_decision}` cast out of order or after resolution must not crash the FSM |
| 3 | Cross-process coordination | 1 | `Phoenix.PubSub` carries `%PermissionRequest{}` to the TUI; the TUI casts `{:permission_decision}` back — two BEAM processes with an async round-trip |
| 4 | Feedback loops | 0 | one shot: request → decision → continue; no closed loop |
| 5 | State accumulation | 1 | `data.pending_permission_requests` accumulates per `:ask` call; cleared only on decision or `:cancel` |

**Triage score: 4/5. L0 + boundary contracts required.**

---

## 2. Component decomposition

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | `Tau.Session` FSM ↔ `Tau.Permissions.Evaluator` | three-way partition at permission gate |
| B2 | `Tau.Session` FSM ↔ `Phoenix.PubSub` ("session:\<id\>") | broadcast `%PermissionRequest{}` at `:ask` time |
| B3 | `Tau.Session` FSM ↔ TUI (or any subscriber) | `{:permission_decision, tool_call_id, verdict}` cast |
| B4 | `Tau.Session` FSM ↔ headless callers (`tau run`, factory loop) | non-interactive fail-closed `:deny` resolution; `interactive?` property |
| B5 | `Tau.Session` FSM ↔ telemetry | `[:tau, :permissions, :request]` at `:ask` time; `[:tau, :permissions, :decision]` at resolution |

---

## 3. L0 — constraints by question

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **★ [C1-B3] (D-090)** `data.pending_permission_requests` is a map of
  `tool_call_id → %{name, arguments}`. The FSM is the sole writer; TUI and other
  subscribers are read-only (they only cast decisions). No concurrent write hazard
  inside the FSM itself (`:gen_statem` is single-threaded per session), but a
  `{:permission_decision}` cast for an **unknown or already-resolved**
  `tool_call_id` — or one arriving in a state other than `:awaiting_permission` —
  MUST be a logged no-op (debug log + telemetry). It MUST NOT crash the FSM and
  MUST NOT silently drop the event without any trace.

### Q2: What ordering assumptions are implicit?

- **[C2-B3] (D-091)** Multiple tool calls in one assistant turn may each yield
  `:ask`. The FSM collects ALL of them into `pending_permission_requests` before
  entering `:awaiting_permission` (D1: defer the whole round). The TUI resolves
  them one at a time via separate `{:permission_decision}` casts. The `:allow_once`
  path adds the resolved call to `permission_dispatch_batch`. The `:deny_once`
  path accumulates a synthesised `is_error` ToolResult in `permission_pending_results`.
  When the last pending entry is cleared, `finish_permission_round/1` emits all
  accumulated results (ToolEnd broadcast + history append), then dispatches the
  approved batch. The FSM then exits `:awaiting_permission` into `:tool_executing`
  (if any approved calls remain) or directly invokes `:start_provider` (if all
  were denied).

- **★ [C3-B4] (D-092)** A `{:permission_decision}` arriving BEFORE
  `:awaiting_permission` is entered (e.g., a race where the TUI resolves faster
  than the FSM transitions) MUST be silently and safely handled. Because
  `:gen_statem` serialises all messages, this cannot happen in practice — the FSM
  enters `:awaiting_permission` synchronously before returning control. However,
  a decision for a `tool_call_id` from a **previous** turn (stale) MUST follow the
  D-090 logged no-op discipline.

### Q3: What happens if a component fails silently?

- **★ [C4-B4] (D-093)** If `interactive?` is `false` (e.g., `tau run`, factory
  loop), an `:ask` verdict MUST resolve immediately to fail-closed `:deny` via a
  synthesised `is_error` `ToolResult`. The FSM MUST NOT enter
  `:awaiting_permission`. The denial message MUST name the fail-closed reason so
  the model can surface it to a human reviewer. Content: `"Permission required for
  <name> but session is non-interactive; denied by policy."`.

- **[C5-B2] (D-094)** If the PubSub broadcast of `%PermissionRequest{}` fails
  (e.g., no subscribers), the FSM continues normally — it still enters
  `:awaiting_permission` and waits. PubSub delivery is best-effort; the FSM MUST
  NOT wait for acknowledgement of broadcast delivery.

### Q4: What invariants must hold across restarts?

- **[C6-B1] (D-095)** `pending_permission_requests` is NOT persisted to JSONL.
  On resume from a `:awaiting_permission` state that crashed, the FSM restores to
  `:awaiting_user` (the JSONL header records the last committed state). Pending
  requests are abandoned; the model must re-issue the tool calls on the next user
  turn. This is intentional: the TUI dialog state is transient and not
  reconstructable from JSONL alone.

### Q5: What's the contract surface visible to extensions?

- **[C7-B3] (D-096)** The public API for permission decisions is:
  - `Tau.Session.decide_permission(session_id, tool_call_id, verdict)` where
    `verdict ∈ {:allow_once, :deny_once}`. Returns `:ok` if the cast was
    dispatched (does not wait for FSM state change).
  - `Tau.Session.set_permissions_mode(session_id, mode)` — updates
    `data.metadata.permissions_mode`. Gated to `:awaiting_user` only (rejects
    with `{:error, :busy}` otherwise, mirroring `swap_model`). Valid modes:
    `:default | :accept_edits | :plan | :auto | :dont_ask | :bypass`.

### Q6: What's the user-visible failure surface?

- **[C8-B5] (D-097)** Telemetry events MUST cover every permission-gate
  decision path:
  - `[:tau, :permissions, :request]` — emitted once per `:ask` call at the time
    `%PermissionRequest{}` is broadcast. Metadata: `session_id`, `tool_call_id`,
    `tool_name`.
  - `[:tau, :permissions, :decision]` — emitted once per resolution (allow, deny,
    or fail-closed non-interactive deny). Metadata: `session_id`, `tool_call_id`,
    `tool_name`, `decision` (`:allow_once | :deny_once | :deny_non_interactive`).
  - The existing `[:tau, :permissions, :decision]` event for rule-set `:deny` is
    unchanged (already present at `session.ex:2268`).

### Q7: What is the `:cancel`-in-`:awaiting_permission` contract?

- **★ [C9-B3] (D-098)** When the user cancels while the FSM is in
  `:awaiting_permission`, the FSM MUST: (1) synthesise an `is_error` ToolResult
  for every entry in `pending_permission_requests` (denial content:
  `"Session cancelled while awaiting permission for <name>."`); (2) broadcast
  `%Events.Cancelled{}`; (3) clear `pending_permission_requests`; (4) transition
  to `:awaiting_user`. This is the **authoritative contract** for this transition;
  any PR touching cancel-in-`:awaiting_permission` (e.g. PR-B) MUST honour it.

### Q8: What's NOT in scope (deferred)?

- **[C10] (D-099 — deferred)** Rule-file persistence: "allow & don't ask again"
  writing to `~/.tau/rules.json`. The consent UI will offer this option, but the
  persistence path is deferred to a follow-up issue. The `:allow_once` and
  `:deny_once` verdict names deliberately signal session-scope-only effect.
- TUI approval dialog (PR-B): implemented in PR #373. PR-B delivers the
  `Tau.TUI.App` approval modal, `/perms <mode>` command, and status-bar indicator.
- The `RuntimeOpts` `:permissions_mode` plumbing (PR-B): implemented in PR #373.

### Q9: Why is `Shift+Tab` infeasible as a mode-change key? (PR-B probe finding)

- **★ [C11-B4] (D-173)** An empirical probe confirmed that termbox delivers
  `Shift+Tab` (`CSI Z`) as **three separate key events** (`ESC`, `[`, `Z`). The
  `ESC` event is indistinguishable from the user pressing Escape (cancel/clear
  semantics) without adding stateful multi-event sequence detection. This would
  require process state or model-level FSM extension, violating OTP non-negotiables
  #3/#8 (no stateful logic in a pure MVU update). The mode-change mechanism is
  therefore the `/perms <mode>` slash command (D-173).

---

## 4. Boundary contracts

These contracts are **locked** once PR-A is merged. Amendments require a spec PR.

### B1 — permission gate (`dispatch_tools/2`)

The existing two-way split:
```elixir
{gated, allowed} =
  Enum.split_with(tool_calls, fn %{name: name, arguments: args} ->
    Evaluator.evaluate(rule_set, name, args, eval_ctx, mode) == :deny
  end)
```

Is replaced by a **three-way partition**:
```elixir
{gated, ask_calls, allowed} = partition_by_permission(tool_calls, rule_set, eval_ctx, mode)
```

Where:
- `gated` — `:deny` verdict → synthesised `is_error` ToolResult (existing).
- `ask_calls` — `:ask` verdict:
  - If `data.interactive? == false` → fail-closed `:deny` (synthesised
    `is_error` ToolResult, D-093). FSM does NOT enter `:awaiting_permission`.
  - If `data.interactive? == true` → broadcast `%PermissionRequest{}` per call,
    enter `:awaiting_permission` (D-092).
- `allowed` — `:allow` verdict → existing hook/dispatch path unchanged.

### B2 — `%PermissionRequest{}` event (B2)

```elixir
defmodule Tau.Session.Events.PermissionRequest do
  @enforce_keys [:session_id, :tool_call_id, :name, :arguments, :decision_reason]
  defstruct [:session_id, :tool_call_id, :name, :arguments, :decision_reason]
  @type t :: %__MODULE__{}
end
```

- `decision_reason` — the human-readable rationale for why consent is required
  (today always `"Tool not matched by any allow rule in current mode."`).
- Broadcast on `"session:<id>"` PubSub topic, one per `:ask` call.

### B3 — `:awaiting_permission` FSM state

```
:tool_executing → [enter] :awaiting_permission
```

Entry condition: `data.interactive? == true` AND `ask_calls != []`.

Data additions:
- `data.pending_permission_requests :: %{tool_call_id => %{name, arguments}}` —
  initialised from `ask_calls` at entry.
- `data.permission_dispatch_batch :: [{id, name, args}]` — accumulates the
  pre-approved `:allow`-verdict calls (deferred at entry) plus any `:allow_once`
  user decisions. Dispatched as one batch in `finish_permission_round/1`.
- `data.permission_pending_results :: [{call_id, %ToolResult{}}]` — accumulates
  instant-resolve results for `:deny_once` decisions. Emitted in
  `finish_permission_round/1` via broadcast + history append (not via
  `{:tool_done}` messages). Cleared on exit.

Instant-resolve items (deny-rule gated, whitelist-filtered, skill-activated)
are tracked in `tools_in_flight` and processed by a Clause 0 `{:tool_done}`
handler in `:awaiting_permission`. This handler processes them identically to
`:tool_executing` but does NOT trigger the post-round transition (that only
fires when `pending_permission_requests` is empty).

Exits:
1. `{:permission_decision, tool_call_id, :allow_once}` — remove from
   `pending_permission_requests`, add to `permission_dispatch_batch`. If map empty
   → call `finish_permission_round/1`.
2. `{:permission_decision, tool_call_id, :deny_once}` — remove from
   `pending_permission_requests`, accumulate result in `permission_pending_results`.
   If map empty → call `finish_permission_round/1`.
3. `:cancel` cast → deny all pending (D-098) → `:awaiting_user`.

Unknown/stale `tool_call_id` in `{:permission_decision}` → logged no-op (D-090).

`finish_permission_round/1` behaviour:
- Removes all `:awaiting_permission` sentinel entries from `tools_in_flight`.
- Emits all `permission_pending_results` (broadcast ToolEnd + append to history).
- Runs `:pre_tool_use` hooks on `permission_dispatch_batch`; hook-denied results
  are also emitted directly (not via `{:tool_done}`).
- If approved calls remain → dispatch via parallel executor → `:tool_executing`.
- If no approved calls → invoke `:start_provider` directly (skip `:tool_executing`).

**D1 (whole-round deferral):** When entering `:awaiting_permission`, NO calls are
dispatched — not even `:allow`-verdict calls. The partition is applied before any
dispatch; `:allow` calls go into `permission_dispatch_batch` at entry, `:ask` calls
go into `pending_permission_requests`, and instant-resolve items (deny-rule,
whitelist) produce `{:tool_done}` messages handled by Clause 0.

### B4 — `interactive?` session property

- Type: `boolean()`
- Set at session init from `opts[:interactive]`, defaulting to `true`.
- `tau run` (`lib/tau/cli.ex` `run_cmd/1`) MUST pass `interactive: false` in
  `start_opts`.
- The TUI launch path (`lib/tau/cli.ex` `tui_cmd/1`) MUST pass `interactive: true`
  (or rely on the default `true`).
- Stored on `data.interactive?`, consulted in `dispatch_tools/2` and nowhere else
  in PR-A.

### B5 — cast shapes and public API

```elixir
# verdict ∈ {:allow_once, :deny_once}
Tau.Session.decide_permission(session_id, tool_call_id, verdict) :: :ok | {:error, :not_found}

# mode ∈ :default | :accept_edits | :plan | :auto | :dont_ask | :bypass
Tau.Session.set_permissions_mode(session_id, mode) :: :ok | {:error, :busy | :not_found}
```

`decide_permission/3` casts `{:permission_decision, tool_call_id, verdict}` to the
FSM. Returns `:ok` if the session exists; `{:error, :not_found}` otherwise.

`set_permissions_mode/2` casts `{:set_permissions_mode, mode}`. The FSM handler
returns `{:error, :busy}` if the state is not `:awaiting_user`.

---

## 5. Acceptance criteria

### PR-A (this PR) — headless / unit, no tmux

- **AC-A1** — under `:default` mode an unmatched tool call in an **interactive**
  session enters `:awaiting_permission` and broadcasts a `%PermissionRequest{}`.
  Test: FSM state-trace assertion + event assertion.
- **AC-A2** — `decide_permission(sid, tcid, :allow_once)` dispatches the call;
  `:deny_once` yields an `is_error` `ToolResult` and the turn continues.
- **AC-A3** — a `{:permission_decision}` for an unknown/stale `tool_call_id`, or
  outside `:awaiting_permission`, is a no-op; the FSM does not crash (D-090).
- **AC-A4** — `tau run` (non-interactive) against a fixture emitting an unmatched
  tool call **terminates**, the unmatched call's result is an `is_error`
  `ToolResult` naming the fail-closed denial, and the FSM never enters
  `:awaiting_permission`. Test exercises `Tau.CLI.main(["run", ...])` path and
  asserts on FSM state trace.
- **AC-A5** — `:cancel` in `:awaiting_permission` denies all pending and returns
  to `:awaiting_user` (D-098/B3).
- **AC-A6** — `set_permissions_mode/2` updates `data.metadata.permissions_mode` in
  `:awaiting_user`; rejected `:busy` mid-turn.
- **Property** — `for all ask_call_lists, interactive? ∈ {true, false}`:
  `interactive? == false` → every `:ask` call in the batch resolves to a
  `is_error` ToolResult and FSM never enters `:awaiting_permission`.

### PR-B (TUI surface — #373)

PR-B implements the interactive TUI surface for the permission system. The
`Shift+Tab` key cycle originally planned for mode-switching is **infeasible**:
an empirical tmux/termbox probe confirmed `Shift+Tab` (`CSI Z`) is delivered
as three separate events (`ESC`, `[`, `Z`), and the `ESC` event
functionally collides with cancel/clear in the existing key map. The
mode-change mechanism is therefore the `/perms <mode>` slash command (D-173).

- **AC-B1** — under `mode: :default`, a `%PermissionRequest{}` event
  makes `Tau.TUI.App` render a permission dialog naming the tool and
  offering allow/deny — before any tool output renders. The dialog is
  an MVU model-state change only (no new process; OTP #3/#8).
- **AC-B2** — with the dialog open, a `y` key event resolves the head
  request via `decide_permission/3` with `:allow_once` and pops it
  from `model.pending_permissions`.
- **AC-B3** — an `n` key event resolves the head with `:deny_once` and
  pops it.
- **AC-B4** — while the dialog is open, a printable keystroke does NOT
  reach the prompt/input editor — the modal captures all input.
- **AC-B5** — `Tau.TUI.StatusBar.render_text/1` includes a
  ` mode: <mode>` segment reflecting `model.permissions_mode`.
- **AC-B6** — typing `/perms accept_edits` + Enter sets
  `permissions_mode` to `:accept_edits` via `set_permissions_mode/2`;
  likewise `/perms plan` → `:plan` and `/perms default` → `:default`.
  An unknown/empty argument is a no-op that reports the current mode
  and the valid set in the transcript (no crash, no mode change).
- **AC-B7** — `/perms <mode>` while `model.status` is `:streaming`
  does NOT change the displayed mode (FSM rejects `set_permissions_mode`
  `:busy` per D-096); once the turn ends, `/perms <mode>` works again.
- **AC-B8** — two `%PermissionRequest{}` events queue; the dialog shows
  the first; resolving it reveals the second; resolving both clears the
  dialog.
- **AC-B9 (meta)** — `RuntimeOpts` carries `:permissions_mode`, plumbed
  from the CLI; the launched TUI's initial indicator reflects it.
  Verified by inspection + the `tau tui` smoke path.

New invariants from PR-B implementation (allocated from D-170..D-179 block
per `docs/MISSION.md` registry — see D-NNN register §6 below).

---

## 6. D-NNN invariant register

| ID | Invariant |
|----|-----------|
| D-090 | A `{:permission_decision}` cast for an unknown or already-resolved `tool_call_id`, or arriving outside `:awaiting_permission`, MUST be a logged debug no-op. It MUST NOT crash the FSM. |
| D-091 | ALL `:ask` calls from one assistant turn are collected into `pending_permission_requests` before `:awaiting_permission` is entered (whole-round deferral). NO calls (including `:allow`-verdict calls) are dispatched at entry; `:allow` calls are held in `permission_dispatch_batch` and dispatched only after all `:ask` decisions are resolved via `finish_permission_round/1`. |
| D-092 | `interactive? == true` AND `ask_calls != []` → enter `:awaiting_permission`. Interactive sessions MUST NOT auto-deny `:ask` calls. |
| D-093 | `interactive? == false` AND any `:ask` verdict → fail-closed `:deny` (synthesised `is_error` ToolResult, message `"Permission required for <name> but session is non-interactive; denied by policy."`). FSM MUST NOT enter `:awaiting_permission`. |
| D-094 | PubSub broadcast of `%PermissionRequest{}` is fire-and-forget. FSM MUST NOT wait for delivery acknowledgement. |
| D-095 | `pending_permission_requests` is NOT persisted to JSONL. A resumed session that crashed in `:awaiting_permission` restores to `:awaiting_user`; pending requests are abandoned. |
| D-096 | Public API: `decide_permission/3` casts `{:permission_decision, tool_call_id, verdict}` (`verdict ∈ {:allow_once, :deny_once}`); `set_permissions_mode/2` casts `{:set_permissions_mode, mode}`, gated to `:awaiting_user`. |
| D-097 | Telemetry: `[:tau, :permissions, :request]` per `:ask` at broadcast time; `[:tau, :permissions, :decision]` per resolution. Both carry `tool_call_id`. |
| D-098 | `:cancel` in `:awaiting_permission` → synthesise `is_error` ToolResult for every pending entry, broadcast `%Cancelled{}`, clear `pending_permission_requests`, transition to `:awaiting_user`. |
| D-099 | (deferred) Rule-file persistence ("allow & don't ask again") — out of scope for PR-A and PR-B. |

**PR-B invariants (D-170..D-173; block D-170..D-179 allocated to this SPEC for PR-B):**

| ID | Invariant |
|----|-----------|
| D-170 | `Tau.TUI.App` MUST maintain a `pending_permissions` queue field (list of `%PermissionRequest{}`). A `%PermissionRequest{}` event arriving via `update/2` MUST be appended to the queue. The dialog renders the head; resolving it pops only the head (FIFO order). Pure MVU state — no new process. |
| D-171 | `Tau.TUI.App` MUST maintain a `permissions_mode` field (atom: `:default \| :accept_edits \| :plan`). Seeded from `RuntimeOpts.get()[:permissions_mode]` at `init/1`; defaults to `:default`. Changed by `/perms <mode>` only when `model.status == :idle`. |
| D-172 | While `model.pending_permissions` is non-empty, ALL key input MUST be captured by the permission dialog handler. `y` → `:allow_once`, `n` → `:deny_once`. Every other keystroke MUST be swallowed (MUST NOT reach the editor or submit path). |
| D-173 | The `/perms <mode>` command is handled in `Tau.TUI.App.submit/1` (TUI layer), not dispatched to the session FSM as a slash command. When `model.status` is not `:idle`, the mode update is suppressed (FSM would reject `:busy`; local model update is also suppressed per AC-B7). Valid modes: `:default`, `:accept_edits`, `:plan`. `Shift+Tab` mode cycling is **infeasible** (termbox delivers `CSI Z` as three events: `ESC`, `[`, `Z`; `ESC` collides with cancel). |

---

## Appendix A — Rejected alternatives

**A1: Auto-allow `:ask` in non-interactive mode** — Rejected. This is the current
(broken) behaviour. Fail-closed is the correct safe default for an autonomous
agent running unattended.

**A2: Auto-allow `:ask` in interactive mode while TUI dialog is pending** —
Rejected. This defeats the purpose of the permission gate. The FSM MUST wait.

**A3: A separate `PermissionManager` GenServer** — Rejected per OTP non-negotiable
§3: no GenServer wrapping stateless logic, and the FSM already owns all session
state. `pending_permission_requests` belongs on `data`.

**A4: The `dialog -- allow & switch mode` option** — Rejected as gold-plating
(critic S2). PR-B will offer `:allow_once` and `:deny_once` only. A future PR
can add mode-switching from the dialog.

---

## Appendix B — Source map

Files whose behaviour is governed by this SPEC:

| File | Role |
|------|------|
| `lib/tau/session.ex` | FSM: three-way partition, `:awaiting_permission` state, `interactive?` data field, cast handlers, public API |
| `lib/tau/session/events.ex` | `%PermissionRequest{}` event struct |
| `lib/tau/cli.ex` | `run_cmd/1`: pass `interactive: false` in `start_opts` |
| `test/tau/session/permission_prompts_test.exs` | AC-A1..A6 + property |
| `test/tau/cli/headless_permission_deny_test.exs` | AC-A4 CLI path |
| `lib/tau/tui/app.ex` | PR-B: `pending_permissions` queue, `permissions_mode` field, permission dialog render, `/perms` command, input capture (D-170..D-173) |
| `lib/tau/tui/status_bar.ex` | PR-B: `permissions_mode_segment/1` — `mode: <mode>` status-bar segment (D-171, AC-B5) |
| `lib/tau/tui/runtime_opts.ex` | PR-B: `:permissions_mode` key documentation (AC-B9) |
| `test/tau/tui/permission_dialog_test.exs` | PR-B: AC-B1..AC-B8 gating tests |

# SPEC: TUI Completion Surface

| | |
|---|---|
| **Status** | Draft — #333 (slash-command surface) implementation PR open. |
| **Date** | 2026-05-21 |
| **Scope** | The MVU completion sub-state machine shared by slash-command autocomplete (#333) and `@`-mention autocomplete (#344): fuzzy filtering, open/filter/navigate/accept/dismiss lifecycle, catalog delivery, and the unknown-command guard. |
| **Method** | PSDH (`.claude/skills/design-reasoning`); triage score 2/5. |
| **D-NNN block** | D-100..D-109 (reserved in `docs/MISSION.md`). |
| **Tracking issues** | #333 (slash-command surface — this PR), #344 (`@`-mention — adds its candidate source later). |

## 0. Why this spec exists

Both the slash-command menu (#333) and the future `@`-mention menu (#344) are
the **same MVU sub-state machine over different candidate sources**: same fuzzy
ranker, same open/filter/navigate/accept/dismiss lifecycle, same `Esc`/`Enter`
clause-ordering hazard. A shared spec prevents two PRs from independently
specifying the same machine in conflicting ways, and gives `Tau.TUI.Fuzzy` a
single authoritative home.

The critic review for #333 identified this spec as the correct resolution of
the B1 SPEC-routing conflict between the #333 elaboration (which incorrectly
proposed amending `SPEC-TUI-HEADLESS.md`) and the #344 elaboration (which
correctly proposed a shared `SPEC-TUI-COMPLETION.md`).

## 1. Triage

| # | Property | Score | Evidence |
|---|----------|-------|----------|
| 1 | Shared mutable state | 0 | Catalog is a pure projection; menu state is MVU-local (D-102). No shared writable store introduced. |
| 2 | Temporal coupling | 1 | Catalog broadcast must precede the first `/` keystroke (D-104); `Esc`/`Enter` clause order is semantically critical (D-106). |
| 3 | Cross-process coordination | 1 | Session FSM broadcasts `CommandCatalog` event to TUI over PubSub/EventBridge (D-103). One hop, one event. |
| 4 | Feedback loops | 0 | One keystroke → one filter → one render. No closed feedback loop. |
| 5 | State accumulation | 0 | Menu state created on `/` and discarded on dismiss/accept/space. Catalog recomputed from authoritative sources, never accumulated. |

**Triage: 2/5. Spec entry required per `.claude/rules/spec-before-code.md`.**

## 2. Component decomposition

| # | Boundary | Operation |
|---|----------|-----------|
| B1 | `Tau.Session` → `Tau.TUI.App` (via PubSub/EventBridge) | `CommandCatalog` broadcast at `SessionStart` and on `/reload` |
| B2 | `Tau.TUI.App.update/2` keystroke path | open menu on `/`, re-filter on char, navigate with arrows, accept with Enter, dismiss with Esc or space |
| B3 | `Tau.Commands.Catalog.list/1` | pure projection from builtins + registry + skills + templates |
| B4 | `Tau.TUI.Fuzzy.match/2` | pure subsequence scorer; candidate-source-agnostic |
| B5 | `classify_slash_command/2` unknown-command arm | emits `SystemNotice` instead of `{:sync, msg}` for unrecognized `/`-tokens |

## 3. Constraints (L0)

Format: `[Cn-Bm]` = constraint number + boundary. **★** marks non-obvious.

### Q1: What can be written by more than one actor?

- **[C1-B1]** The `CommandCatalog` event is broadcast-only from the session FSM.
  The TUI is a pure consumer; it never writes back to the catalog. No race.
- **★ [C2-B3]** `Catalog.list/1` folds four sources whose content can change
  between calls (registry, skills, templates). The catalog is derived each time
  from the authoritative sources — there is no stored snapshot to go stale. The
  session FSM owns the snapshot (`data.skills`, `data.prompt_templates`); the TUI
  receives a broadcast of the computed list and stores it in model state.

### Q2: What ordering assumptions are implicit?

- **★ [C3-B1] / D-104** The `CommandCatalog` broadcast MUST arrive at the TUI
  before the user types `/`. In practice this is guaranteed: `SessionStart` fires
  synchronously during `Tau.start_session/1`; the EventBridge subscribes before
  `start_session` returns (D-004); the catalog broadcast follows `SessionStart` in
  the same init sequence. However, the TUI MUST handle the race window (e.g. a
  keystroke delivered by a test before the bridge drains). **Invariant D-104:**
  when the menu opens and no catalog has been received yet, the builtins floor
  (from `Tau.Commands.Builtin.table/0`) is used as the candidate set. The TUI
  MUST NOT crash on an empty or missing catalog.
- **★ [C4-B2] / D-106** `Esc` while the menu is open MUST dismiss the menu
  **without** cancelling the session. The `Esc`-dismiss clause in `update/2` MUST
  be ordered BEFORE the existing `Esc`→`cancel/1` clause. Inverting the order
  causes `Esc` to cancel the turn every time the user dismisses the menu.
- **[C5-B2] / D-107** `Enter` while the menu is open MUST fill the input with
  `name <> " "` and close the menu — it MUST NOT submit the turn. Commands take
  arguments; auto-submit would break every argument-bearing command. A second
  `Enter` (on an empty menu, or after the menu closes) submits via the existing
  `submit/1` path.
- **[C6-B1] / D-108** `/reload` MUST re-broadcast the `CommandCatalog` event
  so commands discovered after `SessionStart` (via `/reload`) appear in the
  menu and in `/help` without a session restart. A one-shot `SessionStart`-only
  broadcast would make the catalog stale after `/reload`. This invariant is
  **mandatory**, not optional.

### Q3: What happens if a component fails silently?

- **★ [C7-B4]** An empty query string in `Tau.TUI.Fuzzy.match/2` MUST return
  all entries in their natural (catalog) order rather than crashing or returning
  an empty list. This covers the case where the user has typed only `/` with no
  further characters.
- **[C8-B5]** The unknown-command guard in `classify_slash_command/2` MUST only
  intercept an exact `/`-prefixed whitespace-free token with no catalog match. A
  line with whitespace (e.g. `/usr/bin is a path`) or a real prose line MUST
  still pass through to `{:sync, msg}` and reach the model. Intercepting prose
  would falsify AC-7.
- **[C9-B3]** `Catalog.list/1` MUST no-op cleanly if `Tau.PromptTemplates` is
  absent (e.g. if the module is not loaded). The template fold is pluggable: use
  `Code.ensure_loaded?/1` or a `try/rescue` to detect absence. The other three
  sources (builtins, registry, skills) are always present.

### Q4: What invariants must hold across restarts?

- **[C10-B1]** A session crash that kills the FSM also kills the EventBridge
  (it's linked). The TUI model retains the last-received catalog in `model.catalog`
  until the model itself is discarded. No stale writes occur.

### Q5: What's the contract surface visible to extensions?

- **[C11-B4]** `Tau.TUI.Fuzzy` is candidate-source-agnostic. It accepts any
  `[entry]` where `entry` has a `:name` key. It MUST NOT assume entries are
  command catalog entries — #344 will pass `@`-mention candidates through the
  same function.
- **[C12-B3]** Catalog precedence MUST match `classify_slash_command/2`:
  `builtin > extension > file > skill > template`. If the menu shows an entry
  that the dispatcher resolves to a different origin, the menu lies (R1 in the
  elaboration). AC-8 property test enforces this invariant.

## 4. Boundary contracts

### B1 — `CommandCatalog` event

```elixir
defmodule Tau.Session.Events.CommandCatalog do
  @enforce_keys [:session_id, :entries]
  defstruct [:session_id, :entries]
  # entries :: [Tau.Commands.Catalog.entry()]
end
```

Broadcast by `Tau.Session` init (after `SessionStart`) and by `/reload`'s
`{:mutate, fun, notice}` outcome (as a second broadcast after the mutate).

### B2 — Menu model state

```elixir
# New field in Tau.TUI.App model:
# menu :: nil | %{query: String.t(), entries: [Tau.Commands.Catalog.entry()], selected: non_neg_integer()}
```

`nil` means the menu is closed. Non-nil means it is open. The `entries` field
holds the fuzzy-filtered subset of `model.catalog` for the current `query`.

### B3 — `Tau.Commands.Catalog.list/1`

```elixir
@type entry :: %{
        name: String.t(),            # "/help", "/compact", etc.
        description: String.t(),
        origin: :builtin | :extension | :file | :skill | :template
      }

@spec list(session_data :: map()) :: [entry()]
```

Pure. No side effects. No GenServer.

### B4 — `Tau.TUI.Fuzzy.match/2`

```elixir
@spec match(query :: String.t(), entries :: [map()]) :: [{score :: integer(), entry :: map()}]
```

Returns entries sorted by descending score (highest first). An empty query
returns all entries with score 0, preserving input order. Candidate-source-
agnostic: entries need only a `:name` key for scoring; other keys are passed
through unchanged.

### B5 — Unknown-command guard

In `classify_slash_command/2`'s innermost `:error` arm (after skill and
template lookup both fail):

- If the token has no whitespace and starts with `/` and has no catalog match:
  return `{:unknown_command, name}` (a new tagged value).
- The caller (`handle_event/4` for `:user_message`) broadcasts a `SystemNotice`
  (`"Unknown command /foo — type /help"`) and stays in `:awaiting_user`.
- Lines with whitespace (any prose starting with `/`) are NOT intercepted;
  they fall through to `{:sync, msg}` and reach the model.

## 5. Acceptance criteria

### AC-1 (D-100) — `/help` enumerates commands

`/help` + Enter renders a `SystemNotice` listing every builtin in
`Builtin.table/0` with a description, one per line. No provider turn occurs
(status never enters `:streaming`).

**Advances:** D-100. **Test:** `test/tau/commands/builtin/help_test.exs` — unit
test verifying `{:notice, lines}` outcome and that every builtin name appears
in the lines.

### AC-2 (D-101) — Unknown command does not reach the model

`/notacommand` + Enter renders an "Unknown command" `SystemNotice`; status
never enters `:streaming`; no assistant message. Falsifies the previous
`{:sync, msg}` pass-through behaviour.

**Advances:** D-101. **Test:** `test/tau/session/unknown_command_test.exs`.

### AC-3 (D-102) — `/` opens the menu

Typing a single `/` opens the menu panel above the prompt listing command
entries. Menu is MVU state (`model.menu != nil`).

**Advances:** D-102. **Test:** `test/tau/tui/app_test.exs` — unit test on
`App.update/2` with `{:event, %{ch: ?/}}`.

### AC-4 (D-103) — Fuzzy filter narrows

With the menu open, typing `cmp` narrows it to `/compact` (subsequence match).
The menu does not show `/ping`.

**Advances:** D-103. **Test:** property + unit tests in
`test/tau/tui/fuzzy_test.exs` and `test/tau/tui/app_test.exs`.

### AC-5 (D-104) — Keyboard navigation + selection

With the menu open and ≥ 2 entries, pressing Down then Enter replaces the
prompt input with the second entry's `name <> " "` and closes the menu. The
turn is NOT submitted (status stays idle).

**Advances:** D-104. **Test:** `test/tau/tui/app_test.exs`.

### AC-6 (D-105) — `Esc` dismisses without cancelling

With the menu open, pressing `Esc` closes the menu and does NOT cancel the
session (no `Cancelled` notice appears; status stays idle). This requires the
menu-dismiss `Esc` clause to precede the existing `Esc`→`cancel/1` clause.

**Advances:** D-105 (D-106 is the invariant this AC enforces). **Test:**
`test/tau/tui/app_test.exs`.

### AC-7 (D-106) — Prose with `/` passes through

`/usr/bin is a path` + Enter (a line with whitespace) is sent to the model as
prose (status → `:streaming`). The unknown-command guard MUST NOT intercept it.

**Advances:** D-106 (C8-B5). **Test:** `test/tau/session/unknown_command_test.exs`.

### AC-8 (D-107) — Catalog/dispatcher precedence parity (property test)

For every `Catalog.list/1` entry (with a realistic `session_data`),
`classify_slash_command/2` resolves the same name to the same origin. The
catalog and the dispatcher cannot disagree.

**Advances:** D-107 (C12-B3). **Test:** property test in
`test/tau/commands/catalog_test.exs` tagged `@tag :property`.

### AC-9 (D-108) — Pre-broadcast `/` shows builtins floor

`/` pressed before the `CommandCatalog` broadcast arrives shows builtins (the
always-present compile-time floor) and does NOT crash. This guards C3-B1.

**Advances:** D-104 (temporal-coupling invariant). **Test:**
`test/tau/tui/app_test.exs` — model with `catalog: []`.

### AC-10 (D-109) — Bare `/` + Enter does not crash

A bare `/` followed by Enter (empty command with whitespace-free `/`-only
input) does NOT crash, does NOT submit prose to the model, and produces a
`SystemNotice`. Guards C7-B5.

**Advances:** D-109. **Test:** `test/tau/session/unknown_command_test.exs`.

### AC-11 — `/reload` re-broadcasts catalog

After `/reload`, a command discovered post-`SessionStart` appears in `/help`
and in the menu without a session restart. Guards C6-B1 (D-108).

**Advances:** D-108. **Test:** integration assertion in
`test/tau/commands/catalog_test.exs` verifying the `CommandCatalog` event is
re-broadcast on `/reload`.

## 6. D-NNN invariant table

| D-NNN | Statement |
|-------|-----------|
| D-100 | `/help` runs via `{:notice, lines}` outcome — no provider turn (D-042 complement). |
| D-101 | An unrecognized `/`-token with no whitespace and no catalog match produces a `SystemNotice`; it MUST NOT be forwarded to the model as `{:sync, msg}`. |
| D-102 | Menu state is MVU-local (`nil | %{query, entries, selected}`); it is NOT a supervised process. |
| D-103 | The `CommandCatalog` event is the ONLY mechanism for delivering the catalog to the TUI. The TUI MUST NOT call the session FSM synchronously on the render path to fetch catalog data. |
| D-104 | When no `CommandCatalog` has been received yet, the builtins floor (`Builtin.table/0`) is used as the candidate set. The menu MUST NOT crash on a missing catalog. |
| D-105 | `Esc` while the menu is open dismisses the menu. The `Esc`-dismiss clause MUST precede the `Esc`→`cancel/1` clause in `update/2`. |
| D-106 | `Enter` while the menu is open fills the input with `name <> " "` and closes the menu. It MUST NOT submit the turn. |
| D-107 | Catalog precedence is `builtin > extension > file > skill > template`. This ordering MUST match `classify_slash_command/2`. |
| D-108 | The `CommandCatalog` event is re-broadcast after every `/reload` so post-`SessionStart` discoveries appear in the menu without a session restart. |
| D-109 | `Tau.TUI.Fuzzy.match/2` with an empty query returns all entries in input order with score 0. It MUST NOT crash or return empty. |

## 7. #344 extension point

When `@`-mention autocomplete (#344) lands, it:

1. Adds a new candidate source to its own model field (e.g. `model.file_catalog`)
  — separate from `model.catalog` which is the command catalog.
2. Reuses `Tau.TUI.Fuzzy.match/2` unchanged.
3. Opens a second menu sub-state (or extends the existing menu with a
  `source` discriminator).
4. Adds its ACs and D-NNN into this SPEC as a new §5 section.

#344 does NOT modify D-100..D-109; it extends with new invariants from the
same block (D-100..D-109 are reserved for this SPEC).

## Appendix A — PSDH method reference

See `.claude/skills/design-reasoning`.

## Appendix B — Source map

Files that are in scope of this SPEC (changes to any of these trigger
spec-before-code compliance):

| File | Role |
|------|------|
| `lib/tau/tui/fuzzy.ex` | B4 — pure fuzzy scorer |
| `lib/tau/commands/catalog.ex` | B3 — pure catalog projection |
| `lib/tau/commands/builtin/help.ex` | AC-1 — `/help` builtin |
| `lib/tau/commands/builtin.ex` | `description/0` callback + table update |
| `lib/tau/session/events.ex` | `CommandCatalog` event struct |
| `lib/tau/session.ex` | catalog broadcast + unknown-command guard (B5) |
| `lib/tau/tui/app.ex` | menu MVU state (B2) |
| `test/tau/tui/fuzzy_test.exs` | B4 property + unit tests |
| `test/tau/commands/catalog_test.exs` | B3 unit + AC-8 property test |
| `test/tau/commands/builtin/help_test.exs` | AC-1 unit tests |
| `test/tau/session/unknown_command_test.exs` | AC-2, AC-7, AC-10 unit tests |

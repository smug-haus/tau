# Inventory: `lib/tau/tui/app.ex`

1,508 LOC | 83 functions (7 public, 76 private) | 23-field anonymous-map
MVU model | 1 `try/rescue` site (`cost_for_session/1`)

Wrapped in `if Code.ensure_loaded?(Ratatouille.Runtime) do … end` so all
definitions are conditional on the optional dep.

## 1. Cluster candidates (extraction targets)

Each cluster moves to one new sub-module under `lib/tau/tui/app/`.

### Cluster A → `Tau.TUI.App.Model` (keystone defstruct)

The 23-field bare-map MVU model becomes a typed struct. `init/1`'s
field-initialization body moves into `Model.new/1`.

Fields:

| Field | Type | Initial | Mutated by |
|---|---|---|---|
| `session_id` | `String.t()` | `Tau.Session.generate_id()` | init only |
| `editor` | `Tau.TUI.Editor.t()` | `Editor.new()` | keymap, history, alt, submit |
| `history` | `Tau.TUI.History.t()` | `Store.load/2` | history, search, submit |
| `search` | `nil \| map()` | `nil` | search ops, keymap |
| `history_data_dir` | `String.t()` | `Tau.Settings.data_dir()` | init only |
| `history_cwd` | `String.t()` | `File.cwd!()` | init only |
| `transcript` | `[{String.t(), keyword()}]` | `[]` | `bounded_append`, events |
| `subagents` | `%{String.t() => SubagentNode.t()}` | `%{}` | `on_subagent_*` |
| `status` | `:idle \| :streaming \| :sending \| String.t()` | `:idle` | message/session events, submit |
| `last_assistant` | `String.t() \| nil` | `nil` | message events |
| `coding_agent` | `module() \| nil` | runtime_opts | init only |
| `wrap_width` | `pos_integer()` | computed | init, resize |
| `catalog` | `[map()] \| nil` | `nil` | `CommandCatalog` event |
| `menu` | `nil \| map()` | `nil` | menu ops, keymap |
| `pending_permissions` | `[PermissionRequest.t()]` | `[]` | permission events |
| `permissions_mode` | `:default \| :accept_edits \| :plan` | runtime_opts | init, `/perms` |
| `provider` | `module()` | `init_provider/1` | init, session events |
| `model` | `String.t()` | `init_model/1` | init, session events |
| `usage` | `map()` | `%{...}` | `on_message_end` |
| `context_tokens` | `non_neg_integer()` | `0` | `on_message_end` |
| `context_window` | `pos_integer() \| nil` | `nil` | init, session events |
| `compaction` | `:idle \| :running` | `:idle` | compaction events |
| `warn_level` | `:ok \| :warn \| :critical` | `:ok` | `on_message_end` |

### Cluster B → `Tau.TUI.App.Bootstrap` (~185 LOC)

- `init/1` (40-138, 99 LOC) — main initialization (most moves to `Model.new/1`)
- `put_if/3` (140, 2 LOC)
- `init_provider/1` (146, 3 LOC)
- `init_model/1` (153, 15 LOC)
- `transcript_pane_width/1` (172, 5 LOC)
- `run/0` (708, 33 LOC) — Ratatouille bootstrap
- `start_runtime_supervisor/0` (742, 17 LOC)
- `await_down/2` (760, 6 LOC)

### Cluster C → `Tau.TUI.App.History` (~81 LOC)

- `history_prev/1` (901, 13 LOC)
- `history_next/1` (917, 12 LOC)
- `restore_editor_from_text/1` (932, 7 LOC)
- `search_start/1` (943, 11 LOC)
- `search_accept/2` (956, 12 LOC)
- `search_nth_match/3` (971, 11 LOC)
- `search_cancel/1` (984, 5 LOC)

Property tests: history navigation reversibility; multiline restore
round-trip (text → editor → text equals original).

### Cluster D → `Tau.TUI.App.Completion` (~67 LOC)

- `catalog_floor/0` (993, 10 LOC)
- `effective_catalog/1` (1005, 2 LOC)
- `update_menu/1` (1012, 19 LOC)
- `close_menu_if_whitespace/1` (1033, 9 LOC)
- `menu_navigate/2` (1044, 7 LOC)
- `menu_accept/1` (1054, 16 LOC)
- `clamp/2` (1071, 4 LOC)

Property tests: fuzzy-match precedence; whitespace-token gate
(menu closes on space).

### Cluster E → `Tau.TUI.App.Keymap` (~215 LOC)

- `handle_event/1` (319, 6 LOC) — top-level router
- `handle_event_normal/2` (326, 9 LOC)
- `handle_key/3` (362, 66 LOC) — integer-keyed case matrix
- `handle_readline_key/2` (438, 56 LOC) — Ctrl+chord matrix
- `arrow_up/1` (497, 9 LOC) — edge-aware
- `arrow_down/1` (509, 10 LOC) — edge-aware
- `handle_alt/3` (528, 24 LOC) — alt-chord
- `handle_char/2` (555, 14 LOC)
- `editor_insert/2` (887, 3 LOC)
- `editor_backspace/1` (892, 3 LOC)
- `submit_or_continue/1` (1080, 15 LOC)
- `quit_or_append/1` (870, 15 LOC)

### Cluster F → `Tau.TUI.App.Input` (~130 LOC)

- `submit/1` (1096, 31 LOC)
- `handle_perms_command/1` (1133, 39 LOC)
- `cancel/1` (1173, 4 LOC)
- `steer/1` (1182, 16 LOC)
- `followup/1` (1203, 22 LOC)
- `clear_input/1` (1228, 3 LOC)

### Cluster G → `Tau.TUI.App.View` (~182 LOC)

- `render/1` (580, 53 LOC) — top-level Ratatouille view
- `render_menu/1` (639, 21 LOC)
- `menu_entry_text/1` (690, 9 LOC)
- `status_bar/1` (772, 3 LOC)
- `status_bar_model/1` (781, 21 LOC)
- `prompt/1` (810, 11 LOC)
- `build_prompt_labels/1` (822, 34 LOC)
- `inject_cursor/2` (858, 5 LOC)

### Cluster H → `Tau.TUI.App.Events` (~211 LOC)

- `update/2` (179, 45 LOC) — primary event dispatcher (this stays on `Tau.TUI.App` as the MVU callback)
- `update_session_event/2` (228, 71 LOC) — sub-dispatcher
- `drain_bridge/1` (573, 5 LOC)
- `on_subagent_start/2` (1239, 10 LOC)
- `on_subagent_progress/2` (1253, 3 LOC)
- `on_subagent_cost/2` (1259, 3 LOC)
- `on_subagent_end/2` (1266, 18 LOC)
- `on_queue_restored/2` (1295, 21 LOC)
- `on_message_start/2` (1317, 1 LOC)
- `on_message_update/2` (1319, 8 LOC)
- `on_message_end/2` (1328, 77 LOC) — largest event handler
- `cost_for_session/1` (1408, 8 LOC) — **`try/rescue` site (audit)**
- `on_tool_start/2` (1421, 1 LOC)
- `on_tool_end/2` (1423, 1 LOC)
- `on_cancelled/2` (1425, 10 LOC)
- `on_session_end/2` (1436, 11 LOC)
- `on_session_start_status/4` (1451, 4 LOC)
- `on_model_swapped/2` (1458, 5 LOC)
- `resolve_context_window/2` (1468, 12 LOC)
- `on_compaction_started/1` (1482, 1 LOC)
- `on_compaction_finished/1` (1487, 1 LOC)
- `bounded_append/2` (1494, 9 LOC)
- `bounded_append_many/2` (1504, 3 LOC)

`update/2` itself stays on `Tau.TUI.App` (Ratatouille `@behaviour`
callback). The body delegates to `Events.update/2` for the event-shape
dispatch, but the entry point remains here.

### Cluster I → `Tau.TUI.App.Permission` (~55 LOC)

- `handle_permission_dialog_event/2` (339, 10 LOC)
- `resolve_permission/2` (352, 7 LOC)
- `render_permission_dialog/2` (664, 25 LOC)
- `on_permission_request/2` (1287, 4 LOC)

## 2. Stays on `Tau.TUI.App` (~400 LOC after extraction)

Ratatouille `@behaviour` callbacks: `init/1`, `update/2`, `render/1`,
`subscribe/1`. Plus the conditional-compile wrapper. The bodies become
delegations:

```elixir
def init(context), do: Tau.TUI.App.Bootstrap.init(context)
def update(model, msg), do: Tau.TUI.App.Events.update(model, msg)
def render(model), do: Tau.TUI.App.View.render(model)
def subscribe(model), do: # adaptive-tick logic remains inline (5 LOC)
```

## 3. Comment-archaeology density

`tui/app.ex` carries ~100+ inline citations of `D-NNN` / `AC-N` / `SPEC-X §Y`
in current state. The Phase 1 sweep against this file already removed
~30% of issue-citation parentheticals. The remaining citations are
durable (per ADR-0023: `D-NNN`, `AC-N`, `SPEC §Y` references identify
invariants). They stay.

What does NOT carry over to new modules: any `FIX-N` / `BLOCKING-N` /
`C##-B##` / "Phase ..." / process-history vocabulary. The extraction
purges any such tag found.

## 4. Source-order discipline

The `update/2` clause order, the `handle_key/3` case matrix order, and
the `handle_readline_key/2` case matrix order are all load-bearing. They
move into their new modules preserving order exactly. The catch-all
arms (`_ -> model`, `_ -> :ok`) stay last.

The audit's L307–319 block (alt-chord precedence + permission-dialog
capture) is documented load-bearing intent — keep the comment.

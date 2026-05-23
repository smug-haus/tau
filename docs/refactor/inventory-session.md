# Inventory: `lib/tau/session.ex`

5,208 LOC | 240 functions (62 public, 178 private) | 41 `handle_event/4` clauses
| 8 `try/rescue` sites | 69-field anonymous-map FSM `data`

States: `:awaiting_user`, `:provider_streaming`, `:tool_executing`,
`:awaiting_permission`, `:compacting`, `:stopped`.

## 1. Cluster candidates (extraction targets)

Each cluster moves to one new sub-module under `lib/tau/session/`. Names
are chosen to avoid collision with top-level namespaces (`Tau.Persistence`,
`Tau.Provider`, `Tau.Permissions`).

### Cluster A → `Tau.Session.Journal` (~120 LOC)

Pure persistence/serialization helpers. No FSM clauses move with this.

- `persist_event/3` (line 3594, 15 LOC) — write event to persistence layer
- `message_to_data/1` (4620, 4622, 4632) — serialize User/Assistant/ToolResult
- `tool_result_to_data/1` (4634, 11 LOC)
- `event_to_message/1` (4753, 4757, 4766, 4776, 4781) — deserialize JSONL → message
- `events_to_messages/1` (4747, 6 LOC) — preload → message list
- `deserialize_block/1` (4859, 4861, 4864, 4867)
- `deserialize_blocks/1` (4854, 4857)
- `serialize_block/1` (4648, 4650, 4654, 4657, 4660)
- `serialize_content/1` (4645, 4646)
- `format_summary_for_persist/1` (4848, 4850)
- `stop_reason_atom/1` (4869, 4870, 4871) — fix per audit: use `to_existing_atom` not `to_atom`

Data fields touched: `messages`, `persistence`, `persist_handle`, `id`.

Property tests: round-trip serialise → deserialise → equals original.

### Cluster B → `Tau.Session.Queue` (~150 LOC)

Steering + followup queue operations. FSM clauses move.

- `drain_steering_queue_one/1` (5188, 21 LOC)
- FSM clauses to move (as one-line delegations from `session.ex`):
  - `handle_event(:cast, {:user_message, _, _}, state, _)` (815) — postpone when command_task present
  - `handle_event(:cast, {:user_message, msg, tier}, state, data) when state != :awaiting_user` (824, 41 LOC) — tier routing
  - `handle_event(:internal, :drain_followups, :awaiting_user, _)` (906, 28 LOC)
  - `handle_event(:internal, :drain_followups, _state, _)` (934)
  - `handle_event(:internal, :drain_steering_queue, :provider_streaming, _)` (2174, 67 LOC)
  - `handle_event(:info, {:provider_dispatch, _id}, _, _)` (2241, 23 LOC)

Data fields touched: `steering_queue`, `followup_queue`, `command_task`.

Property tests: FIFO order; 32-cap drops with `%SystemNotice{}`;
`:cancel` empties `steering_queue` to `%QueueRestored{}`.

### Cluster C → `Tau.Session.Compaction` (~70 LOC of logic + 3 FSM clause delegations)

- `maybe_compact/2` (2695, 24 LOC)
- `do_compact/2` (2719, 41 LOC)
- `emit_cache_usage/2` (2678, 12 LOC)
- FSM clauses:
  - `handle_event(:info, {ref, result}, :compacting, %{compaction_monitor: ref} = data)` (1883, 68 LOC)
  - `handle_event(:info, {:DOWN, ref, :process, pid, reason}, :compacting, _)` (1951, 14 LOC)
  - `handle_event(:info, {:compaction_timeout, pid, ms}, _state, _)` (2049, 31 LOC)

Data fields: `compaction_task`, `compaction_monitor`, `compaction_failures`,
`messages`, `persistence`.

Property tests: D-016 — `compaction_failures` not reset by `:cancel`;
monotone increment on `{:error, _}`; reset to 0 only on `{:ok, _}`.

### Cluster D → `Tau.Session.ModelSwap` (~50 LOC)

- `do_swap_model/2` (3542, 10 LOC)
- `apply_model_swap/2` (3552, 23 LOC)
- `reconfigure_model/2` (3575, 3577)
- `handle_slash_model_swap/2` (5144, 14 LOC)
- FSM clauses:
  - `handle_event({:call, from}, {:swap_model, model}, :awaiting_user, _)` (1845, 11 LOC)
  - `handle_event({:call, from}, {:swap_model, _}, _state, _)` (1856, 27 LOC) — busy
  - `handle_event(:cast, {:reconfigure, opts}, _state, _)` (1764, 31 LOC)

Property tests: busy-state rejection; nil model is no-op; idempotency.

### Cluster E → `Tau.Session.SkillActivation` (~220 LOC)

- `handle_skill_activations/3` (4485, 4487)
- `skill_activation_tool_spec/1` (4374, 44 LOC)
- `activate_skill/3` (4551, 4561)
- `activate_skill_via_slash/2` (4523, 28 LOC)
- `skill_name_from_args/1` (4510, 4514)
- `model_visible_tool_specs/1` (4434, 19 LOC)
- `active_skill_tool_specs/1` (4453, 4455, 4461)
- `tool_spec_for/1` (4470, 15 LOC)
- `model_invokable_skills/1` (4370, 4 LOC)
- `prepend_skill_messages/2` (4693, 16 LOC)
- `render_skill/2` (4709, 13 LOC)
- `load_skills/1` (4671, 22 LOC)
- `inject_memory/2` (4722, 25 LOC)

Data fields: `skills`, `active_skill`, `persona_lifetime`, `messages`, `cwd`.

Property tests: `:turn` lifetime clears `active_skill` on `:end_turn`;
`:session` lifetime survives `:end_turn`; precedence builtin > extension >
skill > template.

### Cluster F → `Tau.Session.SlashCommand` (~450 LOC)

- `classify_slash_command/4` (4888, 4943, 55+1 LOC)
- `unknown_or_passthrough/3` (4948, 4949)
- `build_template_context/1` (4951, 15 LOC)
- `spawn_command_task/3` (4966, 32 LOC) — **has `try/rescue` site at 4979-4990 (audit §1)**
- `apply_command_result/2` (4998, 43 LOC)
- `prepare_command_args/2` (5041, 5049)
- `handle_builtin_command/4` (5057, 77 LOC)
- `outcome_tag/1` (5134, 5 LOC)
- `invoke_file_command/3` (5158, 7 LOC)
- `build_command_ctx/1` (5165, 23 LOC)
- `register_builtins/0` (4607, 13 LOC)
- FSM clauses:
  - `handle_event(:cast, {:user_message, msg, _}, :awaiting_user, _)` (865, 41 LOC) — classification dispatch
  - `handle_event(:info, {:command_done, result, msg}, _state, _)` (938, 5 LOC)
  - `handle_event(:info, {:command_timeout, pid, msg, ms}, _state, _)` (943, 11 LOC)
  - `handle_event(:info, {:command_timeout, _, _, _}, _state, _)` (954, 6 LOC) — stale

Data fields: `skills`, `prompt_templates`, `cwd`, `command_task`, `model`,
`provider`, `messages`.

### Cluster G → `Tau.Session.ProviderTurn` (~650 LOC)

- `emit_provider_request_terminal/2` (2329, 23 LOC)
- `cancel_provider_task/1` (2352, 43 LOC) — **`Task.yield` + `Task.shutdown`**
- `brutal_kill_provider_task/1` (2395, 11 LOC)
- `lookup_fallback_chain/1` (3642, 9 LOC)
- `resolve_provider/1` (487, 489, 497) — **has `try/rescue` site at 490-495 (audit §1)**
- `merge_provider_ctx/2` (3588, 3590)
- `maybe_replace/3` (3585, 3586)
- `finalize_assistant/2` (2439, 239 LOC) — large
- `nonneg_token/1` (2690, 2 LOC)
- `process_user_message/2` (2406, 32 LOC)
- `current_run?/2` (2314, 6 LOC)
- `transition/3` (3651, 9 LOC)
- `describe_provider_error/1` (3667, 27 LOC)
- FSM clauses (7):
  - `handle_event(:internal, :start_provider, :provider_streaming, _)` (960, 241 LOC) — **has `try/rescue` site at 1041-1051 (audit §1)**
  - `handle_event(:info, {:provider_event, ref, _}, _, _)` (1249, 77 LOC)
  - `handle_event(:info, {:provider_event, wrong_ref, _}, _, _)` (1326, 10 LOC)
  - `handle_event(:info, {:provider_done, ref}, _, _)` (1336, 13 LOC)
  - `handle_event(:info, {:provider_done, wrong_ref}, _, _)` (1417, 25 LOC)
  - `handle_event(:info, {:provider_cancelled, ref}, _, _)` (1442, 21 LOC)
  - `handle_event(:info, {:provider_error, ref, _}, _, _)` (1349, 68 LOC)
  - `handle_event(:info, {:provider_fallback, ref, reason}, _, _)` (1463, 26 LOC)
  - `handle_event(:internal, :finish_provider, :provider_streaming, _)` (1965, 40 LOC)
  - `handle_event(:internal, :end_turn, state, _)` (2005, 44 LOC)

Data fields: `provider`, `original_provider`, `provider_task`, `stream_ref`,
`provider_span_ref`, `cancel_flag`, `assembler`, `fallback_chain_remaining`,
`provider_ctx`, `messages`, `model`, `metadata`, `compaction_task`,
`compaction_monitor`, `provider_retry_state`, `provider_retry_max`,
`provider_retry_base_delay_ms`.

Property tests: `stream_ref` staleness drop; fallback chain monotonicity;
retry-budget monotonicity per turn.

### Cluster H → `Tau.Session.CodingAgentTurn` (~550 LOC)

- `ensure_coding_agent_workspace/1` (3733, 27 LOC)
- `start_coding_agent_dispatcher/2` (3790, 92 LOC)
- `emit_coding_agent_sync_error/2` (3760, 30 LOC)
- `handle_coding_agent_event/2` (3916, 3934, 3947, 3986, 4034, 4044, 4074, 4106)
- `append_assistant_text/2` (4115, 13 LOC)
- `flush_pending_assistant/2` (4128, 4131)
- `finalize_coding_agent_turn/2` (4149, 73 LOC)
- `tool_name_for/2` (4222, 14 LOC)
- `maybe_apply_cost_hook/2` (4236, 55 LOC) — **has `try/rescue` site at 4237-4268 (audit §1)**
- `maybe_capture_coding_agent_session/2` (4291, 4293, 4312)
- `describe_coding_agent_error/1` (4320, 11 LOC)
- `latest_user_text/1` (3882, 34 LOC)
- `agent_to_string/1` (4314, 3 LOC)
- `agent_to_atom/1` (4829, 4831, 4837, 4838) — **has `try/rescue` site at 4831-4836 (audit §1)**
- `coding_agent_from_settings/0` (3628, 14 LOC)
- `coding_agent_state_from_preload/1` (4801, 4814)
- `coding_agent_costs_from_preload/1` (4820, 4827)
- FSM clauses (2):
  - `handle_event(:internal, :start_coding_agent, :coding_agent_streaming, _)` (1201, 23 LOC)
  - `handle_event(:info, {:coding_agent_event, pid, event}, _state, _)` (1224, 14 LOC)
  - `handle_event(:info, {:coding_agent_event, other_pid, _}, _state, _)` (1238, 11 LOC)

Data fields: `coding_agent`, `coding_agent_ctx`, `coding_agent_workspace`,
`coding_agent_workspace_backend`, `coding_agent_workspace_opts`,
`coding_agent_dispatcher`, `coding_agent_pending`, `coding_agent_blocks`,
`coding_agent_state`, `coding_agent_costs`, `messages`, `cwd`.

### Cluster I → `Tau.Session.ToolDispatch` (~650 LOC)

- `dispatch_tools/2` (2760, 307 LOC) — **largest single function**
- `finish_permission_round/1` (3147, 138 LOC)
- `split_tools_whitelist/2` (3132, 3134)
- `whitelist_size/1` (3138, 3139)
- `tool_args_hash/1` (3292, 15 LOC) — **has `try/rescue` site at 3299-3303 (audit §1)**
- `canonicalize_for_hash/1` (3308, 3315, 3318)
- `maybe_apply_tool_loop_brake/3` (3322, 3324, 3327)
- `reset_tool_loop_state/1` (3353, 6 LOC)
- `emit_tool_loop_brake_abort/2` (3359, 60 LOC)
- `deny_reason/2` (3419, 12 LOC)
- `run_tool/4` (3431, 107 LOC) — **has `try/rescue` site at 3491-3515 (audit §1)**
- `run_tool_validated/5` (3467, 70 LOC)
- `spawn_parallel_dispatcher/3` (3067, 65 LOC)
- FSM clauses (5):
  - `handle_event(:info, {:tool_done, call_id, result}, :tool_executing, _)` (1795, 50 LOC)
  - `handle_event(:info, {:tool_done, call_id, result}, :awaiting_permission, _)` (2080, 46 LOC)
  - `handle_event(:info, {:DOWN, ref, :process, pid, reason}, :tool_executing, _)` (2126, 48 LOC)
  - `handle_event(:cast, {:permission_decision, tool_call_id, verdict}, _state, _)` (2264, 28 LOC)
  - `handle_event(:cast, :cancel, :awaiting_permission, _)` (1515, 111 LOC)
  - `handle_event({:call, from}, {:set_permissions_mode, mode}, _state, _)` (2292, 11 LOC)
  - `handle_event({:call, from}, {:set_permissions_mode, _}, _state, _)` (2303, 5 LOC)

Data fields: `tools_whitelist`, `tools_in_flight`, `tool_iterations`,
`max_tool_iterations`, `tool_loop_state`, `tool_loop_brake_threshold`,
`tool_loop_call_lookups`, `pending_permission_requests`,
`permission_dispatch_batch`, `permission_pending_results`, `tool_dispatcher`,
`active_skill`, `messages`.

Property tests: deny/ask/allow three-way partition completeness; whitelist
monotonicity; tool-loop brake hysteresis (success resets counter).

### Stays on `Tau.Session` (~2,500 LOC after extraction)

Public API: `start/1`, `send/2`, `steer/2`, `stream/2`, `resume/1`,
`fork/2`, `cancel/1`, `stop/1`, `update_provider/2`, `swap_model/2`,
`decide_permission/3`, `set_permissions_mode/2`, `list_sessions/1`,
`snapshot/1`, `generate_id/0`, `child_spec/1`, `start_link/1`,
`callback_mode/0`, `init/1`, `terminate/2`.

FSM root: `handle_event/4` arms — bodies become one-line delegations
to the sub-modules. Source order remains load-bearing per the existing
invariant.

Other shared helpers: `broadcast/2`, `whereis/1`, `via/1`,
`cascade_to_children/2`, `emit_user_message_telemetry/3`, `hook_payload/3`,
`generate_event_id/0`, `parent_event_id/1`, `transcript_path/1`,
`model_from_preload/1`. These are called by many sub-modules and stay
on the façade.

## 2. Keystone defstruct: `Tau.Session.Data`

The 69-field FSM `data` map becomes a typed struct. `init/1`'s 259-LOC
body moves into `Data.new/1`.

Field list (alphabetised, with type and purpose):

| Field | Type | Notes |
|---|---|---|
| `id` | `String.t()` | Session UUID; required |
| `cwd` | `String.t()` | Working directory |
| `provider` | `module()` | Current provider; mutates during fallback |
| `original_provider` | `module()` | User-configured; restored after fallback |
| `model` | `String.t()` | LLM model id |
| `metadata` | `map()` | User-supplied JSON-encodable |
| `provider_ctx` | `map()` | Per-request provider context |
| `messages` | `[Tau.Message.t()]` | Full history |
| `skills` | `[{String.t(), Tau.Skill.t()}]` | Discovered skills |
| `prompt_templates` | `[{String.t(), Tau.PromptTemplate.t()}]` | Discovered templates |
| `persistence` | `module()` | Backend |
| `persist_handle` | `term()` | Opaque backend handle |
| `provider_task` | `Task.t() \| nil` | Streaming task |
| `stream_ref` | `reference() \| nil` | Per-stream discriminator |
| `provider_span_ref` | `reference() \| nil` | OTel span ref |
| `cancel_flag` | `:counters.counters_ref() \| nil` | Cooperative cancel |
| `assembler` | `Tau.Message.Assembler.t() \| nil` | In-flight builder |
| `fallback_chain_remaining` | `[module()]` | Per-turn ADR-0012 chain |
| `tools_in_flight` | `map()` | `call_id -> status` |
| `tool_dispatcher` | `pid() \| nil` | Parallel dispatcher |
| `command_task` | `pid() \| nil` | Slash-command task |
| `active_skill` | `Tau.Skill.t() \| nil` | Per-turn or per-session |
| `persona_lifetime` | `:turn \| :session` | |
| `tools_whitelist` | `:all \| [String.t()]` | Spawn-time |
| `child_session_ids` | `MapSet.t(String.t())` | ADR-0014 children |
| `tool_iterations` | `non_neg_integer()` | Per-turn counter (D-005) |
| `max_tool_iterations` | `pos_integer()` | Cap |
| `tool_loop_state` | `map()` | D-060 brake state |
| `tool_loop_brake_threshold` | `pos_integer()` | |
| `tool_loop_call_lookups` | `map()` | `call_id -> {name, hash}` |
| `provider_retry_state` | `%{count: non_neg_integer()}` | D-061 |
| `provider_retry_max` | `pos_integer()` | |
| `provider_retry_base_delay_ms` | `pos_integer()` | |
| `coding_agent` | `module() \| nil` | SPEC-CODING-AGENT |
| `coding_agent_ctx` | `map()` | |
| `coding_agent_workspace_backend` | `module() \| nil` | |
| `coding_agent_workspace_opts` | `keyword()` | |
| `coding_agent_workspace` | `Tau.CodingAgent.Workspace.t() \| nil` | Lazy |
| `coding_agent_dispatcher` | `pid() \| nil` | |
| `coding_agent_pending` | `Tau.Message.Assistant.t() \| nil` | In-flight |
| `coding_agent_blocks` | `[map()]` | Block accumulator |
| `coding_agent_state` | `map()` | Adapter session state (D-037) |
| `coding_agent_costs` | `[Tau.CodingAgent.Cost.t()]` | Per-session ledger (D-038) |
| `compaction_task` | `Task.t() \| nil` | Async worker |
| `compaction_monitor` | `reference() \| nil` | Worker monitor |
| `compaction_failures` | `non_neg_integer()` | D-016 — not reset on cancel |
| `interactive?` | `boolean()` | Headless `tau run` = `false` (D-092) |
| `pending_permission_requests` | `map()` | `call_id -> req` |
| `permission_dispatch_batch` | `[{String.t(), String.t(), map()}]` | |
| `permission_pending_results` | `[{String.t(), Tau.Message.ToolResult.t()}]` | |
| `steering_queue` | `:queue.queue()` | D-077 |
| `followup_queue` | `:queue.queue()` | D-078 |

(Fields are listed grouped by concern in the actual struct; `@enforce_keys`
covers `id`, `cwd`, `provider`, `original_provider`, `model`,
`persistence`, `persist_handle`.)

## 3. `try/rescue` / `catch :exit` sites (audit §1)

All 8 sites that violate OTP non-negotiable #7. Each MUST NOT be replicated
in the extraction. Removal/refactor of these is OUT OF SCOPE for the
decomposition PRs (separate Tier 1 follow-up). They remain in the
extracted modules in their existing form.

| Line | Function | Cluster | What it wraps |
|---|---|---|---|
| 425-429 | `snapshot/1` | stays on `Tau.Session` | `:sys.get_state(pid)` |
| 490-495 | `resolve_provider/1` | `ProviderTurn` | `String.to_existing_atom` |
| 1041-1051 | `:start_provider` body | `ProviderTurn` | Provider stream enumeration |
| 3299-3303 | `tool_args_hash/1` | `ToolDispatch` | `Jason.encode!` |
| 3491-3515 | `run_tool_validated/5` | `ToolDispatch` | `mod.execute/2` |
| 4237-4268 | `maybe_apply_cost_hook/2` | `CodingAgentTurn` | Cost hook |
| 4831-4836 | `agent_to_atom/1` | `CodingAgentTurn` | `String.to_existing_atom` |
| 4979-4990 | `spawn_command_task/3` | `SlashCommand` | Command module `.execute/2` + `catch :exit` |

## 4. Top private helpers (call graph)

These are called from many clusters; they stay on the `Tau.Session`
façade so every sub-module can call them via `Tau.Session.broadcast/2`
etc., or move to a shared `Tau.Session.Util` if grouping is preferred:

| Function | Caller count |
|---|---|
| `broadcast/2` | 66 |
| `persist_event/3` | 28 (moves into `Journal` but sub-modules call `Journal.persist/3`) |
| `append_message/2` | 15 |
| `whereis/1` | 10 |
| `message_to_data/1` | 10 (moves into `Journal`) |
| `current_run?/2` | 7 (moves into `ProviderTurn`) |
| `transition/3` | 4 |

Recommendation: keep `broadcast/2`, `whereis/1`, `via/1`, `transition/3`,
`cascade_to_children/2`, `hook_payload/3`, `emit_user_message_telemetry/3`,
`generate_event_id/0`, `parent_event_id/1`, `transcript_path/1` on
`Tau.Session` as private facade-helpers. Sub-modules call them via
`Tau.Session.broadcast(data.id, event)`. The function becomes public on
`Tau.Session` (`@doc false` so it's not user-facing API).

## 5. Source-order discipline (FSM clauses)

`session.ex` declares FSM clauses in load-bearing order. The catch-all
`handle_event(_type, _event, _state, data) -> {:keep_state, data}` (2307)
MUST remain last. The five `:compacting` terminal clauses must remain in
their documented order. The `awaiting_permission` `:cancel` clause must
precede the cross-cutting `:cancel` clause.

When clause bodies move to sub-modules, the clause heads stay registered
in `session.ex` in their existing order. Bodies become one-line
delegations:

```elixir
def handle_event(:internal, :start_provider, :provider_streaming, data) do
  Tau.Session.ProviderTurn.start(data)
end
```

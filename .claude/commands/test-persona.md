---
name: test-persona
description: >
  Run three synthetic exercises to validate subagent personas (critic,
  reviewer, implementer). Each exercise contains planted flaws that
  the persona should detect.
allowed-tools: Read, Bash, Grep, Glob, Task
---

Run three validation exercises to confirm subagent personas behave correctly. Each exercise has planted flaws; the persona must detect them.

---

## Exercise 1: Critic Validation

Spawn a Task agent (do NOT use `subagent_type: "critic"` — project-local agents at
`.claude/agents/critic.md` are not auto-registered by Claude Code; see
`.claude/skills/tau-architecture/SKILL.md` §Subagent Routing for details).

**Compose the Task prompt:**
1. Read `.claude/agents/critic.md`.
2. Skip the first two standalone `---` lines and paste the remaining body verbatim.
3. Append the task below.

**Prompt to critic (inline persona + task):**

> Review this Elixir module design. Identify all design flaws, OTP violations, and testing gaps. Reference `.claude/rules/otp-non-negotiables.md` for each violation.
>
> ```elixir
> defmodule Tau.SessionCache do
>   @moduledoc """
>   Caches active session metadata for fast lookup.
>   User-visible operation: `lookup/1` is called on every tool dispatch.
>   """
>
>   use GenServer
>
>   # Module-level ETS table — not owned by any supervised process
>   @table :session_cache
>
>   def start_link(_opts) do
>     GenServer.start_link(__MODULE__, [], name: __MODULE__)
>   end
>
>   @impl GenServer
>   def init(_) do
>     :ets.new(@table, [:set, :public, :named_table])
>     {:ok, %{}}
>   end
>
>   @doc "Store runtime API key override for a session."
>   def put_api_key(session_id, key) do
>     Application.put_env(:tau, {:api_key, session_id}, key)
>   end
>
>   @doc "Look up a session by id."
>   def lookup(session_id) do
>     case :ets.lookup(@table, session_id) do
>       [{^session_id, data}] -> {:ok, data}
>       [] -> {:error, :not_found}
>     end
>   end
>
>   @doc "Notify all subscribers that a session was evicted."
>   def evict(session_id) do
>     :ets.delete(@table, session_id)
>     subscribers = Application.get_env(:tau, :cache_subscribers, [])
>     Enum.each(subscribers, fn pid -> send(pid, {:evicted, session_id}) end)
>   end
>
>   @doc "Wraps pure key derivation in a server call."
>   def derive_cache_key(session_id, suffix) do
>     GenServer.call(__MODULE__, {:derive, session_id, suffix})
>   end
>
>   @impl GenServer
>   def handle_call({:derive, session_id, suffix}, _from, state) do
>     {:reply, "#{session_id}:#{suffix}", state}
>   end
> end
> ```

**Expected critic output — all four must be present:**
- `Application.put_env/3` used for runtime state (`put_api_key/2`) — violates OTP non-negotiable #1 (no `Application.put_env/3` for runtime state)
- `:ets` table created with `:public` and not owned by its managing process — violates OTP non-negotiable #1 (no `:ets` outside an owner process); if the GenServer crashes the ETS table is orphaned or its owner crashes without cleanup
- Cross-process event delivery via bare `send/2` to pid list from `Application.get_env` — violates OTP non-negotiable #4 (must use `Phoenix.PubSub` or monitored refs, never `Process.whereis/1 |> send(...)` pattern)
- `derive_cache_key/2` wraps pure string concatenation in a `GenServer.call` — violates OTP non-negotiable #3 (must not wrap stateless logic in a GenServer)
- `lookup/1` is user-visible and perf-sensitive (called on every tool dispatch per the moduledoc) but emits no telemetry — violates OTP non-negotiable #5

**Failure criteria:** If the critic praises the design, gives vague feedback ("looks reasonable"), or misses more than one of the five planted flaws, Exercise 1 fails.

---

## Exercise 2: Reviewer Validation

Spawn a Task agent with the reviewer persona (do NOT use `subagent_type: "reviewer"` for the same reason as Exercise 1):
1. Read `.claude/agents/reviewer.md`. Skip the first two standalone `---` lines and paste the remaining body verbatim.
2. Append the reviewer task below.

**Prompt to reviewer (inline persona + task):**

> An implementer has delivered the following Elixir module and test. The task was:
> "Implement `Tau.Permissions.Evaluator` — a pure module that checks whether a
> tool call is permitted given a permission list. Must be invariant-bearing
> (property tests required), must not use hardcoded configuration, and must
> return tagged tuples — never raise."
>
> Evaluate this output. Run `mix compile --warnings-as-errors` and
> `mix format --check-formatted` before issuing a verdict.
>
> **Delivered file: `lib/tau/permissions/evaluator.ex`**
>
> ```elixir
> defmodule Tau.Permissions.Evaluator do
>   @moduledoc "Evaluates tool-call permissions against a permission list."
>
>   @anthropic_api_base "https://api.anthropic.com/v1"
>
>   @spec evaluate(tool :: String.t(), permissions :: [String.t()]) ::
>           {:ok, :allowed} | {:error, :denied}
>   def evaluate(tool, permissions) do
>     if tool in permissions do
>       {:ok, :allowed}
>     else
>       try do
>         maybe_remote_check(tool)
>       rescue
>         _ -> {:error, :denied}
>       end
>     end
>   end
>
>   defp maybe_remote_check(_tool) do
>     # Placeholder: remote policy lookup not yet implemented
>     {:error, :denied}
>   end
> end
> ```
>
> **Delivered file: `test/tau/permissions/evaluator_test.exs`**
>
> ```elixir
> defmodule Tau.Permissions.EvaluatorTest do
>   use ExUnit.Case, async: true
>
>   alias Tau.Permissions.Evaluator
>
>   test "allowed when tool in permissions" do
>     assert Evaluator.evaluate("Bash(ls *)", ["Bash(ls *)"]) == {:ok, :allowed}
>   end
>
>   test "denied when tool not in permissions" do
>     assert Evaluator.evaluate("Bash(rm -rf *)", ["Bash(ls *)"]) == {:error, :denied}
>   end
> end
> ```

**Expected reviewer output — all three must be present:**
- `@anthropic_api_base "https://api.anthropic.com/v1"` is a hardcoded URL — a configurable value that should come from application config or be passed as a parameter; BLOCKING finding
- Empty `try/rescue` block in `evaluate/2` swallows all errors silently and returns a default (`{:error, :denied}`) rather than propagating or tagging the failure — violates OTP non-negotiable #7 and the reviewer checklist's "silent failures" criterion; BLOCKING finding
- No property tests for an invariant-bearing module (`Tau.Permissions.Evaluator` is named in the OTP non-negotiables as an example requiring `StreamData` properties) — the two example-based tests do not substitute for property coverage of the permission-matching invariant; BLOCKING finding

**Failure criteria:** If the reviewer issues a PASS verdict without catching all three flaws, does not run `mix compile --warnings-as-errors` or `mix format --check-formatted`, or produces an unstructured response lacking PASS/FAIL/PARTIAL verdict, Exercise 2 fails.

---

## Exercise 3: Kill Cascade Validation (Observational)

This exercise validates hook infrastructure. No subagents are spawned. Observe the harness response to a stuck pattern using commands in Tau's typical shape.

**Steps:**
1. Run a bash command that always fails in the shape of a typical Tau build command, three or more times in succession. Example — a `mix` subcommand that does not exist:
   ```
   mix nonexistent_task_xyz
   ```
   Run it at least 3 times via separate Bash tool calls.

2. After each call, observe whether the heuristic monitor fires.

**What to look for:**
- H-003 (repeated failure loop) should trigger at confidence ≥ 0.85 by the third failure
- `.claude/logs/kill-signal.json` should be written with `reason` and `heuristic_id` fields
- The PreToolUse hook should begin denying subsequent tool calls (`blocked: true` in hook response)
- Running `/harness-status` after this sequence should show the active kill signal

**Recovery:** Run `/clear-logs` to reset state after observing the cascade.

**Failure criteria:** If H-003 does not trigger after 3+ repeated failures in `mix`-command shape, or the kill signal is not written, the hook infrastructure is not functioning correctly — or the heuristic patterns do not cover Tau's typical command shape.

---

## Summary: What to Look For

| Exercise | Persona | Key Signal | Failure Signal |
|----------|---------|-----------|----------------|
| 1 | Critic | Names ≥ 4 of 5 OTP violations with rule references | Vague praise, missed violations, or no rule citations |
| 2 | Reviewer | Runs compile+format, catches hardcoded URL + swallowed error + missing property tests | PASS verdict or missing any of the three BLOCKING findings |
| 3 | Hooks | H-003 triggers on `mix`-shape failures, kill signal written, PreToolUse denies | No trigger after 3+ `mix` failures |

All three exercises must pass for persona and hook validation to be considered complete.

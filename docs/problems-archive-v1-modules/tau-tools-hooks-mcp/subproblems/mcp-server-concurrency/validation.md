---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Task-per-invoke with async-contract behaviour enforcement

## Overview

The solution recommends a hybrid of Proposal 1 (per-invoke `Task.start` →
`{ref, rpc_id, result}` delivery, monitored task pid) and Proposal 2
(strip `recv/2` from the `Tau.MCP.Transport` behaviour; document the
non-blocking contract). It claims this satisfies all three acceptance-
criterion clauses (non-blocking send; unconditional `handle_info`
catch-all; pending-map pruning on `:DOWN`) while preventing the
serialisation bug from regressing via the behaviour-level contract. I
extracted seven distinct propositions from the Recommendation, What-
changes, and What-does-not-change sections. Each is validated with the
full six-component Toulmin frame; falsification strategies are chosen
per claim from the catalog in `validate.md`. Six claims withstood;
claim 3 is partially falsified — its qualifier needs narrowing for the
SSE-concurrency case the solution itself flags as an open question.

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This template enforces all six components explicitly with prompts to
counter that variance.

### Claim 1: The Server's `handle_call({:invoke, ...})` returns `{:noreply, state}` immediately after delegating to the transport — the GenServer is not blocked for the network round-trip.

- **Claim (C):** After the change, `handle_call({:invoke, tool, params}, from, state)`
  delegates to `state.transport.send(...)` which spawns a `Task` performing
  the Finch call; the clause returns `{:noreply, state}` synchronously with
  no waiting on the HTTP response. Concurrent `invoke` calls are therefore
  not mutually serialised by Finch latency.
- **Grounds (G):** Today, `lib/tau/mcp/server.ex:108` calls
  `state.transport.send(...)` from inside `handle_call`, and
  `lib/tau/mcp/transport/http.ex:28` invokes `Finch.request(Tau.Providers.Finch)`
  synchronously inside that callback, so the GenServer blocks. Proposal 1's
  sketch (`proposals/proposal-1.md` lines 38–55) replaces this with
  `Task.start(fn -> Finch.request(...) ; Process.send(caller_pid, {ref, rpc_id, result}, []) end)`
  inside `Http.send`. Once the `Task` is spawned the spawning process
  (here the Server) does not wait — `Task.start/1` is documented to
  return `{:ok, pid}` immediately without linking or awaiting
  (https://hexdocs.pm/elixir/Task.html#start/1).
- **Warrant (W):** OTP non-negotiable #1 (`.claude/rules/otp-non-negotiables.md`):
  "Stateful subsystems MUST run as supervised processes." A `GenServer`
  processes its inbox serially; therefore any synchronous I/O performed
  inside a callback determines that subsystem's throughput ceiling. The
  canonical OTP remedy is to spawn an ephemeral process per work item
  so the long-running side-effect does not occupy the message loop.
- **Qualifier (Q):** Holds for the Http transport (per-RPC POST). For
  Stdio the change is a no-op (stdio I/O is already message-driven via
  the Port). For Sse, see claim 3 — Sse's POST is fast but its inbound
  delivery semantics differ.
- **Rebuttal (R):** Would NOT hold if the spawned `Task` itself blocked
  before returning control (e.g., if `Task.start` performed any
  pre-flight synchronous work). It also would NOT hold if Finch's
  internal pool checkout serialised at the connection level for the
  same host — but Finch's pool semantics return a slot quickly under
  normal load (multiple pool entries per host by default).
- **Backing (B):** Cesarini & Vinoski, *Designing for Scalability with
  Erlang/OTP* §7 (task-per-request as the canonical concurrency idiom;
  cited in proposal-1.md `Prior art`). Elixir core documentation on
  `Task.start/1` ("starts a task ... not linked to the caller").

#### Falsification attempt for claim 1

- **Strategy:** counter-example construction + dependency check.
- **Attempt:** Construct an execution where two simultaneous
  `Tau.MCP.Server.invoke/3` calls block one another after the change.
  Trace: call A enters `handle_call` → `Http.send` → `Task.start`
  returns immediately → `handle_call` returns `{:noreply, state}` →
  GenServer dequeues call B → same path. Both `Task` processes are
  independent; the GenServer's mailbox is freed in ~microseconds.
  Dependency check: `Task.start/1` is in Elixir stdlib, not removed
  in 1.18.x. Finch ≥ 0.18 (`mix.exs:51`) exposes `Finch.request/2`
  which is the synchronous call wrapped in the task — no API drift.
- **Outcome:** withstood. I could not construct an execution where
  Server-loop serialisation re-emerges.
- **Action:** none.

### Claim 2: The `handle_info(_msg, state)` catch-all returns `{:noreply, state}` unconditionally — it no longer drains `transport.recv`, and no stray BEAM message can consume a response belonging to a pending caller.

- **Claim (C):** After the change, `server.ex` lines 86–95 (the
  catch-all clause) consist solely of `def handle_info(_msg, state),
  do: {:noreply, state}`. Unrecognised messages have no side effect on
  the transport state, eliminating the drain race that today routes a
  `{:line, _}` to no pending caller.
- **Grounds (G):** Today `lib/tau/mcp/server.ex:86-95` calls
  `state.transport.recv(state.transport_state, 0)` for every
  unrecognised message; for Sse this race is documented in
  `problem.md` lines 35–41 and `Tau.MCP.Transport.Sse.recv/2`
  (`lib/tau/mcp/transport/sse.ex:73-86`) does pull from the same
  mailbox the explicit `handle_info({:line, _}, state)` clause
  expects. Proposal 1 (lines 113–115) and proposal 2 (lines 135–137)
  both prescribe stripping this side-effect. The solution adopts that
  directly (`solution.md` line 77–78).
- **Warrant (W):** OTP non-negotiable #3 ("MUST NOT wrap stateless
  logic in a GenServer") and #7 ("Let it crash; supervise; restart");
  generalised: a GenServer's `handle_info` catch-all is the
  side-effect-free disposal path for unmatched messages — performing
  state-mutating I/O in it violates the locality principle that each
  message-class has one handler.
- **Qualifier (Q):** None — universal. The unconditional return is
  unrestricted by config, transport choice, or state.
- **Rebuttal (R):** Would NOT hold if some current code outside the
  Server depends on the catch-all's side effect (e.g., a test that
  asserts the Server pulls from the SSE queue when poked). I searched
  `lib/tau/` and `test/` for callers that send unrecognised messages
  to the MCP server expecting recv; none found (`find /home/brentw/src/tau/test
  -path '*mcp*'` returns only `test/tau/cli/mcp_test.exs` which uses
  the CLI surface). The dependency does not exist.
- **Backing (B):** Elixir `GenServer` docs:
  "handle_info/2 is invoked to handle all other messages" — its
  semantic role is *disposal*, not behaviour. OTP non-negotiables
  rule 4 forbidding ad-hoc cross-process events reinforces:
  catch-alls should not perform routing.

#### Falsification attempt for claim 2

- **Strategy:** edge-case enumeration + integration check.
- **Attempt:** Enumerate every message class that today routes through
  the catch-all and might lose information once the drain is removed:
  (1) Sse `{ref, {:line, line}}` — already handled by the explicit
  `{:line, _}` clause at `server.ex:84`; once Sse's task forwards as
  `{:line, _}` (today it forwards as `{ref, {:line, line}}` at
  `lib/tau/mcp/transport/sse.ex:47`), it would fall through to the
  catch-all and be discarded. This is a real edge case: the explicit
  clause at `server.ex:84` matches `{:line, line}` (no ref envelope)
  whereas Sse sends `{ref, {:line, line}}` (with ref envelope). The
  solution's new `handle_info({ref, rpc_id, {:line, line}}, state)`
  task-delivery clause (`solution.md` line 72) covers the Task-
  delivered Http case, but the Sse forward shape is `{ref, {:line, line}}`
  (no `rpc_id`) and would need either a separate clause or the Sse
  task forwarder must be modified. (2) `:DOWN` from the monitored
  task pid — explicitly handled by the new `:DOWN` clause. (3)
  Telemetry / Logger / PubSub broadcasts — benign disposal is correct.
  The catch-all stripping is correct *provided* Sse's forwarder
  shape is reconciled with the new explicit clauses.
- **Outcome:** withstood, with a recorded constraint for Sse —
  flagged in claim 3's qualifier rather than as a falsification of
  claim 2 because the catch-all itself remains correct; what is
  required is a matching explicit clause for the Sse delivery shape.
- **Action:** record the Sse-shape reconciliation as an outstanding
  doubt feeding implementation.

### Claim 3: Removing `recv/2` from the `Tau.MCP.Transport` behaviour spec — and from each transport's implementation — is correct: no caller in the codebase depends on the pull API, and removing it prevents future transports from reintroducing the synchronous anti-pattern.

- **Claim (C):** The behaviour callback `@callback recv(state :: term(),
  timeout()) :: ...` (`lib/tau/mcp/transport.ex:21-22`) is removed; all
  three transport modules (`Http`, `Sse`, `Stdio`) drop their `recv/2`
  implementations. No production caller remains. The behaviour now
  documents the non-blocking contract for `send/2`.
- **Grounds (G):** `recv/2` is currently called from
  `lib/tau/mcp/server.ex:87` only (the catch-all about to be stripped).
  A repository grep for `transport.recv` returns one occurrence
  (that line). The `Tau.MCP.Transport.Sse.recv/2` body itself
  (`lib/tau/mcp/transport/sse.ex:73-86`) does a synchronous
  `receive ... after timeout` over the same mailbox the Server
  drains via the catch-all today — confirming the implementation is
  load-bearing only for the about-to-be-removed catch-all path.
  `Tau.MCP.Transport.Stdio.recv/2` (`lib/tau/mcp/transport/stdio.ex:65-78`)
  receives Port `{:data, ...}` messages from inside a callback — i.e.
  it would steal the Port's messages from the Server's mailbox,
  which works today only because the catch-all is the sole caller.
- **Warrant (W):** Hickey's *Simple Made Easy* principle: removing a
  redundant API surface ("complecting" the pull and push contracts)
  simplifies the contract space. OTP behaviour design: a callback
  that exists but has no remaining caller is dead surface, and dead
  surface is a regression risk (a future transport author re-derives
  blocking semantics from the existence of `recv/2`).
- **Qualifier (Q):** Holds for in-tree callers as of repo HEAD
  (commit `c939af8`). Does NOT account for downstream / extension
  callers if any external `Tau.MCP.Transport` implementor exists.
  Also: the Sse transport's *new* asynchronous delivery path (with
  `recv/2` removed) requires confirming that the SSE task's
  `Process.send(parent, {ref, {:line, ev.data}}, [])`
  (`lib/tau/mcp/transport/sse.ex:47`) reaches a matching
  `handle_info` clause in the Server. The current explicit
  `handle_info({:line, line}, state)` clause at `server.ex:84` does
  NOT match the `{ref, {:line, line}}` envelope. **A new explicit
  clause for the Sse envelope is required as part of the change;
  the solution.md does not name it.**
- **Rebuttal (R):** Would NOT hold if `recv/2` were public surface in
  use by an out-of-tree extension implementing `Tau.MCP.Transport`.
  No extensions ship in-repo today (`SPEC-EXTENSIONS.md` is forward-
  looking). Would also not hold if removing `recv/2` from a
  behaviour declaration in Elixir generates only a soft warning
  rather than a compile error on stale implementations — Elixir's
  behaviour conformance is warning-level, so a third-party impl
  retaining `recv/2` would compile cleanly.
- **Backing (B):** Hickey, *Simple Made Easy* (Strange Loop 2011);
  user CLAUDE.md "Opinions / biases" lists Hickey's principles as
  guiding. Elixir behaviour semantics:
  https://hexdocs.pm/elixir/typespecs.html#behaviours (callbacks not
  in `@behaviour`'s `__behaviour__` list raise warnings, not errors).

#### Falsification attempt for claim 3

- **Strategy:** dependency check (codebase-wide) + counter-example
  construction for Sse delivery shape.
- **Attempt:** (a) `grep -rn "transport.recv\|\\.recv(" lib/ test/`
  to find every call site — produced one match in
  `lib/tau/mcp/server.ex:87` (the catch-all). No production caller
  outside the catch-all exists. (b) Trace the Sse delivery path
  end-to-end: SSE task at `lib/tau/mcp/transport/sse.ex:47` sends
  `{ref, {:line, ev.data}}` to the Server pid; with the catch-all
  stripped and `recv/2` removed, the Server has only two `:line`
  matching clauses today: `handle_info({:line, line}, state)` at
  `server.ex:84` and the new `handle_info({ref, rpc_id, {:line, line}}, state)`
  from `solution.md:72`. Neither matches `{ref, {:line, line}}`
  (without `rpc_id`). **The Sse-delivered line would fall through to
  the (now unconditional) catch-all and be dropped**, breaking the
  Sse transport.
- **Outcome:** partially falsified. The claim that removing `recv/2`
  is universally safe survives for `Http` and `Stdio`, but for `Sse`
  the change implicitly requires either (i) altering the Sse task to
  forward as `{:line, line}` (no envelope, no ref isolation
  guarantee), or (ii) adding a third explicit `handle_info` clause
  in the Server that matches the `{ref, {:line, line}}` envelope and
  validates `ref == state.transport_state.ref`. Neither change is
  named in the solution.
- **Action:** narrow this claim's qualifier to record the Sse-
  reconciliation constraint; surface it as an outstanding doubt so
  the implementer treats it as a non-optional sub-task. This does
  NOT trigger solution revision because the solution's "Open
  questions" §4 ("Sse concurrent-invoke semantics") already flags
  the area for confirmation; the partial falsification refines that
  flag from "confirm whether rpc_id correlation handles out-of-order
  responses" to "additionally, ensure the explicit Server clause
  matches the Sse envelope shape, OR change the Sse forwarder shape
  to match the existing `{:line, _}` clause".

### Claim 4: Storing `{from, monitor_ref}` in the `pending` map and pruning on `:DOWN` correctly removes timed-out / crashed callers' entries — solving the stale-`from` accumulation defect named in problem.md.

- **Claim (C):** The `pending` map shape changes from `id => from` to
  `id => {from, monitor_ref}`. A `Process.monitor/1` on the spawned
  task pid (for Http) or on the caller pid (for Sse/Stdio) yields a
  ref stored alongside `from`. A new `handle_info({:DOWN, ref,
  :process, _pid, reason}, state)` clause locates the matching
  pending entry and removes it. Stale entries no longer accumulate.
- **Grounds (G):** Today, `lib/tau/mcp/server.ex:110` writes
  `Map.put(state.pending, id, from)` with no pruning path —
  `problem.md` lines 42–43 documents this leak. The solution
  (`solution.md` lines 70–76) introduces both the value-shape change
  and the `:DOWN` clause. The pattern (monitor + `:DOWN`-driven
  cleanup) is used elsewhere in the codebase:
  `lib/tau/coding_agent/tau_context.ex:171` monitors an owner pid;
  `lib/tau/tools/builtin/agent.ex:206` monitors a parent pid.
- **Warrant (W):** OTP non-negotiable #4: "Cross-process events MUST
  use `Phoenix.PubSub` or monitored refs (never `:global`)."
  `Process.monitor/1` is the canonical BEAM mechanism for liveness
  detection without bidirectional link semantics — it converts a
  process death into a routable message.
- **Qualifier (Q):** Holds when (i) the monitor is established before
  any path that could lose the ref (i.e., synchronously with the
  pending-map insert in `handle_call`), and (ii) the `:DOWN` clause's
  match logic scans the pending map by ref. The solution sketches
  this directly. Does not address the case where the monitored
  process never exits (e.g., a successful response from a long-lived
  caller) — in that case `Process.demonitor/2` should be called on
  successful reply to avoid an orphan monitor; this is named in
  proposal-1.md (`Process.demonitor(task_ref, [:flush])` at
  proposal-1.md:92) but is not echoed verbatim in solution.md.
- **Rebuttal (R):** Would NOT hold if the `:DOWN` message could
  arrive before the pending entry is inserted (race between
  `Process.monitor` and `Map.put`). Both calls happen in the same
  `handle_call` synchronously and inside the same scheduler slice;
  the `:DOWN` message cannot be processed until `handle_call`
  returns. Therefore the race is impossible by GenServer single-
  threaded message-loop guarantee.
- **Backing (B):** Erlang docs on `monitor/2`:
  "The calling process receives a 'DOWN' message ... when the
  monitored process terminates" (https://www.erlang.org/doc/man/erlang.html#monitor-2).
  Existing in-repo precedent at the cited line numbers.

#### Falsification attempt for claim 4

- **Strategy:** edge-case enumeration over pruning lifecycle.
- **Attempt:** Enumerate failure modes: (1) caller process exits
  before the response arrives — `:DOWN` from monitored caller pid
  fires; clause removes the pending entry. ✓ (2) Task crashes (Http)
  before sending the result — `:DOWN` from monitored task pid fires;
  pending entry removed; caller receives no reply and times out at
  `@timeout`. ✓ (3) Successful response arrives — the explicit
  task-delivery clause matches first, removes the pending entry, and
  replies. ✓ But: if `Process.demonitor` is not called on success,
  the still-live monitor will deliver `:DOWN` later when the Task
  finally exits (Task exits normally after sending its message).
  Without `demonitor`, the `:DOWN` clause receives a `:normal`
  reason for a Task whose entry has already been pruned —
  `Enum.find` returns `nil`; clause returns `{:noreply, state}`.
  Benign. (4) `Process.monitor(from_pid)` extraction: the solution
  says "monitor the caller pid for Sse/Stdio". `from` is a
  `{caller_pid, tag}` tuple; `elem(from, 0)` extracts the pid as
  done in proposal-3.md line 108. Works but is an undocumented
  detail of the GenServer `from` tuple.
- **Outcome:** withstood. The `demonitor` omission is a code-
  cleanliness point, not a correctness defect (orphan `:DOWN`
  messages route to `nil` match and are benignly dropped).
- **Action:** record the `demonitor` discipline as an implementation
  note in the outstanding doubts.

### Claim 5: The behaviour-level documentation of "MUST NOT block for the network round-trip" prevents future transport implementors from reintroducing the serialisation bug.

- **Claim (C):** Updating the `@callback send` docstring to state the
  non-blocking obligation, plus removing `recv/2`, is sufficient
  prevention — a future implementor would have to read the docstring
  and discover the blocking anti-pattern as a contract violation.
- **Grounds (G):** The current `Tau.MCP.Transport` module's
  `@moduledoc` (`lib/tau/mcp/transport.ex:1-17`) states "all
  transports use a GenServer-callback-style API" without specifying
  blocking semantics; the absence of an explicit non-blocking clause
  is plausibly *why* the Http transport blocks today
  (`lib/tau/mcp/transport/http.ex:28`). Proposal 2 (lines 12–24, 50–58)
  proposes the explicit non-blocking docstring; the solution adopts
  this verbatim.
- **Warrant (W):** Behaviours in Elixir document a contract, not a
  hard runtime constraint. The warrant is the *social* OTP principle:
  contracts that name the failure mode prevent it more reliably than
  contracts that omit it. Cited in proposal-2.md's strength
  list: "a transport that blocks in `send/2` is a ... design-time
  violation (documented in the callback doc)".
- **Qualifier (Q):** Holds only for implementors who *read* the
  docstring. Holds only for prevention, not mechanical enforcement
  (Elixir's behaviour check is type-shape, not runtime semantics).
  Existing implementors do not get retroactive enforcement — the
  three in-repo transports are updated explicitly in this PR.
- **Rebuttal (R):** Would NOT hold if a future implementor copies an
  existing transport (e.g., `Http`) verbatim and modifies it without
  re-reading the behaviour doc. Documentation alone is a weak
  forcing function compared to, e.g., a property test that asserts
  `send/2` returns within N ms across all impls. The solution does
  not propose such a property test.
- **Backing (B):** Hickey, *Simple Made Easy* on the value of
  declared contracts; OTP design principles on behaviour
  documentation as part of the API surface.

#### Falsification attempt for claim 5

- **Strategy:** prior-art counter-case.
- **Attempt:** Search for cases where a documented behaviour
  contract failed to prevent the contract's named anti-pattern in
  practice. The Tau codebase itself has a precedent: D-NNN
  invariants documented in SPEC files are nonetheless re-violated
  (e.g., `worktree-discipline.md` records that the "parent on main"
  invariant has been broken multiple times by agents who *had* read
  the rule). Documentation is necessary but not sufficient.
- **Outcome:** withstood (with caveat). The claim is "prevents
  future implementors from reintroducing the bug." Strict
  falsification requires a counter-example where a future Tau MCP
  transport implementor blocks despite the docstring; no such
  implementor exists yet to falsify. The prior-art counter-case
  suggests the claim is weaker than the solution implies but does
  not falsify it for the scope of the present PR.
- **Action:** note in outstanding doubts that a property test
  asserting non-blocking `send/2` across all `@behaviour
  Tau.MCP.Transport` implementations would be a more robust
  enforcement than docstring-only.

### Claim 6: The change is self-contained in `lib/tau/mcp/` and `test/tau/mcp/`; no supervisor or application changes are required.

- **Claim (C):** The diff touches `lib/tau/mcp/transport.ex`,
  `lib/tau/mcp/transport/http.ex`, `lib/tau/mcp/transport/sse.ex`,
  `lib/tau/mcp/transport/stdio.ex`, `lib/tau/mcp/server.ex`, and
  `test/tau/mcp/...`. No edits to `lib/tau/application.ex`,
  `lib/tau/mcp/reconciler.ex`, or supervision tree definitions.
- **Grounds (G):** Solution `What changes` enumerates exactly those
  paths (`solution.md` lines 53–82). `Tau.MCP.Reconciler` is
  declared out-of-scope (`solution.md:88`). No new processes are
  introduced — `Task.start/1` produces unsupervised processes by
  design (and the solution accepts this tradeoff in `Open questions`
  §2). The application supervisor (`lib/tau/application.ex`) is
  unaffected because the public start surface
  (`Tau.MCP.Server.start_link/1`) is unchanged.
- **Warrant (W):** Locality: a refactor confined to the modules
  implementing the affected behaviour, with no public-API change at
  the supervisor boundary, requires no supervisor changes. This
  follows from the OTP principle that supervisors care about child
  specs and lifecycle, not internal state shape.
- **Qualifier (Q):** Holds for the proposed Task-based path. Would
  NOT hold if the OTP non-negotiable on supervised processes (rule
  #1) is read strictly to forbid bare `Task.start` — see Rebuttal.
- **Rebuttal (R):** OTP non-negotiable #1 states: "Stateful subsystems
  MUST run as supervised processes." A bare `Task.start` is
  unsupervised. The solution's `Open questions` §2 raises this
  explicitly; if the project elects to require `Task.Supervisor`,
  then `Application.start/2` (or `Tau.MCP` supervision tree) gains
  a `Task.Supervisor` child, falsifying claim 6's "no supervisor
  changes" assertion.
- **Backing (B):** OTP non-negotiables (`.claude/rules/otp-non-negotiables.md`)
  rule #1; documented prior-art for ephemeral-task supervisors in
  `Tau.Session` (provider stream tasks).

#### Falsification attempt for claim 6

- **Strategy:** dependency check (against OTP non-negotiables).
- **Attempt:** Apply rule #1 strictly to the Task this change
  introduces. The Task is *stateful* in the trivial sense that it
  holds a reference to the Finch request in progress; it dies after
  one message. Two readings: (1) "stateful subsystem" means a
  long-lived process holding mutable state — Task does not qualify;
  rule does not apply; claim 6 stands. (2) "MUST run as supervised
  processes" applied uniformly — Task is a process; needs
  supervision; rule applies; claim 6 is falsified because a
  `Task.Supervisor` child must be added to `lib/tau/application.ex`
  or `lib/tau/mcp/` supervision. Reading (1) is the practical
  interpretation used throughout the codebase (see
  `lib/tau/tools/builtin/agent.ex` and similar files where bare
  spawn/Task.start patterns exist for ephemeral work). Reading (2)
  is the literalist interpretation. The solution names this as an
  open question rather than resolving it.
- **Outcome:** withstood under reading (1); partially falsified
  under reading (2). Because solution.md frames it as an open
  question explicitly ("Open questions" §2), it is not concealed —
  the validator records the tension here for the implementer.
- **Action:** note as an outstanding doubt; if the project resolves
  reading (2), this claim's qualifier narrows to "no
  supervisor-tree changes *if* `Task.start` is accepted as
  ephemeral; otherwise requires a `Task.Supervisor` child".

### Claim 7: The Server's `handle_message/2` and `route_response/2` logic is preserved unchanged — only the pending-map value shape changes (`id => from` → `id => {from, monitor_ref}`).

- **Claim (C):** `handle_message/2` (currently `lib/tau/mcp/server.ex:170-181`)
  and `route_response/2` (`server.ex:183-193`) are not modified in
  behaviour; their access pattern over `state.pending` is the only
  surface that changes (to handle the new tuple shape).
- **Grounds (G):** Solution `What does not change` (lines 86–88)
  states this directly. Today `route_response/2`'s pattern at
  `server.ex:191` is `from -> reply_to(from, msg, state)` — it
  treats the pending value as opaque. The shape change requires
  that `from` be destructured: `{from, _monitor_ref} -> reply_to(from, msg, state)`,
  which is a *match* change, not a *logic* change. The internal
  `:internal` tagged values (`{:internal, :init}` and `{:internal,
  :tools_list}`) at `server.ex:189-190` remain unchanged (they have
  no monitor counterpart — no caller to track).
- **Warrant (W):** Semantic locality: a value-shape change that
  preserves the access predicate (pop → reply) does not constitute
  a logic change. Hickey: "compose by data, not by control flow."
- **Qualifier (Q):** Holds provided the internal-init / internal-
  tools_list pending entries are NOT given monitor refs (they have
  no caller to monitor). Solution adopts this by implication —
  `handle_call({:invoke, ...})` is the only path that inserts a
  caller `from`; the internal `request_init/1` and
  `request_tools_list/1` (`server.ex:128-168`) continue to insert
  `{:internal, _}` unmodified.
- **Rebuttal (R):** Would NOT hold if the pending shape change
  forces a refactor of `reply_to/3` beyond the destructure. Both
  `reply_to/3` clauses (`server.ex:214-224`) call
  `GenServer.reply(from, ...)` and treat `from` opaquely. They are
  unchanged by destructure in the caller.
- **Backing (B):** Elixir pattern-match semantics; in-repo
  precedent: similar tuple-extension refactors in
  `lib/tau/coding_agent/tau_context.ex` (state map extensions
  without behaviour change).

#### Falsification attempt for claim 7

- **Strategy:** type-level check + counter-example construction.
- **Attempt:** Walk every `Map.put(state.pending, ...)` and
  `Map.pop(state.pending, ...)` in `server.ex`. Inserts:
  `server.ex:110` (caller from `handle_call`),
  `server.ex:145` (internal init), `server.ex:162` (internal
  tools_list). The change adds a monitor ref to insert site
  `:110` only — internal sites stay one-tuple. Pops: `server.ex:184`
  (`route_response`) — pattern must match BOTH shapes (caller
  `{from, ref}` and internal `{:internal, _}`). The current
  matching cascade at `server.ex:187-192` would need an updated
  branch to handle the new tuple shape. The logic is preserved if
  the branch order is: `{:internal, :init}` first, `{:internal,
  :tools_list}` next, `{from, _ref}` last. This is a mechanical
  refactor; no logic change. Counter-example for "logic preserved":
  the route_response semantics (which tagged value gets which
  handler) survive byte-for-byte.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

The seven claims are mutually consistent under the dominant reading
of OTP non-negotiables (rule #1 = "long-lived stateful subsystems",
not "every BEAM process") and under the assumption that Sse's
delivery shape is reconciled with the new explicit Server clause.
Two latent tensions to record:

1. **Claim 5 vs Claim 6** — Claim 5 promises that docstring-level
   contract enforcement prevents future serialisation; Claim 6
   promises no supervisor changes. Both rest on the same posture
   ("light-touch change, docstring contract"). If reading (2) of
   OTP rule #1 is adopted (forcing a `Task.Supervisor`), claim 6
   narrows but claim 5 strengthens (Task.Supervisor's existence
   makes "fire-and-forget" more visible to future readers). The
   tension resolves into a single choice: light-touch (current
   solution) vs principle-strict (with supervisor). The solution
   takes the light-touch path and flags it as an open question;
   this is internally consistent.

2. **Claim 3 (recv/2 removal) vs Claim 2 (catch-all stripping)** —
   Together these claims close the drain race. If only one is
   landed (e.g., catch-all stripped but `recv/2` retained as dead
   surface), the drain race is gone but the regression risk
   remains. The solution lands both together (per `What changes`
   bullets 1 and 5). Consistent — no tension in the bundled change.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `handle_call` returns immediately; concurrent invokes not mutually serialised | counter-example + dependency check | withstood | none |
| 2 | Catch-all returns `{:noreply, state}` unconditionally; no drain race | edge-case enumeration + integration check | withstood | record Sse-shape reconciliation as outstanding doubt |
| 3 | `recv/2` removal is safe; prevents regression | dependency check + counter-example | partially falsified | narrow Qualifier — Sse `{ref, {:line, _}}` envelope needs matching explicit `handle_info` clause OR the Sse forwarder shape must change |
| 4 | `:DOWN`-driven pending pruning fixes the leak | edge-case enumeration | withstood | record `Process.demonitor(ref, [:flush])` on success as cleanliness note |
| 5 | Behaviour docstring prevents future serialisation regression | prior-art counter-case | withstood (weak) | recommend a property test asserting non-blocking `send/2` as stronger enforcement |
| 6 | Change is self-contained; no supervisor changes | dependency check vs OTP rule #1 | withstood (under reading 1); partially falsified under reading 2 | record open question; defer to implementer per solution's own Open questions §2 |
| 7 | `handle_message/2` and `route_response/2` logic preserved | type-level check + counter-example | withstood | none |

## Revision required

None at solution-revision level. Claim 3's partial falsification
narrows the qualifier in place; the constraint (reconcile the Sse
delivery envelope with the Server's matching clauses) is recorded
as an outstanding doubt and added to the qualifier of claim 3.
Claim 6's partial falsification under the literal reading of OTP
rule #1 is already named as an open question in the solution; this
validator notes the tension but does not force its resolution
ahead of implementation.

Per `validate.md` §5: "If only **partial** falsifications: narrow
each claim's Qualifier in place. No revision needed." That applies
here.

- **Target file:** N/A
- **Revision kind:** N/A — qualifiers narrowed in place
- **Rationale:** Both partial falsifications are already surfaced in
  the solution's own `Open questions` section (§3 and §2
  respectively); the validator's narrowed qualifiers extend rather
  than contradict them. Re-running propose/select for this node
  would not surface a materially different solution — the four
  proposals already on file occupy the design space.

## Outstanding doubts

- **Sse delivery envelope (high priority).** Today's SSE task
  forwards `{ref, {:line, ev.data}}` (`lib/tau/mcp/transport/sse.ex:47`).
  The solution's new task-delivery clause matches
  `{ref, rpc_id, {:line, line}}` (three-element). The pre-existing
  explicit `handle_info({:line, line}, state)` matches the bare
  shape. Neither matches the Sse envelope. The implementer MUST
  either (a) add a third `handle_info({ref, {:line, line}}, state)`
  clause that validates `ref == state.transport_state.ref`, or
  (b) change the Sse forwarder to send the bare `{:line, line}`
  shape. Option (a) preserves ref-isolation; option (b) is simpler
  but loses the ref-as-namespace guarantee.
- **`Process.demonitor` on success.** Proposal 1's sketch
  (`proposals/proposal-1.md:92,97`) calls `Process.demonitor(ref, [:flush])`
  on successful task-delivery routing. The solution.md does not
  echo this verbatim. Without it, orphan `:DOWN` messages route to
  the catch-all (or to the `:DOWN` clause and fail to find a
  pending entry); benign but noisy.
- **OTP rule #1 strictness on `Task.start`.** Solution Open
  Questions §2 raises this; the validator confirms it is the only
  policy choice that could turn claim 6 from "withstood" to
  "falsified". Recommend resolving before PR open: either accept
  `Task.start` and document the exemption in the PR body, or adopt
  `Task.Supervisor` (one-line `application.ex` addition; one-line
  call-site change).
- **Property test for non-blocking `send/2`.** Claim 5's enforcement
  is docstring-only. A property test asserting that every
  `@behaviour Tau.MCP.Transport` implementation's `send/2`
  returns within ~5 ms (mock target server, no real network) would
  catch regressions mechanically. Not in the current solution
  scope; recommend filing as a follow-up if not added here.
- **`Finch.async_request/3` vs `Task.start` (low priority).** The
  solution chose `Task.start` over Finch's native async (which
  Proposal 2 used). The Open Questions §3 names this. Validator
  has no preference; both satisfy the AC. Recorded for parent-
  level synthesis only.

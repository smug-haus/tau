---
template_version: 1
template_name: problem
node_kind: root
depth: 0
parent: "—"
status: decomposed
---

# Problem: tau-cli error isolation, run-loop coupling, and data fidelity

## Statement

`lib/tau/cli.ex` and its `lib/tau/cli/` siblings contain four distinct
defects that cause silent failures, OTP non-negotiable violations, and
incorrect user-visible output: (1) supervised callees wrapped in
`rescue`/`catch :exit` that swallow process crashes; (2) a hand-rolled
`receive` loop in `drain_run_loop/2` that bypasses the project's PubSub
abstraction and silently discards unrecognised events; (3) the `tau init`
wizard persisting only the first selected provider and using a mismatched
credential key for Bedrock; (4) reflective module construction from
untrusted user input that leaks atoms and silently produces wrong modules.
Each defect is independently fixable, but together they make the CLI
surface untrustworthy without extensive manual testing.

## Context

- `lib/tau/cli.ex:344–362` — `run_cmd/1` uses `try/after` (legitimate) but
  also contains the hand-rolled `drain_run_loop/2` event loop.
- `lib/tau/cli.ex:427–486` — `drain_run_loop/2`: raw `receive` with wildcard
  catch-all silently discards every unrecognised `Events.*` struct.
- `lib/tau/cli.ex:489–497` — `drain_session_end/2`: `receive after 10_000`
  reports success on timeout rather than error.
- `lib/tau/cli/extensions.ex:67–81` and `lib/tau/cli/mcp.ex:98–112` —
  `safe_list/0` / `safe_reload/0` catch every exception AND `:exit` from
  supervised callees.
- `lib/tau/cli/init.ex:60–65` — `@providers` maps Bedrock to `AWS_ACCESS_KEY_ID`.
- `lib/tau/commands/builtin/logout.ex:38–43` — `@credential_map` maps
  `"bedrock"` to `AWS_SECRET_ACCESS_KEY` — different key than Init stores.
- `lib/tau/cli/init.ex:152–153` — `List.first(providers)` discards all
  selected providers except one after the user chose several.
- `lib/tau/cli.ex:782–788` / `lib/tau/cli.ex:812–814` — `resolve_coding_agent/1`
  and `resolve_provider/1` tail clauses use `Module.concat` on arbitrary CLI strings.
- OTP non-negotiables in scope: #4 (cross-process events via PubSub, not raw
  `receive`), #7 (let it crash; MUST NOT `try/rescue` across process
  boundaries; MUST NOT catch `:exit`).

## Complecting hypothesis

- Error-reporting is complected with process supervision: `safe_list/0` and
  `safe_reload/0` treat a supervised-process crash as a data absence, making
  process health invisible to the operator.
- Session-event consumption is complected with progress rendering: `drain_run_loop/2`
  both drives the PubSub mailbox drain and inline-formats stderr progress,
  forcing a single raw-`receive` loop that cannot delegate to a proper stream.
- User input parsing is complected with atom/module resolution: `resolve_provider/1`
  and `resolve_coding_agent/1` conflate "known short name" with "arbitrary module
  derivation from user bytes", creating an atom leak in the same clause.

## Decomposition strategy

The four defects decompose cleanly along the **concern (Hickey)** axis — each
cluster of defects involves a different observable concern and can be understood
and fixed without knowing the others:

1. **Error-swallowing rescues** — `rescue`/`catch :exit` shims in Extensions
   and MCP CLI handlers that hide supervision failures.
2. **Run-loop raw-receive** — `drain_run_loop/2` and `drain_session_end/2`
   hand-rolling a PubSub mailbox drain in violation of OTP NN #4/#7.
3. **Wizard data fidelity** — `tau init` discarding all but first provider and
   using the wrong AWS credential key for Bedrock.
4. **Reflective module dispatch** — `resolve_provider/1` and
   `resolve_coding_agent/1` building modules from untrusted user strings,
   leaking atoms and producing wrong modules.

These four sub-problems are mutually exclusive in the code they own and
collectively exhaust the concerns named in the audit lens. Each can be
proposed and reviewed independently.

## Sub-problems (filled by decomposer)

1. **error-swallowing-rescues** — `Tau.CLI.Extensions` and `Tau.CLI.MCP` wrap
   supervised callees in `rescue`/`catch :exit`, silently converting process
   crashes into empty results.
2. **run-loop-raw-receive** — `drain_run_loop/2` and `drain_session_end/2` use
   hand-rolled `receive` loops to consume PubSub events, violating OTP NN #4
   and silently discarding unknown events.
3. **wizard-data-fidelity** — `tau init` persists only the first selected
   provider (`List.first/1`) and stores the wrong AWS credential key for Bedrock
   (`AWS_ACCESS_KEY_ID` vs logout's `AWS_SECRET_ACCESS_KEY`).
4. **reflective-module-dispatch** — `resolve_provider/1` and
   `resolve_coding_agent/1` derive module atoms from arbitrary user strings via
   `Module.concat`/`String.capitalize`, leaking atoms and producing silently
   wrong module names.

## Acceptance criterion

The CLI layer is considered correct when: (a) a crashed supervised callee
surfaces as an explicit error exit code rather than an empty result; (b) the
headless run loop does not use raw `receive` and does not silently discard any
`Events.*` struct; (c) `tau init` persists all selected providers and uses a
consistent credential key for Bedrock across init and logout; (d)
`resolve_provider/1` and `resolve_coding_agent/1` do not create atoms from
unconstrained user input.

## Out of scope

- `doctor_cmd/0` provider-status duplication (per-provider `doctor_status/0` polymorphism)
- Mix task `resolve_target/0` / `bust_burrito_cache/0` copy-paste deduplication
- `run_cmd/1` size (splitting into `setup_session/3` etc.) beyond what the
  run-loop sub-problem addresses
- `commands/builtin/` defects (copy, export, tree, help injection) outside the
  files named above
- Comment-narration / issue-archaeology cleanup
- `main/1` dispatch table compression

## Amendment log

- (none yet)

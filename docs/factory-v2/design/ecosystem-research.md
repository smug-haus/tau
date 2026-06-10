# Claude Code Ecosystem Research — Factory v2

**Scope.** Inventory the Claude Code plugin / agent / skill / hook / MCP-server
ecosystem against the five enforcement classes the Tau factory must guarantee:
contract fidelity (a), test fidelity (b), error-handling discipline (c),
observability (d), PR gating that cannot silent-skip (e). Plus a sixth
"general orchestration" bucket.

**Method.** Anthropic docs (`code.claude.com/docs`), the official
`anthropics/claude-code` and `anthropics/claude-plugins-official` repos,
community catalogues (`ComposioHQ/awesome-claude-plugins`,
`hesreallyhim/awesome-claude-code`, `claude-plugins.dev`), GitHub search,
and adjacent agentic-CI projects (Continue.dev, Aider, Sweep, Meta ACH).
Star counts and license metadata fetched May 2026; treat as "approx" — the
ecosystem is moving weekly.

**Bottom line up front.** The marketplace is *broad but shallow* for Tau's
purposes. There are dozens of "review-my-PR" agents, but **zero** that
mechanically enforce the things the factory v2 SPEC actually cares about:
SPEC §4 ↔ code conformance, AC-to-test linkage with deletion-of-assertions
detection, mutation-score gating, telemetry-to-consumer cross-checks, or
unbypassable CI gates. The ecosystem assumes the human reviewer is the
final gate. Tau's premise inverts that, so most plugins are *useful as
inputs, useless as gates*. Adoption shortlist is small; in-house build list
is most of the work.

---

## a. Contract fidelity — Dialyzer, behaviour callbacks, SPEC §4 ↔ code

The factory needs: every behaviour callback is implemented and pattern-
matches the documented atoms; every public struct's shape matches its
hidden contract; Dialyzer is wall-clean; SPEC §4 boundary contracts are
not silently violated.

### Candidates

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **bradleygolden/claude-marketplace-elixir** | https://github.com/bradleygolden/claude-marketplace-elixir | small (~early adopter) | Y | MIT-ish (verify) | Ships `dialyzer`, `credo`, `precommit`, `ex_unit`, `sobelow`, `mix_audit` plugins. Hooks run on Write/Edit and gate via `permissionDecision: deny` (correct deterministic shape). Closest fit; adopt the hook scaffold even if rules are too coarse. |
| **georgeguimaraes/claude-code-elixir** | https://github.com/georgeguimaraes/claude-code-elixir | small | Y | check repo | `mix format`, `mix compile --warnings-as-errors`, `mix credo`, ElixirLS LSP. Useful as developer-side feedback, not as PR gate. |
| **oliver-kriska/claude-elixir-phoenix** | https://github.com/oliver-kriska/claude-elixir-phoenix | small | Y | check repo | 20 specialist agents + Tidewave MCP + "Iron Laws". Phoenix-flavoured; overlaps heavily with what Tau already has, less rigorous than bradleygolden's. |
| **elixir-lsp/elixir-ls** | https://github.com/elixir-lsp/elixir-ls | ~2k | Y | Apache-2.0 | LSP with built-in MCP server (port `3789 + hash(workspace)`). Gives an LLM agent live Dialyzer, types, refs. Strongest contract-fidelity input source available. Adopt. |
| **mkreyman/bmad-elixir / elixir-discipline** | https://claude-plugins.dev/skills/@mkreyman/bmad-elixir/elixir-discipline | small | Y | check | Skills `elixir-verification-gate`, `elixir-no-shortcuts`, `elixir-no-placeholders`. Explicit rule: do not edit `dialyzer.ignore` or `.credo.exs` excludes. Conceptually aligned with Tau but encoded as prompts, not enforcement. |
| **anthropics/claude-code → pr-review-toolkit / type-design-analyzer** | https://github.com/anthropics/claude-code/blob/main/plugins/pr-review-toolkit | bundled in 30k+ repo | Y (Anthropic) | check | Rates type design on 4 dimensions 1–10 (encapsulation, invariant expression, usefulness, enforcement). Probabilistic, not deterministic. Useful upstream of the gate, not as the gate. |

### Conspicuously absent

- **No behaviour-callback introspector.** Nothing in the ecosystem says
  "for module X declaring `@behaviour Tau.Provider`, prove all
  `@callback`s are implemented and pattern-match the declared atom set."
  This is a `:beam_lib`/`Code.fetch_docs/1` task; Tau must build it.
- **No SPEC §4 ↔ code differ.** No project parses
  `docs/spec/SPEC-*.md` §4, extracts the boundary contracts, and
  diff-checks them against runtime module signatures. Closest analog is
  Continue.dev's rule files, but those are prose-on-prose, not
  prose-on-code.
- **Dialyzer is a per-developer chore, not a per-PR gate.** No plugin
  publishes a delta-Dialyzer ("new PR-introduced warnings only") or
  treats Dialyzer regression as a CI failure with a structured PR
  comment. Tau's CI already runs Dialyzer; the gap is comment-back
  surface.

---

## b. Test fidelity — property tests, mutation, AC-to-test linkage

The factory needs: every `AC-N`/`D-NNN` token in the PR body has a matching
gating test; deleted/weakened assertions are flagged; mutation testing
proves the gating tests actually constrain production code.

### Candidates

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **anthropics/claude-code → pr-review-toolkit / pr-test-analyzer** | https://github.com/anthropics/claude-code/blob/main/plugins/pr-review-toolkit | bundled | Y | check | Rates test gaps 1–10. Looks for behavioural vs line coverage, edge cases. Probabilistic input. **No** mutation, no AC linkage. |
| **obra/superpowers** | https://github.com/obra/superpowers | ~94k–170k+ (rapidly growing) | Y | MIT | TDD-enforcing skills framework. Strong cultural fit ("delete code written before tests exist"). Encoded as skills; the enforcement is the LLM following the skill, not CI. Useful prompt material; not a gate. |
| **devonestes/muzak (Elixir)** | https://github.com/devonestes/muzak | ~120 | Y (Pro version more active) | MIT | Elixir-native mutation testing. `:min_coverage` exits non-zero in CI. **The** primary candidate for Tau's Gate 5.3 replacement / augmentation. Adopt. |
| **Meta ACH (paper)** | https://engineering.fb.com/2025/09/30/security/llms-are-the-key-to-mutation-testing-and-better-compliance/ | n/a (paper) | n/a | n/a | Mutation-guided LLM test generation. Targeted, fault-class-specific mutants; equivalence-detection LLM agent (precision 0.95 / recall 0.96 with preprocessing). Strong design reference; not adoptable software. |
| **Advertest (arXiv 2602.08146)** | arxiv | n/a | n/a | research | Dual-agent adversarial T vs M loop. Conceptual fit for what Tau's test-author + critic could become; not packaged. |
| **codexstar69/bug-hunter** | https://github.com/codexstar69/bug-hunter | small | Y | check | Three-agent Hunter / Skeptic / Referee pipeline. Closest *packaged* analog to adversarial test generation, but the "find" side, not the "gate" side. |
| **silent-failure-hunter** (pr-review-toolkit) | https://github.com/anthropics/claude-code/blob/main/plugins/pr-review-toolkit | bundled | Y | check | Useful for class (c); not (b). |
| **StreamData / PropCheck** | hex.pm | mature | Y | various | Tau already uses StreamData. No Claude-aware tooling around it. |

### Conspicuously absent

- **No AC-to-test linkage scanner exists in the ecosystem.** The token
  pattern `AC-N`/`D-NNN` (and "AC-1 should be tested") is a Tau
  invention. The closest concept is BDD's "scenario tags", and even
  there nothing scans the PR body. Tau's `mix tau.gate.ac_linkage` has
  no off-the-shelf replacement.
- **No deletion-of-assertions detector exists.** Gate 5.2 (masking
  detection) — `-  assert` / `-  refute` lines flagged to the critic —
  is unique. The pattern is well-understood (Meta's ACH equivalence-
  detection agent is the academic cousin) but not packaged.
- **No mutation runner ties to PR diff in CI for Elixir.** Muzak runs;
  Muzak-against-PR-diff with a "minimum kill rate" gate that fails CI
  is not packaged. Tau already builds this in
  `mix tau.gate.mutation` — keep building.

---

## c. Error-handling discipline — no defensive `try/rescue`, OTP let-it-crash

The factory needs: implementers do not insert `try/rescue` against
unreachable conditions; OTP non-negotiable §7 ("let it crash; supervise;
restart") is enforced on every PR.

### Candidates

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **anthropics/claude-code → silent-failure-hunter** | https://github.com/anthropics/claude-code/blob/main/plugins/pr-review-toolkit | bundled | Y | check | Severity-tiered: CRITICAL (silent failure, broad catch), HIGH, MEDIUM. Explicitly hunts catch-block swallowing. Language-general. **Best off-the-shelf for class (c).** Adopt as prompt source for the critic persona; the agent's outputs are advisory, not blocking. |
| **mkreyman/elixir-no-shortcuts / no-placeholders** | claude-plugins.dev | small | Y | check | "Fail loud, fail fast, no silent failures" rule encoded as a skill. Elixir-native phrasing. Adopt the prose. |
| **anthropics/claude-code → security-guidance** | bundled | bundled | Y | check | PreToolUse hook. Adjacent (warns on insecure patterns), not directly (c). |
| **hookify** | https://github.com/anthropics/claude-code/blob/main/plugins/hookify | bundled | Y | check | Generates `block`-action hooks from conversation analysis. The mechanism is right (exit code 2 = deterministic block). Adopt the *mechanism*; the *rule content* is Tau-specific. |

### Conspicuously absent

- **No AST-level `try/rescue` linter exists for Claude Code.** Credo
  has some checks (e.g. `Credo.Check.Warning.RaiseInsideRescue`); none
  cover "rescue against an unreachable exception class" or "rescue then
  re-raise with no context added". Tau needs either a Credo custom
  check or a `mix tau.gate.error_handling` task.
- **No "process-boundary catch" linter.** OTP non-negotiable §7
  forbids `try/rescue` across process boundaries (e.g. a `GenServer`
  callback rescuing then logging). Detection requires call-graph
  analysis (`mix xref`/`:beam_lib`); no plugin exists.
- **Karan Bansal's Medium post** documents the silent-hook failure
  mode (Python validator `sys.exit(1)` does not block — only exit code
  2 does). The mechanism is documented; Tau already enforces it in
  rules; no plugin exists that audits hooks for this hole.

---

## d. Observability — every emitted telemetry event has a production consumer

The factory needs: for every `:telemetry.execute([:tau, ...], ...)` call
site, prove there is at least one `:telemetry.attach/4` consumer wired
into the supervision tree. Detect "fire-and-forget" telemetry that nobody
listens to.

### Candidates

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **traceloop/opentelemetry-mcp-server** | https://github.com/traceloop/opentelemetry-mcp-server | ~188 | Y (release 0.2.2, Feb 2026) | Apache-2.0 | MCP server exposing `search_traces`, `get_trace`, `find_errors` against Jaeger / Tempo / Traceloop. An LLM agent could use this to query the trace backend and *prove* a Tau-emitted event reached a consumer. Adopt for runtime verification; does not solve compile-time gap. |
| **OpenLLMetry Hub** | https://www.traceloop.com (search "OpenLLMetry Hub") | n/a | Y | Apache-2.0 (verify) | LLM gateway that centralises GenAI OTel spans + bridges via MCP server. Useful for Tau's own LLM-call telemetry; not for arbitrary `[:tau, ...]` events. |
| **OTel GenAI semantic conventions** | https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/ | spec | Y | n/a | Recently formalised conventions for MCP tool calls (`tool.name`, `tool.server`, `gen_ai.usage.*`). Tau's `OtelReporter` SPEC should track this. Adopt as design reference. |
| **ExMCP** | https://github.com/azmaveth/ex_mcp | ~14 | Y (v0.9.1, Apr 2026) | MIT | Elixir MCP library; **88 telemetry events**. If Tau exposes itself *as* an MCP server, this is the canonical substrate. Not relevant for the consumer-coverage check. |
| **Hermes MCP** | https://github.com/cloudwalk/hermes-mcp | ~371 | Y | MIT | Elixir MCP SDK with Supervisor integration. Same comment as ExMCP. |
| **anthropics/claude-code → background monitors** | docs.claude.com/en/plugins | bundled | Y | check | `monitors/monitors.json` — `tail -F`-style streams that deliver lines to Claude as notifications. Could tail a Tau OTel collector's "no-consumer" log. Mechanism only; Tau owns the log. |

### Conspicuously absent

- **No `telemetry-event-consumer-coverage` tool exists** in any
  ecosystem (Elixir or otherwise). The canonical pattern is
  `grep telemetry.execute lib/ | …`, hand-correlated. Tau must build
  a `mix tau.gate.telemetry_coverage` that walks the AST for execute
  call-sites, walks the supervision tree for attached handlers, and
  asserts every event-prefix has at least one consumer.
- **OpenTelemetry's "is this span ever consumed" check is also
  absent** — even the OTel SDK does not surface "no exporter is
  listening for this resource". The OTel-MCP server is read-only:
  it tells you what *did* arrive, not what *was emitted but lost*.
- **`anthropics/claude-code → manifest` plugin** advertises "real-time
  cost observability" but applies to LLM-call telemetry, not Tau's
  domain events.

---

## e. PR gating that cannot silent-skip

The factory needs: critic + reviewer MUST PASS; gates 5.1 / 5.2 / 5.3
MUST PASS; no path exists by which the coordinator (or a future
hook) can merge a PR with a missing or red verdict.

### Candidates

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **github/github-mcp-server** | https://github.com/github/github-mcp-server | ~30.1k | Y (active, 870+ commits) | MIT | Official. `pull_request_read.get_check_runs`, `actions_get`, `get_job_logs`, `merge_pull_request`. **No branch-protection tools** (verified). The agent can *query* CI; the gate must be the GitHub-side branch protection rules, configured out-of-band. Adopt for the query side. |
| **denysvitali/gh-actions-mcp** | https://github.com/denysvitali/gh-actions-mcp | small | Y | check | Focused subset: `get_actions_status`, `get_workflow_runs`, `trigger_workflow`. Lighter than the official. |
| **ko1ynnky/github-actions-mcp-server** | https://github.com/ko1ynnky/github-actions-mcp-server | small | Y | check | Similar; broader compatibility (Codeium, Windsurf). |
| **Continue.dev "Continuous AI"** | https://continue.dev | many | Y | Apache-2.0 | Async agents that run on every PR via GitHub Actions, enforce team rules, post structured findings. "Continue Hub adds enforceable CI checks for AI-generated code." Closest commercial-grade analog to factory v2. Worth deep technical read; not directly adoptable (different language, different opinions). |
| **Sweep AI** | https://sweep.dev | many | Y | Apache-2.0 | Issue → PR. Wrong direction for Tau's needs (Tau already opens its own draft PR). |
| **Anthropic-managed Code Review (claude.com/blog "Preview, review, merge")** | docs.claude.com/en/code-review | hosted | Y | proprietary | **Deliberately non-blocking by default** — the check run always finishes "neutral" so it does not gate branch protection. Quote: "If you want to gate merges on Code Review findings, you need to read the severity breakdown … in your own CI." This is the single most important fact for Tau: the official Anthropic surface explicitly punts gating to the customer. |
| **AgentLint** | https://github.com/0xmariowu/AgentLint | small | Y | check | 33 evidence-backed checks for AI-agent-compatibility of a repo. Adjacent (repo lint), not (e). |
| **`anthropics/claude-code → hookify`** | bundled | bundled | Y | check | `action: block` on a PreToolUse hook with exit code 2 = deterministic block at the *tool* level. Right mechanism. Wrong scope (intra-session, not pre-merge). |

### Conspicuously absent

- **An unbypassable cross-PR gate composed of (critic + reviewer +
  gates 5.1/5.2/5.3) is not packaged anywhere.** The official Code
  Review is by design *advisory*. The gates Tau cares about (AC
  linkage, mutation, deletion-of-assertions) do not exist outside
  Tau. The merge-block has to happen at the GitHub side, via:
  - GitHub branch protection rules requiring **named** check-run
    names — and those check runs must be Tau's own CI jobs
    (`mix tau.gate.*`), not the LLM agents.
  - PR merge-eligibility is determined by GitHub Actions exit codes;
    Tau's existing CI is therefore the unbypassable layer. The
    LLM-side critic/reviewer is a *quality* gate, not a
    *correctness* gate.
- **No "I cannot silent-skip" enforcement exists at the agent layer.**
  Claude Code agents can self-certify and proceed. The factory-loop
  rule (`MUST NOT … override / self-certify a FAIL verdict`) is the
  policy; the mechanism that makes it impossible is GitHub branch
  protection on the named check runs. There is no plugin that turns
  the policy into a mechanism.

---

## General orchestration — solution tree, subagent dispatch, memory

| Name | URL | Stars | Maintained | License | Fit |
|---|---|---|---|---|---|
| **josstei/maestro-orchestrate** | https://github.com/josstei/maestro-orchestrate | small | Y | check | 22 specialised subagents through a 4-phase workflow with native parallel execution. Conceptual overlap with Tau coordinator; less rigorous about gates. Reference design. |
| **backloghq/backlog** | https://github.com/backloghq/backlog | small | Y | check | Persistent cross-session task management. 24 MCP tools. Event-sourced storage. Tau's `solution-tree.json` is the in-house equivalent; backlog is a packaged alternative if Tau wants to externalise memory. Probably not worth adopting — divergence cost > value. |
| **agntk** | https://github.com/Phoenixrr2113/agntk | small | Y | check | Persistent named agents + 20 built-in tools. Closer to coordinator-as-CLI; not a fit for OTP-supervised Tau. |
| **context-mode** | https://github.com/mksglu/claude-context-mode | small | Y | check | Sandboxed-subprocess processing, claims 98% context savings. Worth a closer look for Tau's compact discipline. |
| **anthropics/claude-code → feature-dev** | bundled | bundled | Y | check | Structured 7-phase feature development with `code-explorer`, `code-architect`, `code-reviewer` subagents. Lighter than Tau but the same skeleton; cross-check the agent definitions for ideas. |
| **anthropics/claude-code → agent-sdk-dev** | bundled | bundled | Y | check | Adopt if Tau ever exposes a Claude-compatible MCP surface. |
| **obra/superpowers** | https://github.com/obra/superpowers | 94k–170k+ | Y | MIT | The 7-phase workflow (Brainstorm → Spec → Plan → TDD → Subagent → Review → Finalize) is close to Tau's lifecycle. Strongest *prompt-engineering* reference. The Iron Law ("delete code written before tests") aligns with Gate 5.3's spirit. |

### Conspicuously absent

- **No `solution-tree.json`-shaped tool exists.** Every project rolls
  its own. The backloghq/backlog event-sourced model is the closest;
  none of the alternatives bound the tree to a PR lifecycle.
- **No "kill-signal + heuristic-classification" packaged anywhere.**
  Tau's `kill-signal.json` + `heuristic-analysis` skill pattern is
  unique. The closest reference is FindSkill.ai's "10 Parallel Agents:
  Week 1 Failure Modes" essay; descriptive, not enforcement.

---

## Recommended adoption shortlist

Ordered by leverage; "adopt" means "consume directly", "mine" means
"read the source/prompt and lift the parts that apply".

1. **github/github-mcp-server (adopt)** — the canonical CI-status
   query surface. Wire it into the coordinator's gating-test-status
   checks so the agent can verify CI without shelling out to `gh`.
   License MIT. Active.

2. **anthropics/claude-code `pr-review-toolkit` agents (mine, then
   inline)** — `silent-failure-hunter` and `type-design-analyzer`
   are the highest-leverage prompts in the ecosystem. The persona-
   dispatch rule (`CLAUDE.md`) already forbids `subagent_type:`;
   inline these as additional checklist items in the existing
   `critic.md` / `reviewer.md` personas. Do not adopt as separate
   subagents.

3. **bradleygolden/claude-marketplace-elixir (mine the hook
   scaffold)** — the `permissionDecision: "deny"` JSON shape is
   correct; mine the dialyzer/credo/sobelow hook wiring patterns even
   if the rule content is too coarse for Tau's discipline.

4. **devonestes/muzak (adopt, augment)** — Tau already has
   `mix tau.gate.mutation`. Compare against muzak's `:min_coverage`
   semantics; either delegate or document the divergence in an ADR.
   Muzak Pro is more featureful but proprietary; the OSS version is
   sufficient for path-set-scoped mutation.

5. **elixir-lsp/elixir-ls MCP server (adopt)** — runtime Dialyzer /
   type / refs queries from inside the coordinator. The most useful
   contract-fidelity *input* in the ecosystem; complements rather
   than replaces Tau's planned behaviour-callback introspector.

6. **traceloop/opentelemetry-mcp-server (adopt for runtime)** — once
   Tau's `OtelReporter` is exporting OTLP (per SPEC-OTEL-REPORTER),
   wire this MCP server in so the reviewer agent can verify a Tau
   event actually reached the configured collector. Apache-2.0.

7. **obra/superpowers (mine the skills)** — its TDD-Iron-Law,
   brainstorming, and writing-plans skills overlap with Tau's
   `design-reasoning`, `tau-adr`, and the test-first rule in
   factory-loop. Lift the wording where it tightens Tau's
   discipline; do not import the framework wholesale (overlap is
   high, divergence cost is high).

8. **anthropics/claude-code `hookify` mechanism (mine, not adopt)**
   — the `event: bash|file|stop|prompt`, `action: block` pattern with
   exit-code-2 deterministic blocking is the right primitive for any
   future intra-session enforcement Tau adds. The Karan-Bansal silent-
   failure post is the cautionary tale.

9. **GitHub branch protection rules (configure, not a plugin)** —
   the actually-unbypassable gate. Configure required-status-checks
   to name `mix tau.gate.ac_linkage`, `mix tau.gate.masking`,
   `mix tau.gate.mutation`, the critic gate, and the reviewer gate.
   Without this, the loop's `MUST NOT silent-skip` rule is policy
   only.

10. **Continue.dev "Continuous AI" architecture (read, do not adopt)**
    — closest commercial-grade analog. Worth a deep technical read
    of their rule-files-as-code model and their PR-comment posting
    pipeline. Tau's design diverges (OTP-native, Elixir-bound) but
    can lift the rule-set ergonomics.

Anti-recommendations (looked at, deliberately reject):

- **Anthropic Code Review (managed)** — non-blocking by design;
  redundant with critic + reviewer; would muddy the gate.
- **maestro-orchestrate / agntk / backlog** — divergent
  orchestration substrates; integration cost exceeds value.
- **alirezarezvani/claude-skills, GetBindu/awesome-claude-code-and-
  skills, sickn33/antigravity-awesome-skills** — large unfiltered
  skill collections (300+, 1,200+). Useful as search corpora; not
  curated enough to adopt anything directly without per-skill audit.

---

## Gaps requiring in-house build

For each failure class, the gates that *must* be Tau-built because no
package exists:

### (a) Contract fidelity
- `mix tau.gate.behaviour_coverage` — for every `@behaviour Foo`
  declaration, prove every `@callback` is implemented and pattern-
  matches the documented atom set. Walks `:beam_lib` + `Code.fetch_docs`.
- `mix tau.gate.spec_section_4` — parse `docs/spec/SPEC-*.md` §4
  boundary contracts; cross-check against runtime module signatures.
  Tests for "PR removed a contract clause but did not remove the §4
  entry" and vice versa.
- `mix tau.gate.dialyzer_delta` — fail PR if Dialyzer warning count
  increases against the base SHA. Post structured comment.

### (b) Test fidelity
- `mix tau.gate.ac_linkage` — **exists** (PR-B / issue #370).
  Maintain.
- `mix tau.gate.masking` — **exists**. Maintain.
- `mix tau.gate.mutation` — **exists**, path-based. Consider
  delegating to muzak under the hood or documenting the divergence
  in an ADR.
- `mix tau.gate.property_coverage` — for invariant-bearing modules
  enumerated in `otp-non-negotiables.md` §6, prove a `StreamData`
  property exists. Lightweight check (grep + AST presence).

### (c) Error-handling discipline
- `mix tau.gate.error_handling` — AST scan for: `try/rescue` against
  unreachable exception classes; `try/rescue` across process
  boundaries (any `GenServer` / `Task` / `:gen_statem` callback
  containing `try`); broad `rescue _ -> :ok` swallowing. Drives off
  `Macro.prewalk/2`. Either a Credo custom check or a standalone
  Mix task.
- `mix tau.gate.hook_safety` — audit `.claude/settings.json` and
  every hook script: every Python validator body is wrapped in
  `try/except` → `sys.exit(2)`; exit codes 0/2 are the only
  PreToolUse outcomes. The Karan-Bansal hole.

### (d) Observability
- `mix tau.gate.telemetry_coverage` — walk AST for
  `:telemetry.execute(prefix, ...)` call sites; walk
  `Application.start/2` and the supervision tree for attached
  handlers; assert every prefix has at least one consumer reachable
  from a supervisor child. Fails on "fire-and-forget" events.
- `mix tau.gate.start_stop_pairing` — every `*.start` event has a
  matching `*.stop` and `*.exception` handler. Required by OTP
  non-negotiable §5.

### (e) PR gating
- **GitHub branch-protection wiring** — not Tau code, but Tau
  configuration. Required-status-checks list MUST contain every
  `mix tau.gate.*` job name and the critic/reviewer verdicts. Without
  this the factory-loop rule is unenforceable.
- **Critic / reviewer verdict CI shim** — a `mix tau.gate.verdicts`
  task that reads the draft-PR body's `Gate verdicts` section, fails
  if either is missing or `FAIL`, and posts a status check named
  `tau/gate/verdicts`. Promotes the prose rule to a mechanical gate.
- **Gating-test path-set freeze enforcer** — a `mix tau.gate.frozen_
  paths` task that fails if the PR body's `Gating-test paths`
  section changed since the first non-empty value. Prevents
  scope-creep via path-set mutation.

---

## Ecosystem maturity — honest assessment

It is wide but shallow. The plugin marketplace has 55+ official + 70+
community + ~330 catalogued individual skills, but the modal plugin is
*an LLM agent that comments on your PR*. The factory v2 design
explicitly does not trust that pattern as the gate. Of the ~50
relevant repos surveyed:

- **3 plugins** ship anything resembling a deterministic gate
  (bradleygolden's hook scaffold, hookify's block mechanism,
  github-mcp-server's check-run query). None of them gate on the
  things Tau needs.
- **The most-starred frameworks** (Superpowers at 94k–170k stars,
  Everything Claude Code at 100k+) are *cultural* — they encode
  engineering discipline as prompts. Useful, not enforcing.
- **The most-relevant research** (Meta ACH, Advertest) is published
  as papers, not packages.
- **Elixir-native tooling is thin.** Three small plugin marketplaces
  (bradleygolden, georgeguimaraes, oliver-kriska), ElixirLS's MCP
  server, two MCP libraries (ExMCP, Hermes), Muzak. None of them
  cover the SPEC-fidelity / AC-linkage / telemetry-consumer-coverage
  ground.
- **Anthropic itself has declared the gating problem out-of-scope**
  for the managed Code Review service ("never blocks merging through
  branch protection rules" — verbatim from `docs.claude.com/en/code-
  review`). This is the strongest evidence that the gating substrate
  is Tau-shaped work.

The implication for factory v2: spend ecosystem-adoption effort on
inputs (LSP, CI-status MCP, OTel MCP, mutation library) and prompts
(pr-review-toolkit personas, Superpowers skills). Spend in-house
build effort on the gates — the gates are where the ecosystem has
nothing.

---

## Sources

- Claude Code docs (`code.claude.com/docs/en/plugins`, `…/code-review`,
  `…/discover-plugins`).
- `anthropics/claude-code` — plugins directory.
- `anthropics/claude-plugins-official`, `anthropics/claude-plugins-
  community`.
- `ComposioHQ/awesome-claude-plugins`, `hesreallyhim/awesome-claude-
  code`, `claude-plugins.dev`, `claudemarketplaces.com`.
- `modelcontextprotocol/servers` registry.
- `github/github-mcp-server`, `traceloop/opentelemetry-mcp-server`,
  `azmaveth/ex_mcp`, `cloudwalk/hermes-mcp`, `elixir-lsp/elixir-ls`.
- `bradleygolden/claude-marketplace-elixir`, `georgeguimaraes/claude-
  code-elixir`, `oliver-kriska/claude-elixir-phoenix`,
  `mkreyman/bmad-elixir`.
- `obra/superpowers` (94k–170k+ stars; MIT).
- `devonestes/muzak` (Hex), Muzak Pro.
- Meta ACH (FSE 2025, arXiv 2501.12862); Advertest (arXiv 2602.08146).
- Continue.dev, Aider, Sweep — comparative reviews (vibecoding.app,
  augmentcode.com, rywalker.com).
- Karan Bansal — "Claude Code's Most Underrated Feature: Hooks"
  (silent failure mode in PreToolUse).
- OpenTelemetry GenAI semantic conventions
  (`opentelemetry.io/docs/specs/semconv/gen-ai/mcp/`).

Fetched May 2026. Star counts move; treat as ordinals.

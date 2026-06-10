---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Adopt Claude Code memory + MCP knowledge servers; bind to CI via a thin Tau registry adapter

## Approach

Adopt three off-the-shelf substrates from the Claude Code ecosystem rather
than build a bespoke audit-finding store, and bind them to CI via the
smallest possible Tau-owned adapter:

1. **Authoring surface — Claude Code memory cascade + skill.** Audit
   findings live as Markdown files with YAML frontmatter under
   `.claude/memory/audits/<finding-id>.md` (the project-memory directory
   already loaded by Claude Code's `CLAUDE.md` `@import` cascade — Tau
   already exploits this for `TAU.md`/`MEMORY.md`). A new on-demand skill
   `polya-audit:audit-finding` provides the authoring template and
   frontmatter schema; the existing `polya-audit` plugin's
   `templates/problem.md` is the schema's parent.
2. **Persistence + query — `mcp-knowledge-graph` MCP server (or a
   pinned fork).** The Anthropic-published `@modelcontextprotocol/server-
   memory` reference (an entity/relation knowledge-graph server,
   JSONL-backed) and the community `shaneholloman/mcp-knowledge-graph`
   fork both implement structured-fact persistence with stable IDs,
   tagged relations (e.g. `applies_to_path`), and full-text search over
   observations. Findings are mirrored from the Markdown source-of-truth
   into the MCP graph on commit via a Git `post-commit` hook
   (`mix tau.audit.sync`), so authoring is "write a Markdown file" and
   nothing else.
3. **Per-PR gate binding — a thin `Tau.Factory.AuditRegistry` adapter.**
   A ≤200 LoC Elixir module reads the Markdown source-of-truth (the MCP
   server is for agent / dashboard query, not the CI critical path —
   keeping CI hermetic) and exposes one function:
   `applicable_findings(pr_diff_paths) :: [%Finding{}]`. The
   pre-merge-code-gates sibling consumes this list; each finding's
   `check_module` field names the runner (e.g.
   `Tau.Factory.Checks.NoRescue`). Waivers carry an ISO-8601 `expires`
   date; an expired waiver flips the finding back to `open` on the next
   gate run.

The adopt-first split: authoring substrate = adopted (Claude memory
cascade), persistence/query = adopted (MCP knowledge-graph server),
schema = adopted-and-extended (polya-audit `problem.md` frontmatter),
CI binding = bespoke but trivially small (one parser + one
applicability function).

## Rationale

The leaf's complecting hypothesis isolates three pairs: (a) "finding
exists" ↔ "enforcement exists"; (b) "remediation" ↔ "closure"; (c)
"which gate runs" ↔ "PR diff." Building a bespoke registry decomplects
(a) but introduces a new authoring surface that competes with the
existing `docs/problems/` Markdown habit and the `polya-audit` plugin
already in the repo. Adopting the Claude memory cascade preserves the
"author = write Markdown" workflow that already works, and adopting an
MCP knowledge-graph server gives agent-side query (an audit MCP tool
the critic and reviewer can call mid-gate) without writing one.
Bespoke surface area is restricted to the smallest piece that must be
CI-hermetic and Elixir-native: the registry adapter that parses the
Markdown frontmatter and computes applicability. Root §Acceptance D
(ecosystem reuse over reinvention) is satisfied per-component.

## Sketch

### Finding format (Markdown + YAML frontmatter)

`/.claude/memory/audits/F-0042-no-rescue-bash.md`:

```markdown
---
finding_id: F-0042
title: Bash adapter rescues :exit across process boundary
authored: 2026-05-10
status: open
surface:
  paths:
    - lib/tau/tools/builtin/bash.ex
  modules:
    - Tau.Tools.Builtin.Bash
  ast_pattern: rescue
invariant: OTP non-negotiable #7 — no try/rescue across process boundaries
check_module: Tau.Factory.Checks.NoRescue
check_args:
  allow_in_test: false
source_audit: docs/problems-archive-v1-modules/2026-04-bash-adapter.md
waiver: null
---

## Context
The Bash adapter wraps Port commands in `try/rescue` to translate
`:exit` into `{:error, _}`. This is a Module-bound suppression of a
condition the supervisor should observe. See source audit for the
behaviour repro.

## Remediation
Delete the rescue; let the Port-owner process crash; surface failure
through the standard tool-result error tuple emitted from the dispatcher.
```

A `waived` finding adds:

```yaml
waiver:
  approver: brent.walter@gmail.com
  rationale: "Removing the rescue requires a Port-owner restart strategy
    change that depends on #N. Waived until that lands."
  expires: 2026-08-01
  references: ['#412']
```

### MCP server registration

`/.mcp.json` (project-scoped MCP config; Claude Code auto-loads):

```jsonc
{
  "mcpServers": {
    "tau-audit-graph": {
      "command": "npx",
      "args": ["-y", "@shaneholloman/mcp-knowledge-graph"],
      "env": { "MEMORY_FILE_PATH": ".claude/memory/audits/_graph.jsonl" }
    }
  }
}
```

The graph is materialised from Markdown by `mix tau.audit.sync` (idempotent;
hash-keyed entities). Agents call `tau-audit-graph` tools
(`create_entities`, `search_nodes`, `add_observations`) for query
("findings touching `lib/tau/session.ex`?"). CI does NOT call the MCP
server — it reads the Markdown directly via the Tau adapter.

### Tau.Factory.AuditRegistry (bespoke; ~150 LoC)

```elixir
defmodule Tau.Factory.AuditRegistry do
  @moduledoc "Reads .claude/memory/audits/*.md, returns findings applicable to a diff."

  @type status :: :open | :remediated | :waived
  defmodule Finding do
    @enforce_keys [:id, :status, :surface, :check_module]
    defstruct [:id, :status, :surface, :check_module, :check_args,
               :waiver, :title, :invariant, :path]
  end

  @spec load_all(Path.t()) :: [%Finding{}]
  def load_all(dir \\ ".claude/memory/audits"), do: ...

  @spec applicable_findings([Path.t()], DateTime.t()) :: [%Finding{}]
  def applicable_findings(changed_paths, now \\ DateTime.utc_now()) do
    load_all()
    |> Enum.map(&promote_expired_waiver(&1, now))
    |> Enum.filter(&open?/1)
    |> Enum.filter(&surface_intersects?(&1, changed_paths))
  end

  defp promote_expired_waiver(%Finding{status: :waived, waiver: %{"expires" => exp}} = f, now) do
    if Date.compare(Date.from_iso8601!(exp), DateTime.to_date(now)) == :lt,
      do: %{f | status: :open, waiver: nil},
      else: f
  end
  defp promote_expired_waiver(f, _), do: f

  defp surface_intersects?(%Finding{surface: %{"paths" => globs}}, changed),
    do: Enum.any?(changed, fn p -> Enum.any?(globs, &PathGlob.match?(p, &1)) end)
end
```

### Mix tasks (CI-callable)

- `mix tau.audit.compile` — parses Markdown into a single
  `priv/audit_registry.json` artifact (hermetic; committed); fails on
  schema violations and on duplicate `finding_id`.
- `mix tau.audit.sync` — mirrors Markdown into the MCP graph JSONL
  (developer / Git-hook side; never on CI critical path).
- `mix tau.audit.check` — pre-merge gate runner: loads applicable
  findings for the PR's changed files (from `git diff --name-only
  origin/main...HEAD`), invokes each `check_module`, exits non-zero on
  any failure. Returns "checked, no applicable findings" (NOT
  "skipped") when the diff intersects no surface — satisfies root
  §Acceptance C.

### Meta-test (silent-skip + ingestion guarantee)

`test/tau/factory/audit_registry_meta_test.exs`:

```elixir
test "synthetic open finding fires on probe diff" do
  finding = %Finding{id: "F-META", status: :open,
                     surface: %{"paths" => ["lib/probe.ex"]},
                     check_module: Tau.Factory.Checks.AlwaysFail, ...}
  on_exit(fn -> File.rm!(synthetic_path()) end)
  write_finding!(finding)
  assert {:fail, [%{id: "F-META"}]} =
           Tau.Factory.AuditCheck.run(["lib/probe.ex"])
end

test "expired waiver promotes to open" do ... end
test "no-applicable returns :checked_empty, not :skipped" do ... end
```

### Git hook + CI wiring

- `.git/hooks/post-commit` (installed by `mix tau.factory.install`)
  runs `mix tau.audit.sync` so the MCP graph never lags the Markdown
  source-of-truth.
- `.github/workflows/ci.yml` adds an `audit-gate` job calling
  `mix tau.audit.check`; the job has no `|| true`, no conditional
  skips, and emits a registry-fingerprint comment on the PR so a
  reviewer can confirm what set of findings was evaluated.

### Initial population

`mix tau.audit.import` one-shot script reads
`docs/problems-archive-v1-modules/*.md` and `docs/problems/*.md`,
extracts each numbered finding, emits a draft
`.claude/memory/audits/F-NNNN-<slug>.md`. Includes the seven flagged
`rescue` sites from root §Acceptance F as `status: open`. The migration
is one PR; thereafter authoring is per-finding.

## Tradeoffs

### Strengths

- **Adopt-first.** Three of four major moving parts are off-the-shelf:
  Claude memory cascade (authoring surface), MCP knowledge-graph server
  (agent query), `polya-audit` plugin templates (frontmatter schema).
  Satisfies root §Acceptance D explicitly per component.
- **Authoring habit preserved.** "Write a Markdown file in a known
  directory" is what `docs/problems/` already trains; the new surface
  is the frontmatter, not the workflow.
- **Agent-callable knowledge without bespoke RAG.** The MCP knowledge-
  graph server gives the critic and reviewer agents structured query
  (`search_nodes`, `find_relations`) mid-gate, so they can cite finding
  IDs in verdicts. No vector store, no embedding pipeline.
- **Silent-skip impossible by construction.** The gate's empty-set
  path is a distinct verdict (`:checked_empty`), enforced by a meta-
  test; the CI step has no conditional skip. Satisfies §Acceptance C.
- **CI hermeticity.** The CI critical path never talks to the MCP
  server — it reads committed Markdown and the compiled
  `priv/audit_registry.json`. Network flakiness in MCP cannot fail or
  pass-by-accident a gate.
- **Bespoke surface is small and well-bounded.** ~150 LoC adapter +
  ~50 LoC Mix tasks. Easy to audit; easy to replace if MCP standard
  shifts.
- **Per-finding waivers with expiry are first-class.** Expired waivers
  auto-promote to `open` on the next gate run; no human re-review
  needed to re-arm enforcement.

### Weaknesses

- **MCP server is an external dependency**, even if scoped to
  agent/dashboard query. Server churn (`@modelcontextprotocol/server-
  memory` has had breaking JSONL-format changes in the past) means a
  pin + smoke-test job is needed. Mitigated by keeping MCP out of CI's
  critical path, but the agent-side query path will break if the server
  format drifts.
- **Two-store architecture (Markdown + MCP JSONL) needs a sync
  guarantee.** A developer who edits Markdown but skips `mix
  tau.audit.sync` leaves the MCP graph stale. Mitigations: Git hook on
  commit; a CI check that recomputes the JSONL and diffs against
  committed `priv/audit_registry.json`. Operationally fine; mentally a
  surface area.
- **The Claude memory cascade was not designed as a registry.** It is
  loaded into every Claude Code session as context, which means a
  hundred audit findings get loaded as prompt context every session.
  Mitigation: keep `.claude/memory/audits/_index.md` as the only
  cascade-loaded file (a brief summary + pointer to the directory); the
  per-finding `.md` files are NOT `@import`ed, only read by the registry
  adapter. This means we are using the *directory location* convention
  more than the cascade itself.
- **Frontmatter schema is YAML.** Easy to author, easy to typo. The
  `mix tau.audit.compile` parser must reject unknown keys and validate
  types strictly; absent that, a typo silently disables a finding.
- **`check_module` coupling.** A finding names an Elixir module the
  pre-merge-code-gates sibling must provide. Adding a new check shape
  (e.g. "behaviour-callback missing") requires writing a check_module
  AND a finding; the runner library has to be agreed with the sibling
  leaf.
- **MCP knowledge-graph schema is entity/relation-flat.** Rich relations
  ("F-0042 supersedes F-0031 because remediation strategy changed")
  fit awkwardly; expressible but verbose. The Markdown source-of-truth
  carries the prose; the graph carries only the structured facts the
  agents query against.
- **`@shaneholloman/mcp-knowledge-graph` is a community fork**, not an
  Anthropic-maintained server. The reference `@modelcontextprotocol/
  server-memory` is the safer pin (smaller feature set; fewer
  observation fields). Trade query expressiveness for maintenance risk.

### Costs

- **One-time migration.** ~50 findings to import from
  `docs/problems/` and `docs/problems-archive-v1-modules/`. The import
  script generates drafts; a single review pass per finding
  (frontmatter sanity, surface manifest correctness). Estimate: half
  a working day for the seven flagged `rescue` sites the user named,
  plus one day for the bulk import + spot-check.
- **Build / dependency footprint.** `npx @modelcontextprotocol/server-
  memory` requires Node.js on developer machines (CI does not need
  it). Zero new Elixir deps; pure Mix tasks. `priv/audit_registry.json`
  adds ~10-30 KB to the release.
- **Test surface.** Meta-test (3-5 cases) + per-`check_module`
  contract test (~1 per check, owned by pre-merge-code-gates sibling).
  No new test framework needed.
- **Knowledge required.** YAML, basic Elixir module conventions, MCP
  server registration via `.mcp.json`. Nothing exotic; one short README
  in `polya-audit` plugin.
- **Operational cost.** Sync hook installation is a one-line
  `post-commit` script. CI job is ~30s on a warm cache.

## Dependencies

- **pre-merge-code-gates sibling** delivers the `Tau.Factory.Checks.*`
  modules (one per check shape, e.g. `NoRescue`,
  `BehaviourCallbackPresence`, `CapabilityFlagFidelity`,
  `TelemetryConsumerRegistered`). Their interface contract:
  `check(diff_paths, check_args) :: :ok | {:fail, [finding_id]}`.
- **operability-and-hygiene-enforcement sibling** consumes
  `Tau.Factory.AuditRegistry.summary/0` (counts by status) for its
  dashboard.
- **`@shaneholloman/mcp-knowledge-graph` v0.x pinned** OR
  `@modelcontextprotocol/server-memory` (safer; less feature). Pin
  exact version; smoke-test in `mix tau.audit.sync`.
- **`polya-audit` plugin's authoring skill extended** to emit the
  audit-finding frontmatter schema, so `Claude /polya-audit:audit-
  finding "describe finding"` produces a valid file.
- **One-time migration PR** processes existing audits from
  `docs/problems/` and `docs/problems-archive-v1-modules/` per root
  §Acceptance F.

## Confidence

**Medium-high.** The Claude memory cascade and `.mcp.json` mechanisms
are already used in this repo (`TAU.md`, `MEMORY.md`); the MCP
knowledge-graph server is a published reference implementation; the
Tau-side adapter is small enough that confidence about scope is
realistic. Would raise to **high** with: a 1-day prototype of
`mix tau.audit.compile` + the meta-test fixture firing on a synthetic
finding; and a pin decision between Anthropic-reference and community
MCP server (drives the agent-query expressiveness ceiling).

## Prior art / references

- **Claude Code memory cascade** — `CLAUDE.md` `@import` mechanism and
  per-project `.claude/memory/` directory; Tau already uses it for
  `TAU.md` and `MEMORY.md` (see project's `CLAUDE.md`).
- **Anthropic-published MCP reference: `@modelcontextprotocol/server-
  memory`** — entity/relation knowledge graph, JSONL persistence,
  observation tagging. Reference for the simpler-and-safer pin.
- **Community: `shaneholloman/mcp-knowledge-graph`** — feature-richer
  fork with `add_observations`, `delete_entities`, full-text
  `search_nodes`; reference for richer agent-query path.
- **`polya-audit` plugin in this repo** —
  `.claude/plugins/polya-audit/templates/problem.md` is the parent
  schema; the proposed `audit-finding` template extends it with the
  surface manifest + check binding.
- **`mix credo` plugin pattern** — `Credo.Check` modules registered
  via `.credo.exs`; same shape as the `check_module` field in the
  proposed finding format (precedent for "data file names an Elixir
  module the runner invokes").
- **`sobelow` rule modules** — same Credo-style "registered check"
  pattern for security findings; precedent for keyed-on-AST-pattern
  finding scoping.
- **GitHub Code Scanning SARIF ingestion** — explicitly NOT adopted
  (round-trip overhead, GitHub-platform lock-in, no per-PR
  applicability filter); cited as the rejected alternative for §D
  audit-trail.
- **Anthropic Memory Tool / context-management cookbook** — the
  upstream pattern (`memory_20250818` tool family) for agent-managed
  memory; this proposal does NOT use it for the registry (CI must own
  the source-of-truth) but acknowledges it as the agent-side
  inspiration for the MCP knowledge-graph adoption.

## Gaps / open questions

- **MCP server pin choice** — Anthropic-reference (smaller, safer) vs
  community-fork (richer query). Recommend reference + a Tau-side
  "extended search" Mix task for richer queries; revisit if agent
  workflows demand the richer surface.
- **Frontmatter schema versioning** — when (not if) the schema needs
  a v2, how do existing findings migrate? Recommend a `schema_version`
  field defaulting to 1, with `mix tau.audit.compile` rejecting
  unknown versions and a one-shot migration task per bump.
- **AST-pattern field semantics** — `ast_pattern: rescue` is suggestive
  but not yet machine-checkable here; the actual pattern grammar is
  owned by pre-merge-code-gates' `check_module` library. The finding
  format passes `check_args` opaquely; the contract about what those
  args mean is the sibling leaf's.
- **Cross-finding relations** — supersession, "fixed-by", "blocks"
  are first-class in the MCP graph but not yet in the Markdown
  frontmatter. Recommend a `relations:` list-of-maps field, mirrored
  into the graph at sync time.

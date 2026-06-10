---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Audit-as-Datalog — findings are facts in a Datascript/EDN knowledge base queried by OPA-style policy gates

## Approach

Treat every audit finding (current `docs/problems/`, archived
`docs/problems-archive-v1-modules/`, ADRs, SPEC §3 invariants) as a
**fact** in a Datalog-shaped knowledge base, and treat every code gate
as a **policy query** over that base plus the PR's diff facts. Authoring
becomes a structured commit to one canonical store; enforcement becomes
deterministic query evaluation; remediation/waiver becomes a fact
update with provenance and (for waivers) a TTL fact. Concretely:

1. **Storage.** An append-only EDN/JSON-Lines fact log under
   `priv/factory/audit_facts/` plus a derived materialized index built
   by `mix tau.audit.compile` into a single `priv/factory/audit.db`
   (SQLite + a thin Datalog frontend, e.g. **Datalevin** style, or a
   `Datascript`-shaped in-memory DB rehydrated per CI run).
2. **Schema.** Findings are tuples
   `[:finding/id :finding/surface :finding/invariant :finding/status
    :finding/waiver-expiry :finding/provenance]`; PR diffs are
   transient tuples `[:diff/path :diff/line-range :diff/ast-form]`
   loaded at gate time.
3. **Policy.** Each pre-merge gate is a query (rule) — e.g.
   `?finding-violated(F, PR) :- finding(F, :open), surface-intersects(F, PR), pattern-present(F.invariant, PR).`
   The gate exits non-zero iff at least one fact satisfies the
   violation rule.
4. **Authoring path.** A `tau audit add` slash command (Claude Code
   plugin) opens an editor with the finding template, validates the
   schema with `mix tau.audit.lint`, commits the EDN fact, and a Git
   pre-commit hook rejects malformed or duplicate findings.
5. **Waiver lifecycle.** A waiver is itself a fact
   `[:waiver/finding-id :waiver/expiry-date :waiver/rationale-pr]`;
   a daily scheduled CI job re-queries `expired-waivers` and reopens
   findings whose TTL passed (Prolog-style "negation as failure"
   makes "no current waiver" the default).
6. **Silent-skip impossibility.** The Datalog evaluator distinguishes
   `:no-applicable-findings` (a positive result of the query
   `?surface-intersects(*, PR)` returning empty) from `:not-run`
   (impossible — the binary either ran or CI failed); the
   `mix tau.audit.gate` task writes a JSON verdict file every time
   with `{checked: N, applicable: M, violations: K, status: ...}` and
   exits non-zero on either violations or evaluator crash.

## Rationale

The complecting hypothesis identifies three knots: (a) audit-exists ≠
enforcement-exists; (b) remediation ≠ closure; (c) gate-applicability
is implicit. Datalog/Datascript dissolve all three: (a) a fact IS a
query input — authoring and enforcement are the same event horizon,
because the evaluator reloads the materialized DB every run; (b)
status and waiver are independent facts with their own provenance and
TTL, so "remediated" and "closed" are no longer the same row; (c)
applicability is a *rule* over surface-intersection — explicit,
inspectable, testable in isolation. The pattern is the inverse of
ad-hoc Credo checks: instead of N hand-coded check modules each
embedding their own scope logic, one evaluator runs M facts × P
diff-rows. Adding a finding requires zero code changes — only a fact
commit — which closes failure class #10's root cause: the cost
gradient from "audit prose" to "enforced check" today is so steep that
humans stop at prose. Here, the gradient is one EDN file.

Prior art is dense. OPA/Rego is the canonical "policy as code over
facts" pattern in production at Netflix, Capital One, Pinterest; their
`conftest` runs the same shape against arbitrary JSON. Datomic and
Datascript demonstrate Hickey-style "data is the API"; Datalevin and
XTDB show Datalog over SQLite/RocksDB at production scale on the
BEAM-adjacent JVM. Codebase-facts-as-Datalog is the design of
**Glean** (Meta, queries Hack/Python/C++ codebases as facts) and
**Semantic** (GitHub, AST facts queryable with Datalog-style rules).
Dolt provides a Git-shaped Datalog-friendly relational store. The
match between "facts authored once, queried forever" and the parent's
acceptance criterion is exact.

## Sketch

### Fact format (EDN-shaped JSON for editor familiarity)

```jsonl
{"finding/id": "AUDIT-RESCUE-0001",
 "finding/kind": "no-rescue-cross-process",
 "finding/surface": {"globs": ["lib/tau/**/*.ex"],
                     "modules": ["Tau.Session", "Tau.TUI.App"],
                     "ast-pattern": "(try ... (rescue _ -> _))"},
 "finding/invariant": "OTP-NN-7-no-rescue-across-process-boundary",
 "finding/status": "open",
 "finding/waiver": null,
 "finding/provenance": {"source-doc": "docs/problems-archive-v1-modules/audit-2025-11.md",
                        "section": "§4.2",
                        "authored-pr": 287,
                        "authored-at": "2025-11-14T09:11:00Z"}}
```

### Registry module

```elixir
defmodule Tau.Factory.AuditRegistry do
  @moduledoc """
  Loads compiled audit facts from priv/factory/audit.db and answers
  applicability queries. Pure functions over an immutable Datalog DB
  rehydrated at process start; no GenServer — the DB is read-only at
  gate time.
  """

  @spec load!() :: t()
  def load!() do
    Path.join(:code.priv_dir(:tau), "factory/audit.db")
    |> Tau.Datalog.open_read_only!()
  end

  @spec applicable(t(), Tau.Factory.PRDiff.t()) :: [Finding.t()]
  def applicable(db, %Tau.Factory.PRDiff{} = diff) do
    Tau.Datalog.q(db, ~Q"""
      [:find (pull ?f [*])
       :in $ ?diff-paths ?diff-modules
       :where
       [?f :finding/status :open]
       [?f :finding/surface ?s]
       (surface-intersects ?s ?diff-paths ?diff-modules)
       (not-waived ?f)]
      """, diff.paths, diff.modules)
  end

  @spec violations(t(), Tau.Factory.PRDiff.t()) :: [Violation.t()]
  def violations(db, diff) do
    db
    |> applicable(diff)
    |> Enum.flat_map(&Tau.Factory.PatternEval.match(&1, diff))
  end
end
```

### Mix gate task

```elixir
defmodule Mix.Tasks.Tau.Audit.Gate do
  use Mix.Task

  @impl true
  def run(_args) do
    db = Tau.Factory.AuditRegistry.load!()
    diff = Tau.Factory.PRDiff.from_env!()  # reads GITHUB_BASE_REF + git
    violations = Tau.Factory.AuditRegistry.violations(db, diff)
    verdict = %{
      checked: Tau.Datalog.count(db, [:finding/status, :open]),
      applicable: length(Tau.Factory.AuditRegistry.applicable(db, diff)),
      violations: length(violations),
      status: if(violations == [], do: :pass, else: :fail)
    }
    File.write!("audit-gate-verdict.json", Jason.encode!(verdict))
    if violations == [], do: :ok, else: exit({:shutdown, 1})
  end
end
```

### File layout

```
priv/factory/audit_facts/
  AUDIT-RESCUE-0001.jsonl      # one fact per file, append-only
  AUDIT-RESCUE-0002.jsonl
  AUDIT-CAPFLAG-PROMPTCACHE-0001.jsonl
  ...
priv/factory/audit.db          # materialized SQLite-backed Datalog DB
                               # generated by `mix tau.audit.compile`
lib/tau/factory/
  audit_registry.ex
  datalog.ex                   # thin frontend over Exqlite + Datalog rules
  pr_diff.ex
  pattern_eval.ex              # AST matchers per invariant kind
.claude/plugins/tau-audit/     # plugin: `tau audit add` / `tau audit list`
  agents/audit-author.md
  commands/audit-add.md
  hooks/pre-commit-validate.sh
.github/workflows/audit.yml    # `mix tau.audit.compile && mix tau.audit.gate`
```

### Meta-test (acceptance criterion d)

```elixir
test "synthetic finding fires on a probe PR" do
  db = Tau.Factory.AuditRegistry.load_with_overlay!([
    %Finding{id: "SYNTH-001", status: :open,
             surface: %{globs: ["lib/tau/probe.ex"]},
             invariant: :no_rescue}
  ])
  diff = %PRDiff{paths: ["lib/tau/probe.ex"], ast_forms: [{:try, ..., [{:rescue, ...}]}]}
  assert [%Violation{finding_id: "SYNTH-001"}] = AuditRegistry.violations(db, diff)
end
```

## Tradeoffs

### Strengths

- **Decomplects fact from check (parent §Complecting #1):** a fact and
  its enforcement query are textually distinct artifacts but share a
  schema; adding a fact requires zero code.
- **Decomplects status from closure (parent §Complecting #2):**
  `:remediated` and `:waived` are independent values with provenance;
  a waiver carries TTL by schema, so silent indefinite waivers are
  syntactically impossible.
- **Decomplects applicability from PR-shape (parent §Complecting #3):**
  surface-intersection is a Datalog rule reusable across gates; a new
  scope predicate (e.g. "only files modified in the last 90 days")
  is a one-rule change, not N gate edits.
- **Silent-skip impossibility (root §C):** the verdict JSON is always
  emitted; `:no-applicable-findings` is a positive outcome of a
  successful query, not an absence. The CI job that consumes the
  verdict file fails the PR if the file is missing OR contains
  `status != :pass`.
- **Mechanical enforceability (root §B):** the entire surface is one
  binary (`mix tau.audit.gate`) plus one DB file; no agent judgement
  in the loop.
- **Ecosystem reuse over reinvention (root §D):** Datalog/EDN are
  battle-tested as policy substrates (OPA at scale; Glean for AST
  facts; XTDB for bitemporal queries). The bespoke part is the AST
  pattern matchers, which already exist in Credo's check modules and
  can be lifted.
- **Backward integration (root §F):** the initial seed is one
  `mix tau.audit.seed` task that walks `docs/problems/` and
  `docs/problems-archive-v1-modules/`, extracting structured blocks
  (per a YAML-frontmatter convention) into the fact log. The seven
  rescue sites become seven facts; the meta-test confirms they fire.
- **Bitemporal provenance:** every fact carries `authored-at`; the
  Datalog evaluator can answer "what was the rule set on date X" —
  useful for forensic re-runs of historic merges (the four bypassing
  merges #411-#414 can be re-evaluated against today's facts).
- **Composable with other gates:** the same DB can answer queries
  for the post-merge-cross-artifact-coherence sibling (SPEC↔SPEC
  contradiction is a Datalog query over SPEC-derived facts).

### Weaknesses

- **Datalog literacy is rare on the BEAM.** Elixir engineers
  generally know SQL and pattern matching but not Datalog. The
  schema and rule corpus need clear docs and examples or only the
  proposal's author will maintain them.
- **Pattern-matcher coverage is the real work.** The Datalog
  evaluator is cheap to build (thin layer over SQLite); the AST
  patterns for each invariant kind (`no_rescue`, `capability_flag`,
  `telemetry_consumer_required`) require care and test. Estimated
  60-80% of implementation effort lives here, not in the Datalog
  layer. Credo's existing check modules can be lifted, mitigating
  this — but lift cost is non-zero.
- **Single store = single point of failure for evaluator bugs.** A
  bug in the rule evaluator silently passes every PR. Mitigation: a
  golden-test corpus (`test/tau/factory/golden_violations_test.exs`)
  asserts known-bad diffs trigger known-finding violations on every
  CI run; an evaluator that returns "all clean" against the corpus
  fails the meta-test and blocks the merge.
- **EDN/JSON-Lines authoring friction.** "Write some YAML" is lower
  friction than "construct a fact tuple." The `tau audit add` plugin
  command hides this, but a human bypassing the plugin to hand-edit
  has to know the schema. The pre-commit hook mitigates by rejecting
  malformed facts, but the error message must be excellent.
- **Materialized-DB drift.** `priv/factory/audit.db` is generated
  from `priv/factory/audit_facts/`; if a developer commits `.db` but
  not the `.jsonl` source, the gate runs on stale facts. Mitigation:
  CI regenerates `.db` from `.jsonl` and refuses to use a committed
  one; pre-commit hook refuses commits where `.db` is dirty without
  a matching `.jsonl` change.
- **Rule-set evolution risk.** Changing a Datalog rule's semantics
  silently changes every gate's verdict. Mitigation: rule files live
  in `lib/tau/factory/rules/`, are versioned with a manifest hash,
  and a rule-change PR triggers a re-run against the golden corpus
  AND a re-run against the last 100 merged PRs' diffs (replay) to
  surface any newly-failing historical merges (which become tickets,
  not blockers, but visibility is the point).
- **No GUI for findings.** Compared to a dashboard like FireHydrant's
  postmortem UI, this is text + CLI. The operability-and-hygiene
  sibling can surface "open findings count" but rich exploration
  requires a separate tool (acceptable per scope).

### Costs

- **One-time:** ~1500-2000 LOC across `Tau.Datalog`, `AuditRegistry`,
  `PatternEval`, `PRDiff`, plus the `tau-audit` plugin and the seed
  task. Estimate 2-3 PRs.
- **Per finding:** authoring one finding via `tau audit add` takes
  ~5 min (template + the surface manifest + the invariant choice
  from an enum); the friction is the surface manifest, not the
  ceremony.
- **Build/dep:** adds Exqlite (already in deps for SPEC-MEMORY-STORE)
  and `jason` (already there). No new runtime dependencies. The
  Datalog layer is in-tree; ~400 LOC sufficient for the rule shapes
  the gates need (we are not building a general-purpose Datalog).
- **CI time:** the gate adds one `mix` invocation per PR;
  Datalog-over-SQLite on a fact set of 10²-10³ findings against a
  diff of 10²-10³ rows runs in <2s.
- **Knowledge:** the audit-author plugin and a single
  `docs/factory-v2/audit-fact-schema.md` should suffice for
  contributors. The Datalog-internal rule files need one engineer
  comfortable with the syntax — a single `.claude/skills/datalog-
  rules-for-audit.md` skill bridges others.

## Dependencies

- Exqlite (already in the dep tree; SPEC-MEMORY-STORE).
- Decision from the **pre-merge-code-gates** sibling on whether it
  consumes audit-violation verdicts via the JSON verdict file
  (loose coupling, recommended) or via a direct
  `Tau.Factory.AuditRegistry.violations/2` call (tight coupling).
  Loose is the default.
- Agreement on the AST-pattern DSL: either lift Credo's check format
  (faster) or define a minimal pattern language (`{:try, _, [{:rescue, _, _}]}`-style
  Elixir match specs — preferred, zero new DSL).
- A `Tau.Factory.PRDiff` builder that converts `git diff
  origin/main...HEAD` into `{paths, modules, ast-forms}` — depends on
  the **pre-merge-evidence-and-skip-integrity** sibling's "what
  counts as the diff" decision.
- Plugin auto-registration of `tau audit add` requires
  `.claude/settings.json` permissions for the `Bash(git commit)` and
  `Edit` tools in the plugin scope; standard.

## Confidence

**Medium-high.** The Datalog substrate over SQLite is a well-worn
pattern (Datalevin, XTDB) and the OPA/Rego analogue is in production
across many sites; the BEAM-side adaptation is straightforward.
Confidence is not "high" because the AST-pattern matchers are
non-trivial and the rule-evolution discipline is a process risk, not
a code risk. What would raise confidence: a 200-LOC prototype that
ingests the seven archived rescue findings, materializes the DB,
runs the gate against a known-bad diff, and emits the verdict JSON
— roughly half a day's work.

## Prior art / references

- **Datalog as policy substrate:** OPA / Rego
  (https://www.openpolicyagent.org); `conftest` for Kubernetes
  manifests; Sigstore's policy engine.
- **Datalog over code facts:** Meta's **Glean**
  (https://glean.software) indexes AST facts queryable with
  Datalog-shaped queries; GitHub's **Semantic**
  (https://github.com/github/semantic) for the same purpose; **CodeQL**
  uses Datalog under the hood for security queries.
- **In-process Datalog stores:** **Datascript**
  (https://github.com/tonsky/datascript) for browser-side fact stores;
  **Datalevin** (https://github.com/juji-io/datalevin) and **XTDB**
  (https://xtdb.com) for embedded/server bitemporal stores;
  **Datomic** for the canonical immutable-fact-log shape.
- **Append-only fact log + materialized index:** Datomic's transaction
  log; the **Dolt** versioned relational store; Event Sourcing
  patterns (Greg Young).
- **Waiver-with-expiry as enforcement:** Trivy's `.trivyignore` with
  expiry; Snyk policy file expirations; the npm-audit `audit-ci` waiver
  TTL pattern; Sentry's "ignore until" feature.
- **Policy-as-code in production:** Capital One's OPA case studies;
  Pinterest's Rego deployment posts; Netflix's policy-driven
  authorization.
- **Structured-knowledge ingestion on the BEAM:** the precedent
  closest in spirit is `mix credo`'s check-module discovery — Credo
  itself is "rules over AST" with hand-coded checks; this proposal
  generalises the substrate so rules are data, not code.

## Silent-skip impossibility — explicit treatment

Root §C demands gates cannot silent-skip. This proposal makes
silent-skip *syntactically* impossible at three layers:

1. **At evaluator level.** The Datalog query for applicability is
   `?applicable-findings(PR)`; an empty result is the *value* `[]`,
   not the *absence* of a value. The gate task always writes
   `audit-gate-verdict.json` and CI fails if the file is absent.
2. **At CI level.** The `audit-gate` job has no `continue-on-error`,
   no `if:` predicate that can suppress it, and no `|| true` (the v1
   anti-pattern at `ci.yml:115`). A guard test in
   `test/ci/workflow_lint_test.exs` parses `.github/workflows/*.yml`
   and asserts these absences — itself a meta-gate run on every PR.
3. **At schema level.** A "no applicable findings" verdict is a
   *positive* JSON object (`{applicable: 0, violations: 0, status:
   :pass}`); there is no JSON shape representing "skipped." A
   verdict file with a missing field is rejected by JSON-schema
   validation before CI reads it, surfacing infrastructure failure as
   a hard fail, not as a silent pass.

The composition of (1) + (2) + (3) means the only way an audit
finding is not enforced on a PR that touches its surface is: the
finding is not in the fact log (caught by the meta-test that asserts
the seed findings load), OR the surface manifest is wrong (caught by
the golden-test corpus that asserts known-bad diffs trigger known
findings). Neither is a silent skip — both are mis-authoring,
addressable by the pre-commit linter.

## Rejected pattern variants

For diversity bookkeeping (the proposer surveyed these and rejected
each):

- **ADR-tools / MADR ingestion as-is** — rejected because ADR
  frameworks (adr-tools, ADR-Manager, MADR) store findings as
  numbered Markdown files with prose headings. They are excellent
  for human reading and poor for mechanical querying; converting an
  ADR's "Consequences" section into a check is the exact ad-hoc step
  this proposal eliminates. ADRs remain valuable as *source
  documents* — their structured frontmatter feeds the fact log via
  the seed task — but they are not the enforcement substrate.
- **Postmortem-Manager / FireHydrant ingestion** — rejected because
  these are operational-incident tools optimised for post-event
  workflows (timeline, contributing factors, action items) with rich
  UIs. The factory needs lightweight, queryable, append-only facts
  embedded in the repo, not a SaaS or a heavyweight DB. Their action-
  item-with-owner concept does inform the waiver-with-rationale-PR
  schema, however.
- **Org-mode / literate-programming as memory** — rejected because
  Org-mode's structured outline plus Babel code blocks are excellent
  for human-readable knowledge but require a parser per consumer.
  Translating an Org subtree into a Datalog fact is feasible but
  adds an Emacs-shaped dependency on the authoring path, which the
  audit-author plugin avoids by going straight to EDN/JSON.
- **Semver / changesets discipline (Knope, changesets)** — rejected
  as the *primary* substrate because changesets answer "what changed
  in this release" rather than "what invariants does this codebase
  uphold." The waiver-TTL element is borrowed (a changeset declares
  a planned-removal version; a waiver declares a planned-expiry
  date), but the fact-log layer is necessary for the per-PR
  applicability query.
- **Neo4j / TerminusDB / Dolt as knowledge graph** — rejected as
  overkill. A graph DB shines when relationships are dense
  (transitive ownership, organisational hierarchy); audit findings
  are flatter (a finding has a surface, a status, optionally a
  waiver). Datalog over SQLite covers this shape with one binary,
  zero new infrastructure, and the same query expressiveness for the
  cases this leaf needs. Dolt's Git-shaped storage is an interesting
  alternative for the *fact log* layer specifically; we use plain
  JSON-Lines under Git for simpler reviewability.
- **GitHub Code Scanning SARIF round-trip** — partially adopted, not
  primary. SARIF is excellent at *reporting* findings into GitHub's
  UI but weak at *driving* gate decisions (its semantics are
  advisory). The gate writes SARIF as a *side output* for visibility,
  but the merge-block decision comes from the JSON verdict file. This
  is the same split OPA takes: Rego decides, OpenTelemetry / SARIF
  reports.

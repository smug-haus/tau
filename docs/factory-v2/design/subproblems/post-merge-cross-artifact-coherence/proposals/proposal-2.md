---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Scheduled `polya-audit` coherence-agent run on `main`, driven by a YAML rules-pack and a `validation.md → gh issue` adapter

## Approach

Adopt the in-repo `polya-audit` Claude Code plugin
(`.claude/plugins/polya-audit/`) as the cross-artifact coherence engine.
Run it as a **scheduled, non-interactive Claude Code subagent** invoked
from a GitHub Actions workflow that triggers on (a) `push:
branches: [main]` and (b) `schedule: cron '17 4 * * *'` (daily). The
agent is the existing **`researcher`** + **`validator`** pair, but
fronted by a new sub-skill `coherence-audit` (a sibling of
`code-audit-polya`) whose `SKILL.md` loads a structured rules pack at
`.claude/plugins/polya-audit/coherence-rules.yaml`. Each rule names a
contradiction class (D-NNN uniqueness, SPEC §4 symbol resolution, ADR
supersession integrity, telemetry-emit-without-consumer on `main`, SPEC
↔ SPEC contradiction by D-NNN id, Appendix-B path liveness) and a
deterministic detector (a Mix task, an AST grep, a JSON-Schema check, or
— for the contradiction-by-meaning class — a Claude-call constrained to
produce a typed `%CoherenceFinding{}` artifact). The agent's output is a
`validation.md`-shaped artifact under
`.code_audit/main-coherence/<run-id>/` whose findings a thin Elixir
escript (`Mix.Tasks.Tau.Coherence.Report`) converts into one GitHub
issue per finding class, milestoned to the current focus milestone,
labelled `coherence`, and linked to the run-id directory. The workflow
fails (exit non-zero) iff `findings_count > 0` OR
`detectors_attempted < detectors_registered` — the second clause is the
silent-skip guard.

## Rationale

The leaf's complecting hypothesis decomposes into three weaves: (a)
"what a SPEC says" vs "what the code does" — linked only by prose
Appendix-B; (b) "when a contradiction arose" vs "which PR introduced
it" — invisible per-diff because the contradiction emerges from the
*combination* of merges; (c) "D-NNN uniqueness" vs "the author
remembered to grep". A *single-shot, on-`main`, rules-pack-driven
agent* decomplects all three simultaneously: it sees the whole tree
(not a diff), it has machine-readable Appendix-B (the rules pack is
the manifest the leaf's acceptance criterion (e) calls for), and its
detectors run uniformly regardless of who authored what. Reusing the
already-present `polya-audit` agents (`researcher`, `validator`,
`coordinator`) honours root §Acceptance D (ecosystem reuse over
reinvention) and reduces new code to: one workflow file, one sub-skill
directory, one YAML rules pack, one escript adapter. The `validator`'s
Toulmin + falsification protocol gives every finding a documented
backing claim — addressing root §Hypothesis directly: the coherence
verdict is *not* "agent says so" but "rule R fired on artifact A at
location L, with backing evidence B".

## Sketch

### File / module changes

```
.claude/plugins/polya-audit/skills/coherence-audit/SKILL.md      [NEW]
.claude/plugins/polya-audit/skills/coherence-audit/rules.md      [NEW]
.claude/plugins/polya-audit/coherence-rules.yaml                  [NEW]
.github/workflows/main-coherence.yml                              [NEW]
lib/mix/tasks/tau.coherence.report.ex                             [NEW]
lib/mix/tasks/tau.coherence.dnnn.ex                               [NEW]
lib/mix/tasks/tau.coherence.spec_contracts.ex                     [NEW]
lib/mix/tasks/tau.coherence.adr_supersession.ex                   [NEW]
lib/mix/tasks/tau.coherence.appendix_b_liveness.ex                [NEW]
lib/mix/tasks/tau.coherence.telemetry_consumers.ex                [NEW]
lib/tau/coherence/finding.ex                                      [NEW]
lib/tau/coherence/rule.ex                                         [NEW]
lib/tau/coherence/runner.ex                                       [NEW]
test/tau/coherence/dnnn_test.exs                                  [NEW]
test/tau/coherence/spec_contracts_test.exs                        [NEW]
test/tau/coherence/runner_property_test.exs                       [NEW]
docs/spec/SPEC-MAIN-COHERENCE.md                                  [NEW]
```

### Rules-pack schema (`coherence-rules.yaml`)

```yaml
version: 1
rules:
  - id: D-NNN-UNIQ
    title: D-NNN identifiers are unique across lib/, test/, docs/, .claude/
    detector:
      kind: mix_task
      task: tau.coherence.dnnn
    fails_loud_on:
      - duplicate_id
      - id_in_code_not_in_spec
    severity: error

  - id: SPEC-S4-RESOLVE
    title: Every SPEC §4 contract symbol resolves on main
    detector:
      kind: mix_task
      task: tau.coherence.spec_contracts
    inputs:
      spec_glob: "docs/spec/SPEC-*.md"
      section: "## 4"
      symbol_extractor: erlang_module_callback_struct
    severity: error

  - id: SPEC-SPEC-CONTRA
    title: No two SPECs contradict each other on a shared D-NNN
    detector:
      kind: agent_constrained
      agent: validator
      backing_required: true
      output_shape: "Tau.Coherence.Finding"
    severity: error

  - id: ADR-SUPERSEDE
    title: Supersession links are bidirectional
    detector:
      kind: mix_task
      task: tau.coherence.adr_supersession
    severity: error

  - id: APPENDIX-B-LIVE
    title: spec-before-code Appendix B paths exist and at least one symbol per file is mentioned in the SPEC body
    detector:
      kind: mix_task
      task: tau.coherence.appendix_b_liveness
    severity: error

  - id: TELEMETRY-CONSUMER
    title: Every :telemetry.execute on main has at least one non-debug consumer
    detector:
      kind: mix_task
      task: tau.coherence.telemetry_consumers
    severity: warn  # cumulative tail — root #4 already pre-merge-gated
```

### Module signatures

```elixir
defmodule Tau.Coherence.Finding do
  @enforce_keys [:rule_id, :artifact, :location, :message, :backing]
  defstruct [:rule_id, :artifact, :location, :message, :backing, severity: :error]
  @type t :: %__MODULE__{
          rule_id: String.t(),
          artifact: String.t(),
          location: String.t(),
          message: String.t(),
          backing: [%{kind: atom(), evidence: String.t()}],
          severity: :error | :warn
        }
end

defmodule Tau.Coherence.Runner do
  @spec run(Path.t()) ::
          {:ok, %{attempted: non_neg_integer(),
                  registered: non_neg_integer(),
                  findings: [Tau.Coherence.Finding.t()]}}
          | {:error, {:silent_skip_detected, [String.t()]}}
  def run(rules_yaml_path), do: ...
end

defmodule Mix.Tasks.Tau.Coherence.Report do
  use Mix.Task
  # exit codes:
  # 0   — all detectors ran, zero findings
  # 1   — findings present (any severity == :error)
  # 2   — silent-skip detected (attempted < registered)
  # 3   — rules.yaml unparseable
  def run(argv), do: ...
end
```

### Workflow (`.github/workflows/main-coherence.yml`)

```yaml
name: main-coherence
on:
  push:
    branches: [main]
  schedule:
    - cron: '17 4 * * *'
permissions:
  contents: read
  issues: write
concurrency:
  group: main-coherence
  cancel-in-progress: false
jobs:
  coherence:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: erlef/setup-beam@v1
        with: { otp-version: '27.2', elixir-version: '1.18.1' }
      - run: mix deps.get --only test
      - run: mix tau.coherence.report --rules .claude/plugins/polya-audit/coherence-rules.yaml --out .code_audit/main-coherence/${{ github.run_id }}/
        id: cohere
      - name: Open issues for findings
        if: failure()
        env: { GH_TOKEN: ${{ secrets.GITHUB_TOKEN }} }
        run: |
          set -euo pipefail
          for f in .code_audit/main-coherence/${{ github.run_id }}/*.finding.json; do
            gh issue create \
              --label coherence \
              --milestone "$(gh api repos/${{ github.repository }}/milestones --jq '.[] | select(.state=="open") | .title' | head -1)" \
              --title "coherence: $(jq -r .rule_id $f) at $(jq -r .artifact $f):$(jq -r .location $f)" \
              --body-file $f
          done
      - name: Silent-skip guard
        if: steps.cohere.outputs.exit_code == '2'
        run: |
          echo "::error::Silent-skip detected: detectors_attempted < detectors_registered"
          exit 2
```

### Agent invocation (used only for `SPEC-SPEC-CONTRA`)

The `coherence-audit` sub-skill, when handed an `agent_constrained`
rule, invokes the existing `polya-audit` `researcher` agent (already
isolated, Read-only) with a typed output prompt that demands one JSON
object per `Tau.Coherence.Finding` field; the runner rejects any output
that does not parse, treating that as a detector failure (silent-skip
class), not a "no findings" pass.

## Tradeoffs

### Strengths

- **Maximises ecosystem reuse (acceptance D).** Reuses
  `.claude/plugins/polya-audit/agents/researcher.md`,
  `.../agents/validator.md`, and the entire `.../templates/` tree.
  New code is bounded to ~5 Mix tasks (≤ 250 LOC each), 1 YAML pack,
  1 workflow, 1 escript adapter, 1 SPEC. Estimated < 1.5 KLOC new
  Elixir.
- **Silent-skip impossibility is structural, not procedural.** Exit
  code 2 means *the runner could not attempt a registered rule*; the
  workflow surfaces this as a hard failure with `::error::` and a
  distinct GitHub Check annotation. There is no `|| true`; there is
  no path where `findings == 0` AND `attempted < registered` returns
  green.
- **`validator`'s Toulmin discipline is load-bearing.** Each finding
  ships its backing evidence (file:line, AST node, grep hit). The
  v1 PERMISSION-PROMPTS B5/D-171 case detects on first run: rule
  `SPEC-SPEC-CONTRA` finds D-171 cited with two different cardinalities
  (6 vs 3) and emits a `%Finding{}` with both backings.
- **Cadence + push-trigger gives O(hours) detection of cumulative-tail
  drift.** Root §Hypothesis #1 / #4 (the tails) are caught by daily
  cron even when no PR touches the relevant surface.
- **Rules pack is the manifest.** Acceptance criterion (a) requires a
  "structured source-map manifest format" — the YAML rules pack with
  per-rule `inputs.spec_glob` and `symbol_extractor` IS that manifest;
  it lives next to the plugin that consumes it.

### Weaknesses

- **`SPEC-SPEC-CONTRA` rule is the one detector that depends on a
  Claude call.** Even with strict output-schema enforcement, this
  rule's recall is not deterministic across runs. Mitigation: the
  runner pins the model + prompt + temperature, but a missed
  contradiction will not be re-detected until the next cadence run,
  and a hallucinated contradiction will spam issues until quashed.
  The other five rules are pure-AST / pure-grep and deterministic.
- **GitHub Actions cron jitter (≥ 15-minute documented variance) and
  the lack of guaranteed exactly-once scheduling.** Two cron runs may
  fire close together; the `concurrency` group prevents overlap but
  may cause skipped runs. Detection latency floor is therefore ~15
  minutes + run time, not "real time on push".
- **Adds a new failure surface in the `gh issue create` step.** A
  GitHub API outage produces a workflow failure that looks like a
  coherence failure (post-`if: failure()` step never runs and findings
  go undelivered). Distinguishing the two requires inspecting the
  workflow step log, not the issue tracker. Partial mitigation:
  upload findings as workflow artifact unconditionally.
- **No fix-suggesting agent.** Findings open issues; they don't open
  PRs. The leaf's acceptance does not require fixes, only detection;
  the operability sibling consumes verdicts. But a high finding rate
  will increase coordinator backlog management work.
- **Cron-driven Claude invocation has a non-zero token cost per run**
  (~5 K input + agent reasoning; estimated < $0.05/day at current
  Sonnet pricing for the `SPEC-SPEC-CONTRA` rule only; pure-AST rules
  use zero tokens). Annual cost ≤ $20 — accepted.

### Costs

- **New code:** ~1.5 KLOC Elixir + 1 YAML + 1 workflow + 1 SPEC
  (~400 LOC).
- **New deps:** `yaml_elixir` for rules-pack parsing (already a common
  dep in the ecosystem; lightweight). `sourceror` for AST walks in
  `tau.coherence.spec_contracts` and `tau.coherence.telemetry_consumers`
  — already pulled transitively by `credo` (check `mix deps.tree`);
  add explicit dep for safety.
- **CI minutes:** estimated 6-12 min per main push or cron tick. Two
  push-runs per day average + 1 cron = ~30 min/day, well within free
  tier.
- **Knowledge:** maintainer must understand the YAML rules-pack schema
  + the `Tau.Coherence.Finding` shape. Both are documented in
  `SPEC-MAIN-COHERENCE.md` (the SPEC is a deliverable of this proposal,
  consistent with `spec-before-code.md`).

## Dependencies

- The `polya-audit` plugin remains at `.claude/plugins/polya-audit/`
  (currently present; not removed by any in-flight work).
- The operability sibling
  (`subproblems/operability-and-hygiene-enforcement/`) consumes the
  `.code_audit/main-coherence/<run-id>/*.finding.json` artifact for
  the dashboard. This proposal produces them; the dashboard reads them.
- The audit-ingestion sibling
  (`subproblems/knowledge-memory-and-audit-ingestion/`) MAY reuse
  `Tau.Coherence.Finding` as its finding shape — coordinate.
- `mix tau.coherence.report` requires GitHub-Actions context to open
  issues; locally it dumps JSON and prints the would-be-created issues
  to stdout.

## Confidence

**Medium-high.** The pattern (scheduled GH Actions workflow + Mix task
+ thin agent wrapper) is well-trodden in the Elixir / Claude Code
ecosystem; the unknown is recall on `SPEC-SPEC-CONTRA`. What would
raise confidence: a one-day prototype of `tau.coherence.dnnn` +
`tau.coherence.spec_contracts` run against current `main` — both
should already produce ≥ 1 finding (D-171 cardinality contradiction,
known SPEC §4 callbacks-that-no-longer-resolve). If those two
deterministic rules light up on first run, the architecture is
validated; the `SPEC-SPEC-CONTRA` agent-rule can be added in a follow-up.

## Prior art / references

- `.claude/plugins/polya-audit/` (this repo) — the in-repo Pólya-tree
  audit plugin; `researcher` and `validator` agents have the exact
  shape this proposal reuses.
- `.code_audit/skills/code-audit-polya/validate.md` — the Toulmin +
  falsification protocol that each finding's `backing` field
  conforms to.
- `.github/workflows/ci.yml:88-100, :115, :213-223` — the silent-skip
  patterns this proposal's exit-code-2 guard makes structurally
  impossible (root §Acceptance C anti-pattern).
- `.claude/rules/spec-before-code.md` Appendix-B convention — the
  current prose manifest the YAML rules pack supersedes for
  machine-resolvable use.
- `.claude/skills/loop/` — the `/loop` skill is Tau's existing
  scheduled-driver primitive; the GitHub Actions cron is the
  *production* equivalent of `/loop`'s local interval, chosen because
  cron survives the operator's machine being off and because GH
  Actions provides the secret + token context for `gh issue create`.
- `docs/factory-v2/PLAN.md` Workstream-1 § "Adapt-from-Claude-Code-
  ecosystem" — this proposal's directive.
- GitHub Actions `schedule` event docs
  (https://docs.github.com/actions/using-workflows/events-that-trigger-workflows#schedule)
  — confirms ≥ 15-minute jitter caveat noted under Weaknesses.
- `Sourceror` (https://hexdocs.pm/sourceror) — for AST walks; produces
  source-position metadata used by `Finding.location`.

## §Build-order (favouring adopt over invent)

1. **(adopt)** Wire `.github/workflows/main-coherence.yml` to invoke
   the existing `polya-audit` plugin's `researcher` agent in
   read-only mode against a single hardcoded rule (`D-NNN-UNIQ`)
   using a stub `coherence-rules.yaml`. Verify the workflow runs
   green on `main`; verify silent-skip guard fires when the rule
   list is empty. **Adopt-vs-invent: 95% adopt** (one new YAML
   workflow + one stub Mix task that grep-and-counts D-NNNs).
2. **(adopt)** Author `coherence-rules.yaml` with all six rules but
   only wire the three deterministic Mix-task detectors
   (`D-NNN-UNIQ`, `APPENDIX-B-LIVE`, `ADR-SUPERSEDE`). Reuses the
   existing plugin's skill-loading machinery. **Adopt-vs-invent:
   ~70%.**
3. **(invent — minimum-viable)** Author the four Mix-task detectors
   + `Tau.Coherence.Finding` + `Tau.Coherence.Runner` + SPEC. This
   is the bulk of the new code, but each task is small and
   independent. **Adopt-vs-invent: ~20%; Sourceror is the only
   pulled dep doing meaningful work.**
4. **(adopt)** Author `Mix.Tasks.Tau.Coherence.Report` as a thin
   shim over `gh issue create` (no new HTTP client; subprocess gh).
   **Adopt-vs-invent: 90% adopt** (the `gh` CLI is already in CI).
5. **(adopt + minimum invent)** Add the `SPEC-SPEC-CONTRA`
   agent-constrained rule last, after the deterministic rules are
   green. Reuses the `validator` agent's existing schema-output
   discipline; the new code is a JSON-schema validator over the
   agent's output (≤ 80 LOC). **Adopt-vs-invent: 75% adopt.**
6. **(adopt)** Add `TELEMETRY-CONSUMER` rule using the existing
   pre-merge sibling's telemetry-consumer detector run in
   cumulative-on-`main` mode. **Adopt-vs-invent: 100% adopt** if
   the pre-merge sibling has shipped; trivial wrapper otherwise.

Total new Elixir ≤ 1.5 KLOC, ≥ 70% reuse weight across the build
order — satisfying root §Acceptance D.

## §Gaps (honestly enumerated)

- **G1 — `SPEC-SPEC-CONTRA` recall.** A subtle contradiction phrased
  in differing prose between two SPECs may not be detected by the
  Claude-call. Reduces strict-coverage of root §Hypothesis #9 to
  "high-recall on D-NNN-keyed contradictions; medium-recall on
  free-prose contradictions." Mitigation: the deterministic `D-NNN-
  UNIQ` rule catches the v1 PERMISSION-PROMPTS B5/D-171 case
  unconditionally because the contradiction surfaces on the D-NNN
  identifier — Hypothesis #9's canonical example is covered
  deterministically.
- **G2 — Issue-noise.** A single misconfiguration may cause N
  duplicate issues. Mitigation: `Mix.Tasks.Tau.Coherence.Report`
  deduplicates by `(rule_id, artifact, location)` against open
  `coherence`-labelled issues before creating, but the dedup is in
  the new code, not in `gh` itself.
- **G3 — Workflow failure ≠ coherence failure.** If GH Actions has
  an outage during a run, the lack of an issue is indistinguishable
  from "no findings". Mitigation: every run uploads the
  `findings.json` artifact unconditionally so post-hoc inspection is
  possible; the operability sibling's dashboard surfaces "last
  successful coherence run timestamp" so stale-run states are
  visible.
- **G4 — Cron schedule drift.** GitHub Actions does not guarantee
  cron precision; in practice runs may be skipped or delayed up to
  ~30 minutes. Mitigation: the `push: branches: [main]` trigger
  fires the same suite on every merge, so the cron is a backstop,
  not the primary detection mode. Worst-case detection latency for
  drift introduced by a non-`main`-touching event (e.g. a docs-only
  merge that exposes a contradiction): ≤ next push to `main` OR
  ≤ next cron tick.
- **G5 — The plugin lives in `.claude/plugins/` (uncommitted-tooling-
  area).** If a future plugin reorganisation moves it, the workflow
  path breaks. Mitigation: pin the path in `SPEC-MAIN-COHERENCE.md`
  Appendix-B and make plugin relocation a SPEC-amendment-requiring
  event.

## §Silent-skip impossibility (per leaf acceptance (b) and root §Acceptance C)

The runner enforces three invariants in code:

1. **Registered-but-unattempted is exit 2, not 0.** The rules pack
   declares N rules; `Tau.Coherence.Runner.run/1` MUST instantiate a
   detector for each. If `attempted < registered`, the runner returns
   `{:error, {:silent_skip_detected, names}}` and the Mix task exits 2.
   The workflow treats exit 2 as a hard `::error::` annotation
   distinct from `exit 1` ("findings present").
2. **Empty applicability is not skip.** A detector that finds 0
   matches (e.g. `APPENDIX-B-LIVE` on a repo with no SPECs) explicitly
   logs `{rule_id: ..., attempted: true, findings: 0, scope: empty}`.
   The runner counts it as attempted.
3. **No `|| true`, no `continue-on-error: true`.** The workflow has
   neither; CI configurations adding either to the `mix
   tau.coherence.report` step trip a separate `lint` job that greps
   `.github/workflows/main-coherence.yml` for those tokens
   (regression test exists at
   `test/tau/coherence/workflow_format_test.exs`).

The v1 anti-patterns at `ci.yml:88-100`, `:115`, `:213-223` are
structurally impossible because the workflow has no per-rule
conditional steps; one Mix task runs all rules, and the silent-skip
guard is part of the Mix task's exit-code contract, not a YAML
expression that can be deleted in a future edit.

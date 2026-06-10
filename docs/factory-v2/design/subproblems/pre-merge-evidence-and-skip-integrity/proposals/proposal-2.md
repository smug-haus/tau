---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Adopt-from-ecosystem — GitHub Rulesets + Actions-native required checks + Octokit/MCP-driven evidence verification

## Approach

Push the gate-infrastructure substrate onto components the GitHub /
Claude Code ecosystem already provides, and add bespoke code only where
no equivalent exists. Concretely: (1) encode the `main` branch
protection as a **GitHub Repository Ruleset** stored in
`.github/rulesets/main.json`, applied by the official
[`liatrio/github-rulesets-action`](https://github.com/liatrio/github-rulesets-action)
on every push to `main` and verified per-PR by
[`endorlabs/github-actions-policy-check`](https://github.com/marketplace/actions/policy-check-action)-style
drift-detection (drift opens a P0 issue via
[`peter-evans/create-issue-from-file`](https://github.com/peter-evans/create-issue-from-file));
(2) replace bespoke `if:` PR-body guards with **GitHub Actions matrix
jobs** that derive their applicability set from the PR diff using
[`tj-actions/changed-files`](https://github.com/tj-actions/changed-files) —
when the matrix is empty the job emits a `checked-no-applicable` Check
Run with conclusion `success` rather than skipping;
(3) wire a **`workflow-lint` required check** that runs
[`rhysd/actionlint`](https://github.com/rhysd/actionlint) plus a thin
custom `ripgrep` rule pack to reject `|| true`, `continue-on-error: true`
on jobs in the required-checks list, and any `if:` keyed on
`pr.body` / `github.event.pull_request.body` substrings; (4) verify
evidence freshness with the existing
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
running a slash command `/verify-evidence` that calls
[`anthropics/github-mcp-server`](https://github.com/github/github-mcp-server)'s
`list_workflow_runs` and `get_check_run` tools to confirm every
"evidence" link in the PR body points to a Check Run whose `head_sha`
equals the PR head, the conclusion is `success`, and the run is `<24h`
old; (5) eliminate admin merge override by setting `enforcement: active`
+ `bypass_actors: []` in the ruleset, and arm a redundant **post-merge
alarm** via [`github/branch-deploy`](https://github.com/github/branch-deploy)-
style audit hook that opens a P0 issue if any merge to `main` lands
without all required Check Runs green on its head SHA.

## Rationale

The complecting hypothesis names three knots: gate-runs↔PR-body-fields,
evidence↔location, merge↔maintainer-judgement. GitHub itself already
ships the decomplecting primitives for all three — they were under-used
in v1, not absent.

- **Rulesets-as-code** decomplects "merge eligibility" from "maintainer
  judgement": the ruleset is the single source of authority, version-
  controlled, drift-checked, and `bypass_actors: []` removes the
  human-override seam without policy hand-waving.
- **Diff-derived matrices** decomplect "gate applicability" from "PR-body
  opt-in": applicability is a function of the diff (a fact about the
  commit), not the prose (a fact about the author).
- **MCP-mediated Check Run lookup** decomplects "evidence" from
  "location": the evidence is now a typed reference (`check_run_id` with
  `head_sha` invariant) the verifier resolves through the GitHub API,
  not text the gate trusts.
- **`actionlint` + custom rule pack** decomplects "what a workflow does"
  from "what the workflow file claims it does": the `|| true` pattern,
  `continue-on-error: true` on required checks, and `if:` body-guards
  become *parseable, mechanically detectable* lint violations.

Each substitution swaps a v1 bespoke seam for an ecosystem primitive
whose semantics are independently maintained and battle-tested across
millions of repos. Failure classes #5 and #7 collapse to "did you wire
the off-the-shelf component correctly?" — a question a single
configuration-check gate can answer.

## Sketch

### A. Ruleset-as-code artifact

`.github/rulesets/main.json` (encoded; pushed by ruleset action; per-PR
drift check fails the build):

```jsonc
{
  "name": "main-branch-protection",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],                      // no admin override
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "lint",                "integration_id": 15368 },
          { "context": "test (1.18.1 · 27.2)", "integration_id": 15368 },
          { "context": "mutation-check (Gate 5.3)", "integration_id": 15368 },
          { "context": "workflow-lint",       "integration_id": 15368 },
          { "context": "evidence-verify",     "integration_id": 15368 },
          { "context": "ruleset-drift",       "integration_id": 15368 }
        ]
      }
    },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,   // factory-driven repo; agents don't approve
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "required_review_thread_resolution": true
      }
    }
  ]
}
```

### B. Diff-derived applicability matrix (replaces PR-body guards)

`.github/workflows/gate-applicability.yml`:

```yaml
name: gate-applicability
on: pull_request
jobs:
  derive:
    runs-on: ubuntu-24.04
    outputs:
      gating_tests: ${{ steps.fanout.outputs.gating_tests }}
      changed_lib_files: ${{ steps.changed.outputs.lib_files }}
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - id: changed
        uses: tj-actions/changed-files@v45
        with:
          files: |
            lib/**
            test/**
      - id: fanout
        # Pure function of the diff: gating tests = test files in the diff
        # whose @tag :gating attribute is set. No PR-body field consulted.
        run: |
          set -euo pipefail
          GATING=$(echo "${{ steps.changed.outputs.all_changed_files }}" \
            | tr ' ' '\n' \
            | grep -E '^test/.*\.exs$' \
            | xargs -r grep -l '@tag :gating' \
            | jq -R -s -c 'split("\n") | map(select(length>0))')
          echo "gating_tests=${GATING:-[]}" >> "$GITHUB_OUTPUT"

  ac-linkage:
    needs: derive
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Run AC-linkage on derived set (empty = checked-no-applicable)
        run: |
          set -euo pipefail
          mix tau.gate.ac_linkage \
            --gating-tests='${{ needs.derive.outputs.gating_tests }}' \
            --pr-number=${{ github.event.pull_request.number }} \
            --empty-set-behaviour=checked-no-applicable
          # Mix task exits 0 with explicit "checked, 0 applicable" log line
          # when set is empty. NEVER prints "skipping" and exits 0 via a guard.
```

Key invariant: the gate's `if:` is removed; the job always runs, the
mix task always emits a verdict (`pass | fail | checked-no-applicable`),
the job's exit code reflects that verdict deterministically.

### C. Workflow-lint required check (kills `|| true`, body-guards)

`.github/workflows/workflow-lint.yml`:

```yaml
name: workflow-lint
on: [pull_request, push]
jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/actionlint@v1.7.5
      - name: Custom forbidden-pattern rule pack
        run: |
          set -euo pipefail
          BAD=0
          # Anti-pattern 1: `|| true` anywhere in a workflow step
          if rg -nP '\|\|\s*true\b' .github/workflows; then
            echo "::error::|| true forbidden in workflows"; BAD=1
          fi
          # Anti-pattern 2: continue-on-error on a required-check job
          REQUIRED=$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' \
            .github/rulesets/main.json)
          for ctx in $REQUIRED; do
            if rg -nP "name:\s*[\"']?${ctx}[\"']?" .github/workflows | \
               xargs -I{} sh -c "grep -n 'continue-on-error: true' {}"; then
              echo "::error::continue-on-error: true on required check '$ctx'"; BAD=1
            fi
          done
          # Anti-pattern 3: if: keyed on PR body
          if rg -nP 'if:\s*.*github\.event\.pull_request\.body' .github/workflows; then
            echo "::error::if: guards keyed on PR body forbidden"; BAD=1
          fi
          exit $BAD
```

### D. Evidence verification via Claude Code + GitHub MCP

`.claude/agents/evidence-verifier.md` (new agent, invoked by
`anthropics/claude-code-action` on every PR `synchronize` event via the
`/verify-evidence` slash command). The agent's only tool surface is the
[`github-mcp-server`](https://github.com/github/github-mcp-server) (read
scope only). It pseudo-executes:

```text
1. body = mcp.github.get_pull_request(pr_number).body
2. links = extract_actions_run_urls(body)        # /actions/runs/<id>
3. for link in links:
     run = mcp.github.get_workflow_run(link.id)
     assert run.head_sha == pr.head_sha          # else FAIL
     assert run.conclusion == "success"
     assert now() - run.updated_at < 24h
4. forbidden = extract_local_mix_evidence(body)  # regex: "mix test", "N tests, M failures"
5. if forbidden and not links: FAIL "local-mix evidence without SHA-pinned CI run"
6. POST check-run "evidence-verify" with conclusion=success|failure and details
```

The verifier's PASS/FAIL is published as a Check Run named
`evidence-verify`, which the ruleset (block A) requires green to merge.
Bespoke surface is small: a single agent prompt + a single mix task to
parse the body. The Check Run posting, OAuth, retries, and webhook
plumbing are owned by `claude-code-action`.

### E. Ruleset-drift gate

`.github/workflows/ruleset-drift.yml` runs on every PR plus daily cron:

```yaml
- name: Diff live ruleset vs encoded
  run: |
    gh api repos/${{ github.repository }}/rulesets > /tmp/live.json
    diff <(jq -S . /tmp/live.json) <(jq -S '[.]' .github/rulesets/main.json) \
      || { echo "::error::ruleset drift"; \
           gh issue create --title "P0: main ruleset drift" \
              --body-file /tmp/drift.diff --label P0,factory-alarm; \
           exit 1; }
```

### F. Post-merge alarm (redundant safety net)

`.github/workflows/post-merge-audit.yml` on `push` to `main` invokes
`mcp.github.list_check_runs(head_sha=pushed_sha)`; if any required check
in the ruleset is `!= success`, opens a P0 issue and posts to the merged
PR. Catches the residual case where Rulesets fail open (GitHub outage,
misconfiguration).

## Tradeoffs

### Strengths

- **Maximum reuse, minimum bespoke surface.** Five of six components
  (Rulesets, `tj-actions/changed-files`, `actionlint`,
  `claude-code-action`, `github-mcp-server`,
  `peter-evans/create-issue-from-file`) are off-the-shelf and
  independently maintained. Bespoke surface is one `actionlint` rule
  pack, one verifier agent prompt, and the existing `mix tau.gate.*`
  tasks reshaped to fail-loud on infrastructural failure. Satisfies
  root §Acceptance D (ecosystem reuse over reinvention).
- **Silent-skip impossibility is a property of the wiring, not a
  convention.** No `if:` guards keyed on PR-body fields exist (gate C
  forbids them); applicability is the empty matrix (gate B) and the
  empty-set verdict is `checked-no-applicable`, a first-class outcome.
  Satisfies leaf §Acceptance (a) and root §Acceptance C.
- **Evidence is SHA-pinned by construction.** A Check Run is a typed
  artifact bound to a commit; the verifier compares two SHAs and the
  conclusion field. There is no text-parsing of local mix output, so
  the "paste output verbatim" attack surface vanishes (root #7).
  Satisfies leaf §Acceptance (d).
- **Admin override is removed, not just discouraged.** `bypass_actors:
  []` plus ruleset-drift detection plus post-merge alarm form a
  defence-in-depth against the v1 collapse mode where four PRs merged
  red. Satisfies leaf §Acceptance (c).
- **Versioned ruleset is auditable.** `.github/rulesets/main.json` is
  reviewable in a PR like any other artifact, and the drift gate
  surfaces unauthorised UI changes within 24h.
- **MCP servers are the canonical Claude-Code-to-GitHub bridge.** The
  `github-mcp-server` is Anthropic-published and already supports the
  `list_workflow_runs` / `get_check_run` tools needed; we add no new
  trust surface to the agent loop.

### Weaknesses

- **Repository Rulesets API is newer than classic Branch Protection
  and its drift surface is poorly documented.** Some fields (`integration_id`
  for app-owned checks) require a GitHub App ID lookup the proposal
  hand-waves; a half-day spike is needed to confirm the JSON shape and
  the `gh api` round-trip is lossless. If the round-trip is lossy,
  drift detection produces false positives that desensitise the alarm.
- **`tj-actions/changed-files` had a security incident in March 2025
  (CVE-2025-30066, malicious mutation of a tag).** Proposal pins by
  commit SHA, not tag, and adds a `step-security/harden-runner` audited
  egress allow-list — this is mitigation, not elimination, and we
  inherit ongoing supply-chain risk on every dep.
- **`claude-code-action` introduces a recurring agent loop with token
  cost on every PR `synchronize`.** Evidence verification is cheap
  (≤4 API calls) but the OAuth + webhook plumbing means a measurable
  per-PR token spend. Cheap, but not free.
- **The "evidence-verifier" is itself a Claude agent.** The root spec
  warns "Where Claude is in the loop, Claude's claims must be cross-
  checked by mechanism." Mitigation: the agent only consumes MCP tool
  output (typed) and emits a Check Run conclusion (typed) — its prose
  is not load-bearing. Still, the agent's prompt is a soft spot a
  hostile contributor could attempt to inject via PR body. A separate
  deterministic mix task (no LLM) running the same checks would close
  this; proposal punts it to "phase 2 hardening."
- **Doesn't solve "the meta-gate must itself not silent-skip".** The
  `workflow-lint` job is required by the ruleset, but if a contributor
  removes `workflow-lint` from the required list in `.github/rulesets/
  main.json`, the drift gate must catch it on that same PR. We rely on
  the drift gate to require its own presence; this is a fixed point
  the proposal asserts but does not prove.
- **MCP server availability is a runtime dependency.** A
  `github-mcp-server` outage blocks `evidence-verify`; the Check Run
  must then time out and post `failure`, NOT `neutral` or skip — the
  agent's prompt must hard-code this.
- **No CODEOWNERS-style policy-as-code for in-repo rules.** OPA /
  conftest would be a stronger fit but adds a runtime; we accept the
  weaker `actionlint` + ripgrep rule pack as the pragmatic floor.

### Costs

- **Implementation: ~5-8 PRs.** (1) ruleset JSON + apply action;
  (2) drift gate; (3) workflow-lint job + custom rule pack;
  (4) gate-applicability refactor of `gate-applicability.yml`
  replacing the existing `if:` guards in `ci.yml:78,108,175`;
  (5) `mix tau.gate.*` reshape for `--empty-set-behaviour=checked-no-applicable`;
  (6) evidence-verifier agent + Claude Code Action wiring;
  (7) post-merge audit workflow; (8) decommission v1 `|| true` and
  silent-skip branches.
- **Dependency footprint adds:** `liatrio/github-rulesets-action`,
  `rhysd/actionlint`, `tj-actions/changed-files` (SHA-pinned),
  `peter-evans/create-issue-from-file`, `anthropics/claude-code-action`,
  `github/github-mcp-server`, `step-security/harden-runner`. Six new
  Actions, one MCP server. All have >1k stars and active maintenance
  as of 2026-05.
- **CI minutes:** ~+90s per PR (workflow-lint ~10s, drift ~5s,
  applicability derivation ~15s, evidence-verify ~30-60s including
  MCP round-trips). Acceptable on the ubuntu-24.04 runner profile.
- **Token cost:** evidence-verifier ≈ 1-3k tokens per PR
  `synchronize`. At current PR cadence, ~$1-3/month.
- **Knowledge cost:** team must learn Repository Rulesets JSON schema
  (one-time) and the changed-files SHA-pinning policy (ongoing).
- **Migration cost on existing PRs:** the three `if:`-guarded gates in
  v1 `ci.yml` must be rewritten in one atomic PR; mid-flight PRs need
  rebase. Per worktree-discipline, this means a brief loop freeze.

## Dependencies

- GitHub Repository Rulesets API GA on the org (confirmed available
  as of 2025; org-level enforcement may require admin coordination).
- `anthropics/claude-code-action` GitHub App installed on the repo
  with `pull_requests:read`, `checks:write`, `issues:write` scopes.
- `github/github-mcp-server` reachable from the Claude Code agent
  loop; OAuth or PAT credentials provisioned as a repo secret.
- `mix tau.gate.ac_linkage`, `mix tau.gate.masking`, `mix tau.gate.
  mutation` reshaped to accept `--empty-set-behaviour` and emit
  structured verdicts on stdout (small change, ≤50 LoC each).
- Decision on `tj-actions/changed-files` vs Anthropic-vendored
  changed-files action — preference for the latter if it materialises;
  fallback is SHA-pinning plus `harden-runner` egress allow-list.
- Sibling **operability-and-hygiene-enforcement** leaf's dashboard
  consumes the new Check Run names (`workflow-lint`, `evidence-verify`,
  `ruleset-drift`, `post-merge-audit`); coordinate naming before
  landing.

## Confidence

**Medium-high.** GitHub Rulesets, `actionlint`, `tj-actions/changed-files`,
`claude-code-action`, and `github-mcp-server` are all production-grade
with public adopters; the wiring is bookkeeping. The principal unknowns
are (1) Repository Rulesets JSON round-trip fidelity (needs a
half-day spike — would raise to high) and (2) whether MCP round-trip
latency stays within the `evidence-verify` time budget on cold-start.
A bespoke deterministic mix task fallback for evidence verification is
prepared if the MCP-based path proves flaky.

## Prior art / references

- GitHub Repository Rulesets — https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- `liatrio/github-rulesets-action` — apply rulesets-as-code on push to default branch
- `rhysd/actionlint` — battle-tested workflow YAML static analysis (>3k stars)
- `tj-actions/changed-files` — diff-derived matrix builder; CVE-2025-30066 informs SHA-pin policy
- `peter-evans/create-issue-from-file` — programmatic P0 issue creation for drift / audit alarms
- `anthropics/claude-code-action` — Claude Code GitHub App with `/`-command surface, runs in CI under repo secrets
- `github/github-mcp-server` — Anthropic-/GitHub-published MCP server exposing typed Check Run / Workflow Run lookup
- `step-security/harden-runner` — egress-control hardening for supply-chain mitigation
- Open Policy Agent / `conftest` — considered for in-repo policy as code; rejected as heavier than `actionlint`+ripgrep for the v2 scope (revisit if rule pack exceeds ~30 rules)
- Tau v1 `ci.yml` anti-patterns at `ci.yml:88-100`, `:115`, `:213-223` — proposal's negative reference points

---

## Adoption-vs-build summary (per root §Acceptance D)

| Capability | Decision | Component | Bespoke surface |
|---|---|---|---|
| Branch protection encoding | **Adopt** | GitHub Repository Rulesets | `main.json` (config) |
| Ruleset application | **Adopt** | `liatrio/github-rulesets-action` | — |
| Ruleset drift detection | **Adopt+thin glue** | `gh api` + `peter-evans/create-issue-from-file` | ~30 lines YAML |
| Workflow YAML lint | **Adopt** | `rhysd/actionlint` | — |
| Forbidden-pattern rule pack (`\|\| true`, body-guards) | **Build** | ripgrep rule pack | ~40 lines bash (no ecosystem equivalent) |
| Diff-derived gate applicability | **Adopt** | `tj-actions/changed-files` (SHA-pinned) | matrix fan-out YAML |
| Empty-set "checked-no-applicable" verdict | **Build** | `mix tau.gate.* --empty-set-behaviour` | ~150 LoC across 3 mix tasks |
| PR-body evidence verification | **Adopt+thin glue** | `claude-code-action` + `github-mcp-server` | one agent prompt + one mix task |
| Post-merge red-CI alarm | **Adopt+thin glue** | `github-mcp-server` + `create-issue-from-file` | ~40 lines YAML |
| Admin-override removal | **Adopt** | Rulesets `bypass_actors: []` | — |

Bespoke totals: ~260 LoC + 1 agent prompt + 1 config JSON. The rest is
configuration of well-maintained external components. Proposal satisfies
root §Acceptance D by adopting where ecosystem coverage exists, and
documents per-component justification where it does not.

## Gaps and open questions

- **Ruleset JSON round-trip fidelity** — half-day spike required. If
  `gh api repos/.../rulesets` does not round-trip to byte-identical
  JSON, drift detection needs a semantic differ (jq-based normalisation)
  rather than `diff`.
- **MCP `github-mcp-server` cold-start latency** — must be measured
  under load; fallback is a bespoke `gh api`-based mix task.
- **Anthropic-vendored alternative to `tj-actions/changed-files`** — if
  available by 2026-Q3, swap and drop `harden-runner` mitigation.
- **CODEOWNERS-style policy-as-code** — deferred to a later phase if
  the bespoke rule pack grows beyond ~30 rules; OPA/conftest noted as
  the upgrade path.
- **Cross-PR coherence (e.g., two PRs both touching `ci.yml`)** —
  out of scope for this leaf; handed off to **post-merge-cross-
  artifact-coherence** sibling.

## Build-order — adopt first, glue second, bespoke last

Sequencing favours adoption: lowest-risk-highest-leverage components
land first, bespoke code only after the adopted substrate is proven.

1. **(adopt)** `.github/rulesets/main.json` encoded + applied via
   `liatrio/github-rulesets-action`; `bypass_actors: []`,
   `required_linear_history`. Removes admin merge override on day 1.
2. **(adopt)** `workflow-lint` job running `actionlint` only; surfaces
   pre-existing YAML errors. Added as a required check in the ruleset.
3. **(adopt+glue)** `ruleset-drift` job; `peter-evans/create-issue-from-file`
   for the P0 alarm. Made required.
4. **(bespoke)** Add the ripgrep rule pack to `workflow-lint` for
   `|| true`, `continue-on-error: true`, and PR-body `if:` guards. Run
   in audit-mode for one PR cycle, then switch to required-blocking.
5. **(adopt+bespoke)** Refactor `mix tau.gate.*` tasks to emit
   `checked-no-applicable` on empty input; replace `if:` guards in
   `ci.yml:78,108,175` with always-on jobs whose applicability comes
   from `tj-actions/changed-files`-derived matrices. Atomic PR;
   coordinate with worktree-discipline brief.
6. **(adopt+glue)** Wire `anthropics/claude-code-action` with the
   `evidence-verifier` agent + `github-mcp-server` MCP server; post
   `evidence-verify` Check Run. Required in the ruleset only after
   shadow-mode confirms <1% false-positive rate over 10 PRs.
7. **(adopt+glue)** `post-merge-audit.yml`; redundant safety net for
   any path that bypasses Rulesets.
8. **(bespoke, deferred)** Replace agent-driven `evidence-verify` with
   a deterministic `mix tau.gate.evidence_check` if cold-start latency
   or prompt-injection surface justifies it.

Each step is one PR per the factory loop; each PR strengthens the
substrate before the next layer relies on it. No bespoke code lands
before its adopted scaffold.

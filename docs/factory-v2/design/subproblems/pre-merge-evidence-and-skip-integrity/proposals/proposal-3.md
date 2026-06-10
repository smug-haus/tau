---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: SLSA-style signed build provenance with a merge queue and policy-as-code admission controller

## Approach

Replace PR-body-driven gate selection and human-judged merge eligibility with
a three-layer admission pipeline whose model is taken wholesale from the
software-supply-chain world: (1) **provenance** — every gate produces a signed,
SHA-pinned attestation (in-toto / SLSA v1.0 statement) emitted by the CI
runner and stored as a transparency-log entry (sigstore Rekor or an
equivalent append-only log committed to a `attestations/` orphan branch); (2)
**policy-as-code admission** — a single `policy-controller` job (modelled on
Sigstore's `policy-controller` for Kubernetes, or `conftest`/OPA Rego over
admission input) consumes the diff, the attestation set, and the repo state,
and emits one verdict the branch-protection ruleset requires; the policy
enumerates the *required* attestations as a function of `diff∩repo`, never as
a function of the PR body; (3) **merge queue** — GitHub Merge Queue (or a
Bors-style queued merger) is the only path that updates `main`, configured
with `require_branches_to_be_up_to_date=true` and `required_status_checks =
{policy-controller}`. The policy-controller job replays the diff against the
admission rules, and an attestation absent for an applicable rule fails the
queue entry; no PR-body field controls anything. Branch-protection rulesets
themselves are encoded as Terraform/`gh-rulesets` HCL and a separate
"ruleset-drift" workflow gates the policy on `main` against the live ruleset
returned by `gh api repos/.../rulesets`.

## Rationale

The complecting hypothesis (problem §Complecting) names three braids:
gate-runs ↔ PR-body-opt-in; evidence-validity ↔ where-run; merge-eligibility ↔
maintainer-judgement. SLSA/in-toto separates *what was built/checked* from
*who claims it*: the attestation is a typed, signed payload whose subject is
the head SHA and whose predicate is the check result. The policy-controller
separates *which checks are required* from *who declared they were required*:
the policy is a versioned file in the repo, evaluated by an OPA-style engine
over the diff. The merge queue separates *PR-is-mergeable-now* from
*human-clicks-merge*: a queue entry must pass the policy against the merge
candidate's actual tree (rebased onto current `main`), not against the PR's
historical head SHA. The three layers compose: provenance fixes #7's
local-mix-evidence rot, policy fixes #5's silent-skip, and the queue fixes
#7's red-CI-merge — without any of the three trusting the PR author or the
maintainer.

## Sketch

### Layer 1 — Provenance (every gate emits a signed attestation)

Each gate job ends with an attestation step. We use the standard
`actions/attest-build-provenance@v2` (sigstore-backed) and a custom
attestation type for gate verdicts:

```yaml
# .github/workflows/gates.yml — illustrative gate-runner shape
jobs:
  gate-ac-linkage:
    runs-on: ubuntu-24.04
    permissions:
      id-token: write   # for sigstore OIDC
      attestations: write
      contents: read
    outputs:
      verdict: ${{ steps.run.outputs.verdict }}
    steps:
      - uses: actions/checkout@v4
      - id: run
        run: mix tau.gate.ac_linkage --json > gate-ac-linkage.json
      - uses: actions/attest@v2
        with:
          subject-path: gate-ac-linkage.json
          predicate-type: https://tau.dev/attestations/gate-verdict/v1
          predicate: gate-ac-linkage.json
```

Predicate shape (in-toto statement, predicate field):

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [{"name": "head", "digest": {"sha1": "<commit-sha>"}}],
  "predicateType": "https://tau.dev/attestations/gate-verdict/v1",
  "predicate": {
    "gate_id": "ac-linkage",
    "gate_version": "1.4.0",
    "verdict": "pass" | "fail" | "not_applicable",
    "applicable_inputs": ["AC-B6", "D-090"],
    "checked_at": "2026-05-23T...",
    "runner": {"workflow_run_id": 12345, "head_sha": "<sha>"}
  }
}
```

A `not_applicable` verdict is a first-class, signed value — there is no
"didn't run". Sigstore Rekor (public log) and a repo-local
`refs/attestations/<sha>` ref both retain the bundle; the policy step
verifies the signature against the GitHub OIDC issuer keyed to this repo.

### Layer 2 — Policy-as-code admission controller

A single required status check `policy-controller` runs Rego over an input
document. The required-attestation set is *derived* from the diff and repo
state, not from the PR body:

```rego
# policy/admission.rego  (OPA / Rego)
package tau.factory.admission

default allow := false

# Derive required gate IDs from the diff (no PR-body inputs)
required_gates contains gid if {
    some path in input.diff.changed_files
    rule := data.gate_rules[_]
    glob.match(rule.path_glob, [], path)
    gid := rule.gate_id
}

# A gate is satisfied iff a fresh, signed, head-SHA-pinned attestation exists
satisfied(gid) if {
    some att in input.attestations
    att.predicate.gate_id == gid
    att.subject_sha == input.head_sha
    att.signature.verified == true
    att.predicate.verdict != "fail"
}

allow if {
    every gid in required_gates { satisfied(gid) }
    not input.ci_red                    # head SHA's required-check set is green
    input.head_sha == input.queue_target_sha   # merge-queue rebased candidate
}

# Reasons surfaced when allow=false
deny[msg] if {
    some gid in required_gates
    not satisfied(gid)
    msg := sprintf("missing attestation for gate %q", [gid])
}
```

`data.gate_rules` is the in-repo registry mapping path globs to gate IDs;
adding a gate means a PR to this file (itself attested):

```yaml
# policy/gate_rules.yml
- gate_id: nn7-rescue-purity
  path_glob: "lib/**/*.ex"
  description: "OTP NN#7 — no try/rescue across process boundary"
- gate_id: capability-flag-fidelity
  path_glob: "lib/tau/providers/**/*.ex"
  description: "prompt_caching:true ⇒ cache_regions/2 exported"
- gate_id: ac-linkage
  path_glob: "**/*"
  description: "AC-N/D-NNN tokens claimed ⇒ linked test"
```

The controller job:

```yaml
policy-controller:
  needs: [gate-ac-linkage, gate-nn7-rescue-purity, gate-capability-flag, ...]
  if: always()    # MUST run even when a needed job fails
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@v4
    - uses: actions/download-attestations@v2
      with: { subject-sha: ${{ github.event.pull_request.head.sha }} }
    - run: |
        # Build input document
        jq -n \
          --slurpfile atts attestations/*.intoto.jsonl \
          --arg head "${{ github.event.pull_request.head.sha }}" \
          --arg target "${{ github.event.merge_group.head_sha || github.event.pull_request.head.sha }}" \
          --argjson red "$(gh api repos/${{github.repository}}/commits/$head/check-runs --jq '[.check_runs[]|select(.conclusion=="failure")]|length>0')" \
          '{attestations:$atts,head_sha:$head,queue_target_sha:$target,ci_red:$red,diff:{changed_files:$ENV.CHANGED|split("\n")}}' \
          > policy-input.json
        conftest verify --policy policy/ --data policy/gate_rules.yml policy-input.json
```

### Layer 3 — Merge queue is the only path to `main`

Branch-protection ruleset (encoded; live ruleset diffed by `ruleset-drift`
job):

```hcl
# infra/branch_protection.tf
resource "github_repository_ruleset" "main" {
  name = "main"
  target = "branch"
  enforcement = "active"
  conditions {
    ref_name { include = ["~DEFAULT_BRANCH"] }
  }
  rules {
    required_status_checks {
      required_check { context = "policy-controller" }
      strict_required_status_checks_policy = true
    }
    required_linear_history = true
    deletion = true
    non_fast_forward = true
    merge_queue {
      merge_method = "MERGE"
      min_entries_to_merge = 1
      max_entries_to_merge = 1            # serialized — matches factory-loop
      max_entries_to_build = 3
    }
  }
  bypass_actors = []                       # NO admin override
}
```

A separate `ruleset-drift` workflow runs on every PR and on cron:

```yaml
ruleset-drift:
  runs-on: ubuntu-24.04
  steps:
    - uses: actions/checkout@v4
    - run: |
        terraform -chdir=infra plan -detailed-exitcode -out=tfplan
        # exit 2 = drift; exit 0 = no drift; exit 1 = error
        # 2 fails the check; the policy-controller requires this check.
```

### Local-mix evidence detector

A small gate that scans the PR body / commit messages and fails on any
"evidence" string lacking a corresponding attestation:

```elixir
# mix tau.gate.evidence_provenance
# Fails if PR body contains "mix test" output, "X tests, Y failures",
# "assert ... passed", "compiled successfully" etc., AND no
# attestation has predicate.gate_id matching a CI-run that
# produced equivalent output for the head SHA.
```

This gate itself emits an attestation and is in `policy/gate_rules.yml`.

## Tradeoffs

### Strengths

- **Silent-skip is structurally impossible (acceptance §a).** The
  policy-controller's `required_gates` is computed from the diff and repo,
  not from the PR body; "I didn't declare it" is not a thing the policy can
  observe. A missing attestation deterministically denies admission. A
  legitimately-not-applicable gate emits a signed `not_applicable`
  attestation — auditable, distinct from absent.
- **Evidence-where-run is locked to CI head-SHA (acceptance §d).** Sigstore
  OIDC binds each attestation's signing identity to the GitHub Actions
  workflow run on the actual head SHA; an attestation produced on a laptop
  has no valid signing key chain to this repo's OIDC issuer. PR-body text
  is irrelevant to the policy.
- **Red-CI merge structurally impossible (acceptance §c).** Merge queue
  rebases the candidate onto current `main` and re-runs required checks;
  the `policy-controller` reads live CI state (`ci_red`) and denies. The
  ruleset has `bypass_actors = []` and `required_linear_history`; the
  ruleset-drift job blocks any PR that mutates these fields without an
  attested ADR.
- **Meta-gate "no `|| true`, no PR-body-keyed `if:`" is unnecessary by
  construction (acceptance §b).** The policy doesn't read `if:` guards; it
  reads attestations. A workflow that silently no-ops produces no
  attestation, the policy denies, the queue refuses. (We still ship a
  `lint-ci` job that scans `.github/workflows/*.yml` for `|| true` and
  `continue-on-error: true` on required checks, because it's cheap defense
  in depth — but it is not load-bearing.)
- **Reuse over reinvention (root §Acceptance D).** All four core
  components are ecosystem standards: SLSA v1.0 attestation predicates,
  in-toto statement format, Sigstore/Rekor transparency log, OPA Rego,
  GitHub Merge Queue, Terraform/`gh-rulesets`. The bespoke surface is the
  Tau-specific gate-verdict predicate type and the gate-rule registry —
  ~200 lines of YAML + Rego.
- **Cross-PR coherence is free.** Because attestations are SHA-pinned and
  persisted to Rekor / `refs/attestations/`, downstream coherence checks
  (sibling leaf `post-merge-cross-artifact-coherence`) get a queryable
  attestation history without re-instrumenting.

### Weaknesses

- **Operational surface area is large.** Sigstore OIDC, Rekor, OPA, merge
  queue, Terraform-managed branch protection, attestation predicate schema
  — five infrastructure dependencies. Each is robust on its own; together
  they demand a maintainer who understands the chain. A toolchain-down
  day on any of the five blocks all merges.
- **First-PR bootstrap problem.** The policy-controller itself is encoded
  in the repo and gated by itself. Bootstrapping requires a one-time
  admin push that *adds* the controller + initial gate registry; this push
  is by definition unattested. Mitigation: a signed tag + a public ADR; but
  the bootstrap window is a known trust hole.
- **Policy authorship is a new skill on the team.** Rego is a small DSL but
  it is a DSL; the maintainer who edits `gate_rules.yml` must also
  understand `policy/admission.rego` to add a new gate type. This is a
  shift from "edit a workflow YAML" to "edit policy + workflow + predicate
  schema."
- **Latency cost.** Each gate adds a sigstore signing round-trip (~1-3 s)
  and a Rekor inclusion proof (~2-5 s). For ~10 gates per PR, this is
  ~30-50 s of additional pre-merge latency. Acceptable for Tau's PR cadence
  (small team, few PRs/day) but would be noticeable in a hot monorepo.
- **Merge queue serializes throughput.** `max_entries_to_merge=1` matches
  the factory-loop's serialized-merge invariant but eliminates any
  throughput from parallelism gains. The factory's parallel-implementer
  phase is unaffected; only the merge gate serializes.
- **OIDC signing identity scope.** Sigstore's OIDC binds to the workflow
  *repository*, not to the workflow file path. A malicious workflow file
  added to the repo could produce attestations the policy accepts. Defense:
  pin policy-controller to `workflow_ref` allowlist (`tau-dev/tau/.github/
  workflows/gates.yml@refs/heads/main` only); but this allowlist is itself
  policy and must be reviewed.

### Costs

- **Initial infra build:** ~2-3 PRs of work (proposal-2's mix-task layer
  reused; new layers are Terraform, Rego policy, attestation-emit GHA
  steps, merge-queue ruleset). Estimate ~600-900 LoC across `policy/`,
  `infra/`, and workflow YAML.
- **Per-gate addition cost:** add a YAML entry to `gate_rules.yml`, a Rego
  function `satisfied/1` extension only if the gate has a non-standard
  shape, and a workflow `attest` step. ~30 LoC per new gate.
- **CI cost:** +30-50 s per PR (sigstore + Rekor); +1 OPA job (~5 s); +1
  ruleset-drift job (~10 s with cached `terraform init`). Net ~+1 min per
  PR.
- **Bootstrap one-time cost:** an admin push to seed the controller, with a
  matching signed-tag ADR; ~half a day including writing the bootstrap ADR
  and verifying drift detection fires correctly.
- **Knowledge cost:** team learns Rego (small), in-toto predicate shape
  (small), sigstore verification (small). Each is documented, but the
  total is non-trivial vs proposal-2's "all Elixir mix tasks."
- **Test surface:** new property tests for the Rego policy (Conftest has a
  built-in test harness), new contract tests for the attestation predicate
  schema. Estimate 30-50 properties/tests.

## Dependencies

- GitHub Merge Queue (GA since 2023; available on Tau's plan).
- Sigstore Cosign / `actions/attest@v2` (GA; in production at major OSS
  projects — Kubernetes, npm registry signing).
- OPA / Conftest (CNCF graduated; widely deployed).
- Terraform `integrations/github` provider ≥ v6 (rulesets support).
- A repository orphan branch `refs/attestations/` OR reliance on Rekor +
  GitHub attestations API. Recommend both for redundancy.
- The mix-task layer from proposal-2 (each gate emits structured JSON; the
  attestation step wraps it).
- ADR-NNN authorising the bootstrap push (one-time unattested admin push;
  recorded as a known trust hole closing once policy-controller is live).

## Confidence

**Medium-high.** The pattern is in production at scale: Kubernetes uses
Sigstore policy-controller for admission; npm uses sigstore for package
provenance; the SLSA framework is the reference model for "did this artifact
come from a trusted build." The translation to "did this PR pass its required
checks" is direct: the PR is the artifact, the policy is the consumer.
Confidence would be **high** with a 1-week prototype proving (a) sigstore
OIDC attests on a private repo Tau-equivalent, (b) Rego admission rejects a
PR with a missing attestation, (c) merge queue refuses an entry when
`policy-controller` is red. The unknowns are operational (Rekor latency
percentiles, sigstore key-rotation handling), not architectural.

## Prior art / references

- **SLSA v1.0 — Supply-chain Levels for Software Artifacts.**
  `https://slsa.dev/spec/v1.0/` — defines "provenance" as a signed attestation
  binding an artifact (here: PR head SHA) to the process that produced it. The
  policy-controller is a SLSA Level 3 verifier.
- **in-toto Attestation Framework.**
  `https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md` —
  the `_type: Statement/v1` predicate schema is what each Tau gate emits.
- **Sigstore policy-controller (Kubernetes admission).**
  `https://github.com/sigstore/policy-controller` — direct conceptual analog:
  Kubernetes refuses to admit a Pod whose image lacks the required signed
  attestations. Tau refuses to admit a PR whose head SHA lacks the required
  signed gate-verdict attestations.
- **OPA / Conftest for policy-as-code admission.**
  `https://www.openpolicyagent.org/` and `https://www.conftest.dev/` —
  Rego is the policy language; Conftest the test harness. Used in Kubernetes
  admission, Terraform plan gating (Hashicorp Sentinel's open analog), and
  Spinnaker pipeline gating.
- **GitHub Merge Queue + branch-protection rulesets.**
  `https://docs.github.com/en/repositories/configuring-branches-and-merges-
  in-your-repository/configuring-pull-request-merges/managing-a-merge-queue`
  — Microsoft's monorepo (Windows / 1ES) and the `rust-lang/rust` Bors
  workflow are the longest-running production references. The queue's
  rebase-and-reverify behaviour is what kills the "merged against stale
  green" failure mode.
- **Bors / homu (Rust, Servo) and Kafka MergeQueue (LinkedIn).**
  `https://graydon2.dreamwidth.org/1597.html` (Graydon Hoare on "the not
  rocket science rule") — the canonical statement that "the master branch
  must always be green" requires a queued merger that tests the post-merge
  candidate, not the pre-merge PR head.
- **`benchmark-action/github-action-benchmark` and `actions/attest-build-
  provenance`** — concrete GHA building blocks; the latter is the GA
  attestation emitter used by the npm registry's provenance program.
- **Phabricator's Herald rules + Differential audits.** The historical model
  for "the policy that decides whether a diff lands is itself a versioned
  artifact in the repo, not maintainer judgement." Less directly applicable
  (Phabricator is sunsetted) but the conceptual lineage of policy-as-code
  admission to a trunk traces here.
- **Gerrit's label/voting model (`Code-Review +2`, `Verified +1`).** Gerrit
  separates *who claims* (label authors) from *what the label means* (project
  config). The translation to attestation predicates is direct: a `Verified`
  vote is a SLSA gate-verdict attestation under a different name; Gerrit's
  `submit-requirements` are Rego rules under a different syntax.
- **Bazel remote-execution build attestations / SLSA generator.**
  `https://github.com/slsa-framework/slsa-github-generator` — the reference
  GitHub-Action implementation of SLSA L3 provenance. The Tau gate-verdict
  predicate is a domain-specific extension of the same model.

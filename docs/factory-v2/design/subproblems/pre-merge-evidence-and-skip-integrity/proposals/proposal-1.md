---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Verdict-Bus — a signed, SHA-pinned verdict ledger driving merge eligibility

## Approach

Re-derive the gate-execution substrate from first principles. The
substrate has exactly one purpose: turn the question "may this PR
merge?" into a deterministic function of (head SHA, repo state, a set
of *signed verdicts*). Every gate becomes a producer that emits a
signed `Verdict` record into a single append-only ledger called the
**Verdict-Bus**. Merge eligibility is computed by a separate `Admittor`
component that reads only the ledger plus the diff, and never reads PR
body text. Applicability of every gate is computed from the diff and
the repo state — not from PR-body fields. Anything that today silent-
skips becomes either a `Verdict{status: :n_a, applicable_inputs: []}`
(explicit, signed, ledgered) or a `Verdict{status: :infra_fail}` which
the Admittor treats as a merge-blocking failure. `|| true`,
`continue-on-error`, and "PR-body opt-in" become syntactically
unrepresentable because no component in the substrate consumes PR-body
text and no verdict producer's exit status is consulted — only the
signed record it writes.

## Rationale

The leaf's complecting hypothesis names three couplings: gate-runs vs.
PR-body opt-in; evidence vs. where-it-ran; merge-eligibility vs.
maintainer-judgement. A Verdict-Bus decomplects all three by routing
every gate-runtime decision through one narrow contract:
`Verdict := {gate_id, head_sha, applicable_inputs, status, evidence_ref,
producer_identity, signature}`. The diff alone determines
`applicable_inputs` (decomplecting gate-runs from PR body). The
signature alone determines whether evidence is trusted (decomplecting
evidence from origin — a laptop-produced verdict cannot be signed by
the CI signer). The Admittor alone, reading only the ledger, determines
merge eligibility (decomplecting eligibility from human judgement;
admin override becomes a separate, alarmed event-class rather than a
silent path). The Admittor's input is a *set*; absence of a required
verdict is itself a deterministic block. There is nowhere a `|| true`
can hide because the producer's exit code is not the eligibility
signal — the signed record is.

## Sketch

### Components

```
+----------------------+         +------------------------+
| Applicability        |         | Gate Producers         |
| Oracle               |         | (one per gate-id)      |
| - inputs: diff,      |         | - read: applicable     |
|   repo tree          |  ---->  |   inputs from Oracle   |
| - emits: per-gate    |         | - run check            |
|   applicable_inputs  |         | - sign + POST verdict  |
+----------------------+         +------------------------+
            \                              |
             \                             v
              \                +----------------------+
               \------->       | Verdict-Bus          |
                               | (append-only ledger; |
                               |  one row per         |
                               |  {gate_id, head_sha})|
                               +----------------------+
                                          |
                                          v
                               +----------------------+
                               | Admittor             |
                               | - reads ledger +     |
                               |   gate registry      |
                               | - emits merge-       |
                               |   eligibility        |
                               |   verdict (also      |
                               |   signed, ledgered)  |
                               +----------------------+
                                          |
                                          v
                               +----------------------+
                               | Branch-protection    |
                               | Required Check       |
                               | (only one required   |
                               |  check exists:       |
                               |  "admittor")         |
                               +----------------------+
```

### Data shapes

```elixir
defmodule Tau.Factory.Verdict do
  @enforce_keys [:gate_id, :head_sha, :applicable_inputs, :status,
                 :evidence_ref, :producer_identity, :signature, :emitted_at]
  defstruct [:gate_id, :head_sha, :applicable_inputs, :status,
             :evidence_ref, :producer_identity, :signature, :emitted_at,
             :findings, :tool_version, :runtime_env_digest]

  @type status ::
          :pass            # check ran, all applicable inputs satisfied
          | :fail          # check ran, ≥1 applicable input violated
          | :n_a           # check ran, applicable_inputs == [];
                           # explicitly "checked, 0 applicable"
          | :infra_fail    # check could not run; merge-blocking
end

defmodule Tau.Factory.GateRegistry do
  @type t :: %{required(gate_id :: atom) =>
                 %{producer: module,
                   applicability: module,
                   required: boolean,
                   public_key: binary}}
end

defmodule Tau.Factory.Admittor do
  @callback decide(head_sha :: binary, ledger :: [Verdict.t]) ::
              {:merge, AdmittorVerdict.t} | {:block, AdmittorVerdict.t}
end
```

### Per-component contracts

- **Applicability Oracle** (`mix tau.factory.applicability <head_sha>`).
  Pure function over `(diff, repo_tree)`. For every registered gate,
  emits the set of files / AST nodes / symbols the gate is responsible
  for. Output is JSON, content-addressed, signed by the Oracle's key.
  The Oracle never reads `.github/PULL_REQUEST_TEMPLATE`, never reads
  the PR body, never reads commit messages. Determinism is verified by
  the Self-Check Gate (below).

- **Gate Producers**. Each gate is a separate workflow job that
  (1) fetches the Oracle's signed applicability record for its
  `gate_id`, (2) runs the check across that input set, (3) constructs a
  `Verdict`, (4) signs it with the producer's key (held in GitHub
  Actions OIDC-issued short-lived cert — see §Build-order step 3),
  (5) POSTs to the Verdict-Bus. Exit status of the workflow job is
  *informational only*; the only signal the Admittor reads is the
  signed `Verdict` in the ledger. A producer that crashes mid-run emits
  no verdict; the Admittor treats absence as `:infra_fail` after
  timeout (see Admittor contract).

- **Verdict-Bus**. Append-only store keyed by `{gate_id, head_sha}`,
  unique on that pair. Implementation: a `verdicts/` directory in a
  dedicated branch (`refs/factory/verdicts`) of the repo itself, one
  JSON file per verdict, force-push disabled by branch-protection.
  Rationale for using a git ref rather than an external service:
  zero new infrastructure to operate, every verdict cryptographically
  pinned to the repo's hash chain, queryable with `git`. Writers are
  authenticated by signature verification at push time (a server-side
  pre-receive hook on the verdict branch — implemented as a required
  status check on that branch itself; the branch's only writer is the
  CI signer). Readers are unrestricted.

- **Admittor** (`mix tau.factory.admit <head_sha>`). Reads the gate
  registry and the verdicts for `head_sha`. Emits `:merge` iff:
    1. For every `required: true` gate in the registry, exactly one
       verdict exists with `head_sha == head_sha` and signature verified
       against that gate's registered public key.
    2. Every such verdict's `status` is `:pass` or `:n_a`.
    3. The verdict's `applicable_inputs` set equals what a re-run of
       the Applicability Oracle on the same `head_sha` would emit
       (deterministic-Oracle invariant — caught by the Self-Check Gate).
  Else emits `:block` with a per-rule explanation. The Admittor's
  verdict is itself a signed `Verdict` written to the Bus under
  `gate_id: :admittor`. The single GitHub branch-protection required
  status check on `main` is named `admittor` and is satisfied iff the
  Admittor's most-recent verdict for the PR's head SHA has
  `status: :pass`.

- **Self-Check Gate** (`mix tau.factory.gate.self_check`). A producer
  like any other; emits a `Verdict{gate_id: :self_check, ...}`.
  Parses every YAML under `.github/workflows/`, fails on any of:
  `|| true` after a step that produces evidence, `continue-on-error:
  true` on any job referenced by the gate registry, `if:` expressions
  matching `contains(github.event.pull_request.body, …)` or any other
  PR-body predicate, any `actions/checkout` with `persist-credentials:
  true` on a verdict-producer job (signing must use OIDC, not
  repo-scoped tokens). Also: re-runs the Applicability Oracle and
  asserts its output is byte-identical to the prior run (determinism
  invariant). The Self-Check Gate is `required: true` in the registry,
  so a malformed CI configuration blocks merge by the same mechanism
  as a failed code-check.

- **Evidence Origin Gate** (`mix tau.factory.gate.evidence_origin`). A
  producer that scans the PR body and every commit message for
  patterns that look like locally-produced evidence — `Finished in
  \d+\.\d+ seconds`, `\d+ tests, \d+ failures`, `running on .*-host`,
  `iex>`, `> mix test`. For every hit, requires an adjacent
  `https://github.com/<owner>/<repo>/actions/runs/<id>` URL whose
  `head_sha` (fetched via `gh api`) equals the PR head SHA. The gate's
  `applicable_inputs` are the lines that matched the pattern; if none
  matched, status is `:n_a`. No silent-skip: empty input set is
  explicit.

- **Ruleset Conformance Gate** (`mix tau.factory.gate.ruleset_conformance`).
  The branch-protection ruleset on `main` is encoded as a versioned
  file at `.factory/rulesets/main.json`. This gate fetches the live
  ruleset via `gh api repos/:owner/:repo/rulesets` and asserts
  byte-equality against the file. Drift fails the gate. Admin override
  of branch protection (the "merge anyway" path) becomes detectable
  because the post-merge mirror job (below) opens an issue when a
  merge commit on `main` has no corresponding signed `:admittor`
  verdict with `status: :pass` for its parent SHA.

- **Post-Merge Alarm**. A workflow on `push: main` that, for each new
  merge commit, asserts a signed `:admittor` verdict exists for the
  merged head SHA with `status: :pass`. Absence opens a GitHub issue
  labelled `factory/bypass-detected` with the merge SHA and merger
  identity. This is the only mechanism that handles the admin-override
  escape hatch; removing the admin override entirely is preferred but
  org-policy-dependent.

### Silent-skip impossibility — by construction

The phrase "silent-skip" decomposes into four sub-failures, each
structurally eliminated:

1. *Skip because PR body lacks a declaration field.* — Eliminated: no
   substrate component reads PR body. Applicability comes from the
   Oracle, not from any field.

2. *Skip because exit code masked with `|| true`.* — Eliminated: the
   Admittor does not consult exit codes; it consults signed Verdicts.
   An absent Verdict is treated as `:infra_fail` after the workflow's
   declared timeout (a wall-clock the Admittor reads from the registry,
   not from the workflow). A `|| true` produces no Verdict and
   therefore blocks merge.

3. *Skip because the job did not run (e.g. path-filtered out).*
   — Eliminated: path filters are forbidden in the verdict-producer
   workflows. The Self-Check Gate fails on any `paths:` or
   `paths-ignore:` in a producer job. Every required gate runs on every
   PR; gates with empty applicable input emit `:n_a`, which is a
   signed, ledgered, explicit "checked, 0 applicable" state.

4. *Skip because infrastructure failed (toolchain, network, OOM).*
   — Eliminated: any non-emission of a verdict for a required gate
   within its declared timeout is treated by the Admittor as
   `:infra_fail`, which blocks merge. The producer itself, if it
   detects an unrecoverable infra error, may *emit* a signed
   `Verdict{status: :infra_fail}` to give a clearer reason; either way
   merge is blocked.

### Verdict consumption

There is exactly one consumer that gates merges: the **Admittor**. Its
decision is computed by a pure function of:

- the gate registry (versioned at `.factory/registry.json`),
- the set of signed verdicts for the head SHA,
- the diff + repo tree (only as the re-run input to the Applicability
  Oracle, for the determinism invariant).

The Admittor emits a signed verdict (`gate_id: :admittor`). The
GitHub branch-protection required status check on `main` is named
`admittor`; GitHub treats it as failed unless the Admittor's verdict
for the head SHA has `status: :pass`. No other consumer of verdicts
gates merges. Secondary consumers exist (the operability dashboard;
post-merge alarm; audit-ingestion subsystem reading historical
verdicts) but none influence eligibility.

## §Build-order

A concrete sequence; each step's exit-criterion is a check the *next*
step can run against. Step N may not begin until step N-1's exit-
criterion is itself ledgered as a passing verdict (the Verdict-Bus
bootstraps itself once step 4 lands).

1. **Verdict schema + registry file format** (1 PR). Land
   `Tau.Factory.Verdict` struct, JSON schema at
   `.factory/schemas/verdict.schema.json`, and an empty
   `.factory/registry.json` with the schema-version field. Exit: `mix
   test` passes a property test that round-trips arbitrary verdicts
   through JSON.

2. **Applicability Oracle skeleton** (1 PR). `mix
   tau.factory.applicability` that emits an empty applicability map
   (no gates registered yet) signed with a development-only key. Exit:
   running the task twice on the same `head_sha` produces byte-
   identical output (determinism).

3. **CI signing identity** (1 PR). Configure GitHub Actions OIDC →
   short-lived signing certs (via Sigstore Fulcio or an in-repo CA
   bootstrap; choice deferred to selector). Land the public-key
   distribution: the gate registry stores each gate's expected signer
   identity (the GitHub Actions workflow path + repo + ref pattern).
   Exit: a smoke workflow signs and verifies an arbitrary blob.

4. **Verdict-Bus storage + write path** (1 PR). Create the
   `refs/factory/verdicts` orphan branch. Land the push-time signature
   verification (a required check on that branch named
   `verdict-signature`; an admittor-style verifier that reads the
   pushed file and the registry). Land a `Tau.Factory.VerdictBus.put/1`
   helper that pushes a signed verdict to the branch. Exit: pushing an
   unsigned or wrong-signer verdict is rejected at the server side.

5. **Admittor v0** (1 PR). `mix tau.factory.admit <head_sha>` that
   reads the empty registry and the empty ledger and trivially emits
   `:merge`. Add a workflow `admit.yml` that runs on every PR's head
   SHA and POSTs the Admittor's signed verdict. Configure branch
   protection on `main` to require exactly one status check: `admit`.
   Exit: a PR with no gates registered merges only after `admit`
   reports success.

6. **Self-Check Gate** (1 PR). First real producer. Register
   `:self_check` in the registry as `required: true`. Land
   `mix tau.factory.gate.self_check`. Exit: a PR that introduces a
   `|| true` in a workflow file is blocked by the Admittor.

7. **Evidence Origin Gate** (1 PR). Register `:evidence_origin`.
   Exit: a PR whose body pastes `Finished in 0.4 seconds` without an
   actions/runs URL is blocked.

8. **Ruleset Conformance Gate + initial `.factory/rulesets/main.json`**
   (1 PR). Encode the current branch-protection ruleset. Register
   `:ruleset_conformance`. Exit: drift between live and encoded ruleset
   blocks the next PR.

9. **Post-Merge Alarm** (1 PR). Land `factory/bypass-detected`
   workflow on `push: main`. Exit: simulating an admin-override merge
   (in a fork) opens a tagged issue.

10. **Sibling gate adoption** (incremental, gated). Each existing CI
    gate (`mix tau.gate.ac_linkage`, `mix tau.gate.masking`,
    `mix tau.gate.mutation`) is migrated to the Verdict-Bus pattern:
    one PR per gate, each registering its `gate_id` in the registry
    and replacing `|| true` / silent-skip paths with `:n_a` /
    `:infra_fail` verdict emissions. Once migrated, the old workflow
    job is deleted in the same PR. Exit per gate: the corresponding
    failure-class probe (e.g. a synthetic PR that should fail the
    gate) is blocked at merge by the Admittor.

11. **PR-body-field deprecation** (1 PR). Remove every gate's
    PR-body-field reader (the existing v1 silent-skip surface).
    Update `CONTRIBUTING.md` to state that PR-body fields are
    *advisory* and *never* gating. Exit: the Self-Check Gate's
    expanded ruleset forbids re-introducing PR-body predicates.

The build-order's monotonicity invariant: at every step, the failure
classes the new mechanism is supposed to block are tested by a
synthetic-PR probe that lands in the same PR as the mechanism. No
mechanism lands without its falsification probe.

## Tradeoffs

### Strengths

- **Silent-skip impossibility is structural, not procedural.** The
  Admittor reads signed records; absence is failure; PR-body text is
  never read. There is no surface for a `|| true` to hide.
- **Evidence origin is enforced by cryptography.** A verdict not
  signed by the registered CI identity is rejected at the Bus's write
  path (pre-receive hook on `refs/factory/verdicts`). A maintainer
  cannot paste local output as evidence; the substrate has no way to
  accept it.
- **Merge eligibility is a pure function.** The Admittor's verdict is
  reproducible given (head SHA, registry, ledger, repo tree). Anyone
  can re-run `mix tau.factory.admit <sha>` and check.
- **Single required status check** (`admittor`) replaces the v1
  multi-check arrangement, removing a class of branch-protection
  drift (mis-spelled required-check names that silent-pass).
- **Bootstraps on existing repo infrastructure.** The Verdict-Bus is a
  git ref; no new database, no new service to operate.
- **Admin-override path is not eliminated but is alarmed**, satisfying
  the leaf's acceptance criterion (c).

### Weaknesses

- **Cryptographic key management is now load-bearing.** A compromised
  CI signing key forges verdicts. Sigstore short-lived certs mitigate
  but do not eliminate. A bug in signature verification at the Bus's
  pre-receive hook is a silent bypass channel — must be its own
  redundantly-checked gate.
- **The Admittor itself is a single point of failure.** A bug in
  applicability-determinism logic could systematically silent-pass.
  Mitigations: the Self-Check Gate re-runs the Oracle and asserts
  byte-equality; the Admittor's own verdict can be re-verified by a
  reviewer running `mix tau.factory.admit` locally. But the substrate
  trusts the Admittor's signature, so a compromised Admittor key is
  catastrophic.
- **Migration is invasive.** Every existing gate must be migrated to
  emit signed Verdicts; until migration completes, the v1 substrate
  and v2 substrate coexist (one PR per gate, ~10 PRs).
- **`refs/factory/verdicts` as ledger** is unusual; tooling (GitHub
  UI, `git log --all`) doesn't naturally surface it; operators need
  training. An external append-only log (e.g. an immutable blob store)
  is more conventional and might be selected by §Build-order step 4's
  selector. The proposal commits to the git-ref shape for zero-new-
  infrastructure, accepting the operability cost.
- **Determinism of the Applicability Oracle is hard to guarantee** —
  filesystem walks, sort order, tool version drift. The Self-Check
  Gate's byte-equality assertion catches violations but at the cost of
  rejecting PRs that, e.g., upgrade a tool the Oracle depends on
  unless the Oracle is upgraded in lockstep.
- **No mitigation for a corrupted gate registry.** A PR that edits
  `.factory/registry.json` to remove a `required: true` gate would
  bypass it on the next PR. Requires a meta-rule: `.factory/registry.
  json` edits are themselves a gated, signed event with stricter
  signers (e.g. a multi-sig). This is sketched but not fully designed.
- **Time-to-first-merge increases** because every PR runs every
  required gate (no path-filtering shortcut), and each emits a signed
  verdict. Estimated overhead: +60–120s per PR for signing +
  verification + Admittor evaluation. Acceptable for the trustworthi-
  ness gain but real.

### Costs

- **Migration**: ~10 PRs (one per existing gate) plus 9 substrate PRs
  (§Build-order steps 1–9). Estimated 6–10 engineer-weeks of focused
  factory work; partial value lands after step 9.
- **Key infrastructure**: GitHub Actions OIDC + Sigstore Fulcio
  integration, or an in-repo CA. New dependency surface; Sigstore is
  ~3 new actions deps and one verification CLI.
- **CI minutes**: +60–120s per PR per gate (signing + signature
  verification + Admittor pass). With ~5 required gates post-migration,
  ~5–10 added CI-minutes per PR run.
- **Documentation**: Every gate must publish its applicability rules
  and verdict semantics. ~1 page per gate; ~10 pages total.
- **Operability surface**: `refs/factory/verdicts` queries surface in
  the sibling operability leaf's dashboard; coordination required.
- **Failure mode for offline forks**: contributors without a verified
  CI signing identity cannot produce verdicts; their PRs depend on
  upstream CI runs. This is a feature (evidence-origin enforcement)
  but a UX change.

## Dependencies

- A signing-identity mechanism (Sigstore Fulcio OIDC or in-repo CA).
  Selector chooses; either satisfies the contract.
- Branch-protection ruleset edit access on `main`.
- Coordination with the **operability-and-hygiene-enforcement**
  sibling: their dashboard reads `refs/factory/verdicts`; the schema at
  `.factory/schemas/verdict.schema.json` is shared.
- Coordination with the **pre-merge-code-gates** sibling: those gates
  become Verdict-Bus producers under this proposal's contract; the
  sibling owns gate content, this proposal owns the substrate they
  emit into.
- Coordination with the **knowledge-memory-and-audit-ingestion**
  sibling: that subsystem's audit findings become *applicability
  inputs* to specific gates (e.g. an audit finding that flags a
  module makes that module an applicable input to the corresponding
  gate). The Oracle reads audit registry entries.

## Confidence

**Medium.** Confidence would rise to **high** with:

- a working spike of §Build-order steps 1–5 against a fork of this
  repo, demonstrating that a PR with no gates registered can be
  admitted by the Admittor and that an unsigned verdict push is
  rejected;
- a clear selector decision on the signing-identity mechanism
  (Sigstore vs in-repo CA) — the proposal is contract-defined enough
  to be agnostic, but the spike requires choosing;
- a sketch of the registry-mutation meta-rule (multi-sig or equivalent)
  that closes the "corrupted registry" weakness.

The Verdict-record / Applicability-Oracle / Admittor decomposition is
high-confidence — it is a direct application of the leaf's
decomplecting hypothesis. The git-ref-as-ledger choice is medium-
confidence; an alternative proposal that uses an external log store is
plausible and worth comparing.

## Prior art / references

This is a first-principles proposal; ecosystem and adversarial-
reverse-engineering proposals are out of scope per the brief and will
be authored by proposers 2, 3, 4. The following are *internal* prior
art only:

- Tau's existing `Tau.Factory.Gate` module (`lib/tau/factory/gate.ex`)
  — three pure verdict-producing functions; this proposal generalises
  their shape to all gates and adds the signed-ledger substrate.
- The factory-loop rule's `## The gate` section, which already names
  "both halves must return PASS" — this proposal extends "PASS" to a
  cryptographically signed verdict rather than an agent assertion.
- ADR conventions in `docs/adr/` — the registry-mutation meta-rule
  (currently a weakness) would itself be ADR-worthy.

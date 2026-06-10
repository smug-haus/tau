---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Gate-infrastructure integrity — no silent-skip, no local-mix evidence, no red-CI merge

## Statement

The factory must make it structurally impossible for a gate to (a)
silent-skip when its declaration field is missing, (b) accept evidence
from a developer's local `mix` invocation in lieu of CI, or (c) merge a
PR while CI is red. v1 fails on all three: CI early-exits at
`ci.yml:88-100` and `:213-223` (silent-skip when AC-N declaration is
absent), one of three gates ends in `|| true` at `:115` (cannot fail),
PR bodies cite `mix test` output run on the contributor's laptop (root
#7), and the four most recent merges (#411-#414) merged against red CI
(root §Hypothesis preamble). The problem is solved when the
gate-execution substrate itself cannot be bypassed by a malformed PR,
an absent field, a `|| true`, or a maintainer choosing to merge a red
PR.

## Context

- Root §Acceptance C — "Silent-skip impossibility. No gate may
  silent-skip. A gate that has nothing to check on a particular PR
  returns 'checked, no applicable findings' — not 'skipped.' A gate
  that cannot run for infrastructural reasons fails the PR rather than
  passing it. The v1 CI early-exits at `ci.yml:88-100` and `:213-223`
  and the `|| true` at `:115` are the anti-patterns to make impossible."
- Root §Hypothesis #5 (silent-skip), #7 (red-CI merges, local-mix
  evidence).
- GitHub repository ruleset / branch-protection mechanics: required
  status checks, `require_branches_to_be_up_to_date`, `dismiss_stale_
  reviews`, "require linear history". Reuse vs custom must be evaluated.
- `gh api repos/:owner/:repo/branches/main/protection` is the current
  authoritative state; today the rules are partial.

## Failure classes addressed (from root §Hypothesis)

- **#5** (primary) — CI gates silent-skip when declaration field
  missing; `|| true` makes one gate non-failing.
- **#7** (primary) — factory merges PRs against red CI; PR-body fields
  cite local-machine `mix` output as evidence.

## Complecting hypothesis

- "Whether a gate runs" is complected with "whether the PR body opted
  it in" because v1 gates read declaration fields and skip when absent;
  decoupling requires that the gate's input universe be derived from
  the diff and the repository, not from the PR body.
- "Evidence of a check passing" is complected with "where the check was
  run" because PR bodies paste local output verbatim; the gate must
  refuse any evidence not produced by a CI run keyed on the head SHA.
- "Merge eligibility" is complected with "maintainer judgement" because
  GitHub allows an admin override; the branch-protection ruleset must
  remove the override or alarm on its use.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names mechanisms such that: (a) every gate's
applicability is computed from the diff/repo state, not from a PR-body
declaration field — a gate with an empty applicable-input set
explicitly logs "checked, 0 applicable" and exits 0; a gate whose
infrastructure cannot run (toolchain missing, network failure, runner
OOM) exits non-zero and the run is reported as failed, never as
skipped; (b) `.github/workflows/*.yml` files contain no `|| true`,
`continue-on-error: true` on a required check, or `if:` guards keyed on
PR-body fields — enforced by a meta-gate (e.g. `mix
tau.gate.ci_self_check` or a `lint-ci` job) that parses workflow YAML
and fails on any of those anti-patterns; (c) the GitHub branch-
protection ruleset on `main` is encoded as a versioned artifact (e.g.
Terraform, `gh api` script in the repo, or Repository Rulesets via the
GitHub API) and verified per-PR by a gate that diffs the live ruleset
against the encoded one — admin merge of a red PR is either disabled
or fires a post-merge alarm that opens an issue; (d) all gating
evidence cited in a PR body must reference a CI run URL on the PR's
head SHA — a gate scans PR-body text and fails if it finds `mix test`
output, `assert ... passed` lines, or other local-mix patterns without
a matching `actions/runs/<id>` URL whose `head_sha` matches; (e) the
design records reuse-vs-build per artifact (GitHub Rulesets API vs
bespoke; existing actions like `actions/github-script`, the
`benchmark-action/github-action-benchmark`, or a `polya-audit`-style
plugin) per root §Acceptance D; (f) the spec output identifies the
concrete artifacts: workflow files, the meta-gate mix task names, the
ruleset definition file, any GitHub App or bot for SHA-pinned evidence
verification, hook scripts in `.claude/settings.json`, and a
post-merge alarm mechanism (e.g. an issue-opener Action).

## Out of scope

- The content of each individual code gate (AST checks, behaviour
  completeness, etc.) — owned by **pre-merge-code-gates** sibling.
- AC-binding mechanics — owned by **intent-capture-and-ac-binding**
  sibling.
- What runs on `main` after merge (drift re-audit, cross-spec
  consistency) — owned by **post-merge-cross-artifact-coherence**
  sibling.
- The factory dashboard / state-observability surface — owned by
  **operability-and-hygiene-enforcement** sibling (this leaf produces
  the verdicts; that leaf displays them).
- Ingesting prior audit findings — owned by
  **knowledge-memory-and-audit-ingestion** sibling.
- Documentation-only components; agent-discipline-only enforcement;
  workstream-2 corrective-actions catalogue.

## Amendment log

- (none yet)

# Work-record schema (v1)

Each file `.claude/work-records/<record-id>.json` captures one end-to-end
operator interaction on a single task. Records are append-only by
convention: each role appends its block when it runs. The record is the
sole signal source the project adapter
(`.claude/hyperagents-eval/role_eval.py`) reads to score a sibling's
candidates.

**No human in the loop.** Ground truth comes from the toolchain
(`mix test`, `mix format --check-formatted`, `mix credo --strict`),
cross-role agreement, and downstream operational signal (whether a
generated diff lands on `main`). Anything that needs a human to
adjudicate is not a signal this loop consumes.

## Path & id

`.claude/work-records/wr-<UTC-yyyymmddThhmmss>-<short-hash>.json`

## Shape

```json
{
  "version": 1,
  "record_id": "wr-20260513T1812-7f3a",
  "created_at": "2026-05-13T18:12:00Z",

  "task": {
    "kind": "issue | curated | hyperagents-task",
    "source": "github | hand-curated | eval_config",
    "issue_number": 143,
    "title": "...",
    "url": "https://github.com/smug-haus/tau/issues/143",
    "body": "the prompt text the operators receive"
  },

  "implementer": {
    "gen_id": "hyperagent-gen4-a7175c7a",
    "base_sha": "<tau HEAD sha at run time>",
    "diff": "unified diff text — applies cleanly via `git apply` against base_sha",
    "files_changed": ["lib/tau/..."],
    "stdout_excerpt": "first ~2KB of operator stdout",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  },

  "critic": {
    "gen_id": "hyperagent-gen5-a7175c7a",
    "reviewed_base_sha": "<base_sha the critic actually saw, set by the adapter>",
    "findings": [
      {
        "id": "f-1",
        "severity": "BLOCKING | SUGGESTION",
        "category": "spec-deviation | otp-non-negotiable | over-engineering | scope-creep | other",
        "file": "lib/tau/session.ex",
        "line": 142,
        "message": "...",
        "evidence": "quoted code or spec excerpt"
      }
    ],
    "single_most_important_id": "f-1",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  },

  "reviewer": {
    "gen_id": "hyperagent-gen7-a7175c7a",
    "reviewed_base_sha": "<base_sha the reviewer actually saw>",
    "verdict": "PASS | FAIL | PARTIAL",
    "tests":  { "tool": "mix test", "passed": 360, "failed": 0, "errors": 0 },
    "format_clean": true,
    "credo_clean": null,
    "findings": [ "same shape as critic.findings" ],
    "evidence": "...",
    "wall_clock_s": 0.0,
    "tokens": 0,
    "completed_at": "..."
  }
}
```

## Worktree contract — critic and reviewer review the *applied* diff

The adapter builds a fresh `git worktree add --detach <wt> <base_sha>` for
each critic / reviewer invocation, then `git apply`s `implementer.diff`
into it before running the role's candidate with `cwd=<wt>`. The candidate
therefore sees:

- A real git checkout at `implementer.base_sha`,
- With `implementer.diff` already applied to its working tree,
- So `git diff`, `mix test`, `mix compile`, `mix format --check-formatted`,
  and `mix credo --strict` all reflect the implementer's actual changes.

If `git worktree add` or `git apply` fails, the role block is populated
with `{error: "worktree-prep failed: ..."}` and the per-task probe scores
0. The next mutation cycle's meta-agent sees this through the
`metrics.task_verdicts[].why` field (via plugin Change 1).

## Field semantics — the bits load-bearing for evolution

- `implementer.base_sha` + `implementer.diff`: together pin the exact
  tree critic/reviewer review. Without both, the role adapters fall back
  to current HEAD, which is best-effort and not reproducible.
- `critic.findings[].id`: stable identifier so later analysis (or a
  downstream operator) can refer to a finding by id.
- `critic.findings[].severity`: `BLOCKING` is the hard signal;
  `SUGGESTION` is graded more leniently (a noisy critic is more painful
  for blocking findings than suggestions).
- `reviewer.verdict` + `reviewer.tests`: ground truth from the
  toolchain. The reviewer ran `mix test` against the actual applied
  diff; a `PASS` with `tests.failed > 0` is incoherent and should fail
  schema validation in any downstream calibration script.
- `reviewed_base_sha`: set by the adapter, not the candidate; lets a
  later run detect that two reviewers reviewed the same tree (worth
  comparing) vs. different trees (not comparable).

## Lifecycle

1. `implementer` role runs → file created with `task` and `implementer`
   blocks populated; other blocks `null`.
2. `critic` role runs → reads records where `implementer != null` and
   `critic == null`; for each, creates a patched worktree, invokes the
   critic candidate, appends `critic` block.
3. `reviewer` role runs → reads records where `implementer != null` and
   `reviewer == null`; for each, creates a patched worktree, invokes
   the reviewer candidate, appends `reviewer` block.

No further mutations to a record after `reviewer` is populated. New
information about a diff (e.g., a follow-up generation reviewing the
same task) gets a new record.

## Adapter contract

`role_eval.py` reads work-records, scores the candidate, and writes
`scores.json` per `hyperagents:eval-adapter-spec`. The `metrics`
channel is the project's open channel to the meta-agent's prompt
(per plugin Change 1) — emit anything you want the meta-agent to be
able to reason over.

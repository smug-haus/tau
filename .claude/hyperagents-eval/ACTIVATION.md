# Activating the real-work evaluator

The infrastructure (work-record schema, operator manifest, role-eval
adapter, structured-findings extensions to critic/reviewer) is built and
sits side-by-side with the existing synthetic-probe pipeline. **Nothing
is activated yet.** Activation is a deliberate per-sibling step.

## Per-sibling activation steps

To flip a sibling from synthetic-probe eval (`purpose_task_eval.py`) to
real-work eval (`role_eval.py`):

1. Edit `.claude/hyperagents/<sibling>/settings.json` and change the
   `evaluator` block to point at the project adapter and pass the role:

   ```json
   {
     "evaluator": {
       "kind": "script",
       "command": [
         "${PROJECT_ROOT}/.venv/bin/python3",
         "${PROJECT_ROOT}/.claude/hyperagents-eval/role_eval.py"
       ],
       "args_template": [
         "--plugin-dir", "{plugin_dir}",
         "--out",        "{out_dir}",
         "--role",       "<implementer|critic|reviewer>"
       ],
       "timeout_s": 3600,
       "expected_outputs": ["scores.json"]
     }
   }
   ```

   Set `--role` per sibling: `tau-implementer` → `implementer`,
   `tau-critic` → `critic`, `tau-reviewer` → `reviewer`.

2. Commit the change in the sibling's archive repo:

   ```sh
   cd .claude/hyperagents/<sibling>
   git add settings.json
   git commit -m "evaluator: switch to real-work role_eval"
   ```

3. (Optional) Update `eval_config.json` `tasks` to point at real backlog
   items rather than the synthetic AI-derived list. The adapter reads
   `tasks` for the implementer role only.

4. Run the loop. `/hyperagents:step --name <sibling>` or the
   `restart_tau_hyperagent.py` driver will now invoke the role-eval
   adapter instead of the synthetic judge.

## What each adapter does once activated

- **implementer**: runs the candidate against each task in
  `eval_config.tasks`, captures diff + stdout in a fresh work-record
  per task, scores on immediate signals (non-empty diff/output, rc=0).
- **critic**: picks pending records where `implementer != null` and
  `critic == null`, invokes the candidate to produce structured
  findings, appends the `critic` block, scores on structural shape.
- **reviewer**: same shape as critic, emits PASS/FAIL/PARTIAL + tests
  block, scores on structural shape.

## What the adapter does not yet do

- It does **not** read `human_action` from records for scoring. Once
  records have human-action data, replace the structural-shape score
  with a calibration score (e.g., critic: fraction of findings the
  human addressed; reviewer: agreement between verdict and merge).
- It does **not** invoke other-role operators inline. Each role runs
  separately. To chain (impl → critic → reviewer), run the loop for
  each sibling in sequence, or write a chain orchestrator.

## Smoke test

The adapter has a `--stub-mode` flag for plumbing tests without
spending tokens:

```sh
.claude/hyperagents-eval/role_eval.py \
  --plugin-dir .claude/hyperagents/tau-implementer/agents/<gen-id> \
  --out /tmp/smoke --role implementer --stub-mode
```

Writes records and `scores.json` deterministically; no `claude -p`
invocations.

## Rollback

To revert a sibling to synthetic-probe eval, restore its
`settings.json` from before the activation commit (or copy from another
sibling that's still on the synthetic adapter). The work-record store
stays in place — only new records stop being produced.

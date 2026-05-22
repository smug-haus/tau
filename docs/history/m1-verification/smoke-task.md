# M1 Verification: Smoke-Task Prompt

## Chosen task: issue #258 (skill namespace collision)

Issue #259 (YAML folded-scalar parser bug) was considered first. It is small
and well-scoped, but it requires touching `Tau.Skills.Frontmatter` (a parser
module), adding property tests, and also editing five `.claude/skills/*/SKILL.md`
files. The parser change carries real test-breakage risk on a first verification
run where diagnosing a coordinator failure vs. a test failure is the harder
problem.

Issue #258 (skill namespace collision — generic persona names can be masked by
user skills) is the better choice:

- **Scope is bounded.** Option (1) + (2) from the issue: rename the three
  bundled personas (`implementer` → `tau-implementer`, `critic` → `tau-critic`,
  `reviewer` → `tau-reviewer`), update the coordinator SKILL.md references, add
  a shadow-detection warning to `Tau.Skills.Loader.discover/1`, and add a test.
- **Touches no coordination-heavy SPECd boundary.** `priv/skills/` and
  `lib/tau/skills/loader.ex` are not in any SPEC's Appendix B source map, so
  `spec-before-code.md` does not apply and there is no mandatory spec amendment
  to negotiate.
- **Directly unblocks M1.** The coordinator persona currently passes
  `subagent_type: "implementer"` to the `Agent` tool. If a user has their own
  `~/.tau/skills/implementer/SKILL.md`, the bundled persona is silently masked.
  Fixing this collision is a prerequisite for the coordinator factory loop to
  work reliably on any installation.
- **Mix test is low risk.** Renaming files and updating string references in one
  Elixir module; the existing loader test suite will catch regressions cleanly.

---

## Verbatim smoke-task prompt

Pass the following text as the `<prompt>` argument to `tau run`:

```
You are the Tau coordinator. Execute one factory step for issue #258.

Issue #258 is open on smug-haus/tau. Title: "fix(skills): namespace collision —
generic persona names can be masked by user skills". The issue documents that the
bundled coordinator sub-personas (implementer, critic, reviewer under priv/skills/)
share generic names that a user skill at ~/.tau/skills/ can silently shadow,
breaking the M1 factory loop.

Execute the factory cycle for this issue end-to-end:

1. Check for .claude/STOP-FACTORY — halt if present.
2. Confirm issue #258 is open on smug-haus/tau (gh issue view 258).
3. Verify git is on main at origin/main (git fetch origin; git rev-parse main
   vs git rev-parse origin/main). Branch: git checkout -b fix/skill-namespace-258.
4. Spawn an implementer Agent to implement option (1)+(2) from the issue:
   - Rename priv/skills/implementer/ to priv/skills/tau-implementer/ (and critic,
     reviewer analogously).
   - Update all subagent_type references in priv/skills/tau-coordinator/SKILL.md
     from "implementer"/"critic"/"reviewer" to "tau-implementer"/"tau-critic"/"tau-reviewer".
   - Add a Logger.warning in Tau.Skills.Loader.discover/1 when a priv/skills
     entry is shadowed by a same-named user skill.
   - Add a test that asserts the bundled personas remain reachable when a
     same-named user skill exists in ~/.tau/skills/.
   - Run mix compile --warnings-as-errors and mix test to confirm green.
   - Commit and push the branch; open a PR with gh pr create referencing
     Closes #258.
5. Run the FULL gate: spawn a critic Agent (read the diff with git diff
   origin/main...HEAD; return {"ok": true} or {"ok": false, "reason": "..."} as
   the last JSON line). Then spawn a reviewer Agent (same diff, same contract).
   Both must return {"ok": true} to proceed.
6. If gate is green: gh fetch origin; confirm origin/main is unchanged; then
   gh pr merge <n> --merge --delete-branch.
7. Sync: git fetch origin && git checkout main && git pull --ff-only origin main.
8. Health check: mix compile --warnings-as-errors && mix test. Report results.
9. Report: state the merged PR number and SHA, confirm M1 factory cycle
   completed successfully, and that #258 is now closed.
```

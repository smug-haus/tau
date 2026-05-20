# M1 Self-Hosting Verification — Runbook

The final M1 step is *running* the coordinator workflow end-to-end inside a Tau session against a real provider. This runbook is one-time bootstrap + one invocation. Everything else (build, smoke, full QA gate) is automated by `mix tau.qa` (issue #268) and the CI `binary-qa` job.

Smoke-task body in [`smoke-task.md`](smoke-task.md). Evidence destination is [`evidence/`](evidence/).

## 1. Prerequisites — one-time

1. **Toolchain**: `bash scripts/install-toolchain.sh` (no sudo; installs Erlang/Elixir/Zig under `$HOME/.local/share/tau-toolchain`). Then `source ~/.local/share/tau-toolchain/env.sh` (or add to your shell rc for persistence).
2. **A tool-capable provider API key**. Recommended: Anthropic (`export ANTHROPIC_API_KEY=...`). See `lib/tau/providers/` for alternatives; their auth conventions live in each adapter module.
3. **`gh` CLI authenticated** with push to `smug-haus/tau`.
4. **Shadow-skill precheck** — the coordinator persona dispatches sub-personas by name. A same-named skill under `~/.tau/skills/` would silently shadow the bundled one:

   ```sh
   ls ~/.tau/skills/ 2>/dev/null | grep -E '^(implementer|critic|reviewer|tau-coordinator)$'
   # must produce no output
   ```

5. **CI on `main` is green** (specifically the `binary-qa` job — six-layer gate from #268). Check: `gh run list --workflow=ci.yml --branch=main --limit=1`. If red, fix CI first; do not run verification against a known-broken `main`.

## 2. Verify — one command

```sh
./tau run "$(awk '/^```$/{if(p)exit; p=1; next} p' docs/m1-verification/smoke-task.md)" \
  --system-prompt-file priv/skills/tau-coordinator/SKILL.md \
  --provider anthropic \
  --model claude-opus-4-7
```

The `awk` extracts the smoke-task body verbatim from `smoke-task.md`. Substitute provider/model if you're not using Anthropic. The coordinator runs to completion (one merged PR), then exits 0.

**Expected exit behaviour:** `0` on a successful end-to-end coordinator step (a merged PR for the smoke-task issue exists, owned by the Tau-run commit history). Non-zero means the run failed — see § 4.

## 3. Capture evidence — after a successful run

The session writes a JSONL transcript at `~/.tau/sessions/<date>/<session-id>.jsonl`. After exit 0:

```sh
SESSION=$(ls -t ~/.tau/sessions/*/*.jsonl | head -1)
SHA=$(gh pr list --state merged --limit 1 --json mergeCommit --jq '.[0].mergeCommit.oid' | cut -c1-7)
cp "$SESSION" "docs/m1-verification/evidence/parent-${SHA}.jsonl"
cat > "docs/m1-verification/evidence/${SHA}-summary.md" <<EOF
# M1 Verification — ${SHA}

Provider: anthropic
Model: claude-opus-4-7
Session: ${SESSION##*/}
Merged PR: $(gh pr list --state merged --limit 1 --json url --jq '.[0].url')

Observations: (one-liners — anything surprising)
EOF
```

Commit the `evidence/*` files. That is the M1 acceptance artifact.

## 4. If the run fails

The two non-trivial failure paths are:

- **Provider auth / quota**: `tau run` exits non-zero with a `provider error` line. Fix the env var, re-run.
- **The coordinator's reasoning produced a defect** — it spawned the wrong sub-persona, mis-quoted the gate verdict, etc. File a GH issue against the coordinator persona (`priv/skills/tau-coordinator/SKILL.md`) with the failing JSONL attached.

All structural failures (binary won't boot, NIF won't load, persona file unloadable, drain loop wrong) are caught by `mix tau.qa` upstream — if CI is green, those are not on your path.

## 5. Closing M1

After the evidence is committed:

```sh
gh issue close 256 --comment "M1 verified — see docs/m1-verification/evidence/<sha>-summary.md"
gh api repos/:owner/:repo/milestones/$(gh api repos/:owner/:repo/milestones --jq '.[] | select(.title=="M1 — Self-hosting") | .number') -X PATCH -f state=closed
touch .claude/STOP-FACTORY      # halt the factory loop (sentinel checked before next step)
```

The factory loop stops being driven once M1 is met and verified.

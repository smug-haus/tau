#!/usr/bin/env python3
"""Implementer revision pass on a BLOCK'd work-record.

Given a record id, build a revision prompt from the existing critic and
reviewer findings, re-invoke the currently-promoted implementer
operator against a worktree where the current diff is already applied,
capture the revised diff, update the record's implementer block, and
reset critic / reviewer to null so the next pass through role_eval (or
chain.py) re-evaluates the revised work.

This is the third role of the loop the user named explicitly: when the
gates BLOCK, the implementer revises in response to the critic's
BLOCKING findings and the reviewer's failure reasons. Repeat until
READY or until the implementer refuses (no diff produced, or output
states refusal).

Usage:
    revise.py <record-id-or-path> [--implementer GEN] [--run-timeout-s N] [--stub-mode]

The record file lives at `.claude/work-records/<id>.json`; passing the
bare id (without .json) is fine.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path("/home/brentw/src/tau").resolve()
OPERATORS_DIR = REPO / ".claude" / "operators"
ARCHIVE_BASE = REPO / ".claude" / "hyperagents"
WORK_RECORDS = REPO / ".claude" / "work-records"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_operator(role: str) -> str:
    p = OPERATORS_DIR / f"{role}.id"
    line = p.read_text().strip().split("#", 1)[0].strip()
    if not line:
        raise SystemExit(f"empty operator manifest: {p}")
    return line


def plugin_dir_for(role_path: str) -> Path:
    if "/" not in role_path:
        raise SystemExit(f"operator manifest must be '<sibling>/<gen-id>', got: {role_path}")
    sibling, gen = role_path.split("/", 1)
    p = ARCHIVE_BASE / sibling / "agents" / gen
    if not p.is_dir():
        raise SystemExit(f"operator scaffold not found at {p}")
    return p.resolve()


def load_record(rec_arg: str):
    p = Path(rec_arg)
    if not p.is_absolute():
        if not p.name.endswith(".json"):
            p = WORK_RECORDS / f"{rec_arg}.json"
        else:
            p = WORK_RECORDS / rec_arg
    if not p.is_file():
        raise SystemExit(f"record not found: {p}")
    return p, json.loads(p.read_text(encoding="utf-8"))


def head_sha() -> str:
    return subprocess.run(
        ["git", "-C", str(REPO), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip()


def build_revision_prompt(record: dict, plugin_name: str | None) -> str:
    """Compose the implementer's revision prompt from existing record state."""
    task = record["task"]["body"]
    impl = record.get("implementer") or {}
    diff = impl.get("diff") or ""
    crit = record.get("critic") or {}
    rev = record.get("reviewer") or {}

    routing = f"@{plugin_name}:task-agent\n\n" if plugin_name else ""

    def fmt_findings(label, findings, severities=("BLOCKING",)):
        relevant = [f for f in (findings or []) if (f.get("severity") or "").upper() in severities]
        if not relevant:
            return ""
        out = [f"\n## {label} ({len(relevant)})\n"]
        for fi in relevant:
            loc = f"{fi.get('file','?')}:{fi.get('line','?')}"
            out.append(f"- [{fi.get('severity')}] {loc}\n  {fi.get('message','').strip()}")
            ev = (fi.get("evidence") or "").strip()
            if ev:
                out.append(f"  Evidence: {ev[:400]}")
        return "\n".join(out)

    crit_findings = fmt_findings("Critic BLOCKING findings", crit.get("findings"))
    crit_suggestions = fmt_findings(
        "Critic SUGGESTION findings (lower priority — address only if cheap)",
        crit.get("findings"), severities=("SUGGESTION",),
    )
    rev_verdict = rev.get("verdict") or "(no reviewer verdict)"
    rev_findings = fmt_findings(
        "Reviewer BLOCKING / WARNING findings",
        rev.get("findings"),
        severities=("BLOCKING", "WARNING"),
    )
    rev_tests = rev.get("tests")

    body = f"""{routing}This is a REVISION of a prior implementation. Your prior diff is below,
followed by what the critic and reviewer flagged. Produce a revised diff
that addresses every BLOCKING finding from the critic and every failure
from the reviewer.

Address SUGGESTION findings only if the fix is small and obviously
correct. Do not regress passing tests.

## Original task

{task}

## Your prior diff (currently applied to the working tree as your starting point)

```diff
{diff}
```
{crit_findings}
{crit_suggestions}

## Reviewer verdict: {rev_verdict}

Reviewer tests: {json.dumps(rev_tests) if rev_tests else '(none recorded)'}
{rev_findings}

## Output

The working tree you see has the prior diff applied. Edit further to
address the findings — produce additional changes on top. The captured
diff at the end of your run will be (prior + revisions). Confirm
`mix test`, `mix format --check-formatted`, and `mix credo --strict`
still pass (or move closer to passing) before reporting done.

If you believe a critic finding is wrong (false positive), state your
reasoning in your final stdout but do NOT make a change for it. The
loop tracks refusals as a signal.
"""
    return body


def claude_p(*, plugin_dir, input_text, cwd, timeout_s):
    cmd = [
        "claude", "-p",
        "--output-format", "json",
        "--plugin-dir", str(plugin_dir),
        "--dangerously-skip-permissions",
    ]
    try:
        r = subprocess.run(
            cmd, input=input_text, cwd=cwd,
            capture_output=True, text=True, timeout=timeout_s,
        )
    except subprocess.TimeoutExpired as e:
        out = e.stdout if isinstance(e.stdout, str) else (e.stdout or b"").decode("utf-8", "replace")
        return (out or "", 0, -1, "timeout")
    try:
        obj = json.loads(r.stdout or "")
        text = obj.get("result", "") or ""
        u = obj.get("usage") or {}
        tokens = int(u.get("input_tokens", 0) or 0) + int(u.get("output_tokens", 0) or 0)
    except (json.JSONDecodeError, ValueError, TypeError, KeyError):
        text, tokens = (r.stdout or ""), 0
    return (text, tokens, r.returncode, (r.stderr or "")[:2000])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("record")
    p.add_argument("--implementer", default=None,
                   help="override `<sibling>/<gen-id>` for implementer")
    p.add_argument("--run-timeout-s", type=int, default=1500)
    p.add_argument("--stub-mode", action="store_true")
    args = p.parse_args()

    rec_path, record = load_record(args.record)
    impl_block = record.get("implementer") or {}
    if not impl_block.get("diff"):
        raise SystemExit(f"record {rec_path.name} has no implementer.diff to revise")

    base_sha = impl_block.get("base_sha") or head_sha()
    prior_diff = impl_block.get("diff") or ""
    revision_n = int(impl_block.get("revision_n", 0)) + 1

    operator = args.implementer or read_operator("implementer")
    plugin_dir = plugin_dir_for(operator)
    plugin_name_path = plugin_dir / ".claude-plugin" / "plugin.json"
    plugin_name = None
    if plugin_name_path.is_file():
        try:
            plugin_name = json.loads(plugin_name_path.read_text(encoding="utf-8")).get("name")
        except (OSError, json.JSONDecodeError):
            pass

    print(f"[revise] record:    {rec_path.name}")
    print(f"[revise] operator:  {operator}")
    print(f"[revise] base_sha:  {base_sha}")
    print(f"[revise] revision:  {revision_n}")
    print(f"[revise] prior diff: {len(prior_diff)} chars, {len((prior_diff or '').splitlines())} lines")

    if args.stub_mode:
        # Pretend revision: append a comment line to the prior diff (stub)
        new_diff = prior_diff
        new_files = list(impl_block.get("files_changed") or [])
        stdout = "stub-mode revision: no edits"
        tokens = 0
        wall = 0.0
        rc = 0
        stderr = ""
    else:
        # Build a patched worktree at base_sha + prior diff, hand to candidate.
        base = Path(tempfile.mkdtemp(prefix="tau-revise-"))
        wt = base / "wt"
        subprocess.run(["git", "-C", str(REPO), "worktree", "prune"], capture_output=True, text=True)
        r = subprocess.run(
            ["git", "-C", str(REPO), "worktree", "add", "--detach", str(wt), base_sha],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            shutil.rmtree(base, ignore_errors=True)
            raise SystemExit(f"git worktree add failed: {r.stderr[:300]}")
        # Apply the prior diff.
        if prior_diff.strip():
            ap = subprocess.run(
                ["git", "-C", str(wt), "apply", "--whitespace=nowarn", "-"],
                input=prior_diff, capture_output=True, text=True,
            )
            if ap.returncode != 0:
                subprocess.run(["git", "-C", str(REPO), "worktree", "remove", "--force", str(wt)],
                               capture_output=True, text=True)
                shutil.rmtree(base, ignore_errors=True)
                raise SystemExit(f"git apply prior diff failed: {ap.stderr[:300]}")

        # Snapshot existing nested agent worktrees so we can detect ones
        # the implementer's Task tool spawns during revision.
        agent_wt_root = REPO / ".claude" / "worktrees"
        preexisting_agent_wts = set()
        if agent_wt_root.is_dir():
            preexisting_agent_wts = {p.name for p in agent_wt_root.glob("agent-*")
                                     if p.is_dir()}

        prompt = build_revision_prompt(record, plugin_name)

        ts = time.monotonic()
        stdout, tokens, rc, stderr = claude_p(
            plugin_dir=plugin_dir, input_text=prompt, cwd=str(wt),
            timeout_s=args.run_timeout_s,
        )
        wall = time.monotonic() - ts

        # Capture the new total diff against base_sha.
        subprocess.run(["git", "-C", str(wt), "add", "-A"], capture_output=True, text=True)
        new_diff = subprocess.run(
            ["git", "-C", str(wt), "diff", "--cached"],
            capture_output=True, text=True,
        ).stdout or ""
        names = subprocess.run(
            ["git", "-C", str(wt), "diff", "--cached", "--name-only"],
            capture_output=True, text=True,
        ).stdout or ""
        new_files = [ln.strip() for ln in names.splitlines() if ln.strip()]
        diff_source = "workspace"

        # Fallback: if no diff in our workspace, check nested agent worktrees
        # the implementer's Task tool may have spawned. Same nested-worktree
        # workaround as in role_eval.py.
        if not new_diff.strip() and agent_wt_root.is_dir():
            new_agent_wts = [p for p in agent_wt_root.glob("agent-*")
                             if p.is_dir() and p.name not in preexisting_agent_wts]
            for awt in new_agent_wts:
                subprocess.run(["git", "-C", str(awt), "add", "-A"],
                               capture_output=True, text=True)
                d = subprocess.run(["git", "-C", str(awt), "diff", "--cached"],
                                   capture_output=True, text=True).stdout or ""
                n = subprocess.run(["git", "-C", str(awt), "diff", "--cached", "--name-only"],
                                   capture_output=True, text=True).stdout or ""
                if d.strip():
                    new_diff = d
                    new_files = [ln.strip() for ln in n.splitlines() if ln.strip()]
                    diff_source = f"nested-agent-worktree:{awt.name}"
                    break

        # Tear down our parent worktree (we don't tear down nested agent
        # worktrees — they are still locked by their plugin owner; they will
        # be cleaned up on next worktree prune cycle).
        subprocess.run(["git", "-C", str(REPO), "worktree", "remove", "--force", str(wt)],
                       capture_output=True, text=True)
        shutil.rmtree(base, ignore_errors=True)

    # Detect refusal: rc=0 but diff unchanged from prior → implementer refused.
    refused = (rc == 0) and (new_diff.strip() == prior_diff.strip())
    why = "refused (no change vs prior)" if refused else (
        f"rc={rc}; {stderr[:200]}" if rc != 0 else "revised")

    print(f"[revise] new diff:  {len(new_diff)} chars, {len(new_diff.splitlines())} lines")
    print(f"[revise] files:     {new_files}")
    print(f"[revise] wall:      {wall:.1f}s  tokens: {tokens}  rc: {rc}  status: {why}")

    # Update the record: replace implementer block with revised; reset critic/reviewer.
    new_impl = {
        "gen_id": plugin_name or str(plugin_dir),
        "base_sha": base_sha,
        "diff": new_diff[:200_000],
        "files_changed": new_files[:200],
        "diff_source": diff_source if not args.stub_mode else "stub",
        "stdout_excerpt": stdout[:8000],
        "wall_clock_s": round(wall, 2),
        "tokens": tokens,
        "revision_n": revision_n,
        "revised_at": now_iso(),
        "refused": refused,
        "prior_diff_chars": len(prior_diff),
    }
    record["implementer"] = new_impl
    record["critic"] = None
    record["reviewer"] = None
    rec_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

    print(f"[revise] wrote: {rec_path}")
    print(f"[revise] next: run critic and reviewer to re-evaluate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

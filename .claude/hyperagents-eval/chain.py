#!/usr/bin/env python3
"""End-to-end orchestrator: implementer → critic → reviewer on one task.

Reads the operators manifest under `.claude/operators/` to resolve each
role to its currently-promoted hyperagent gen, then invokes
`role_eval.py` for each role in sequence. The chain is order-dependent:

  1. implementer creates a fresh work-record with the diff.
  2. critic picks up that record (or any pending one) and appends findings.
  3. reviewer picks up the record and appends the verdict.

Each step is a separate `role_eval.py` subprocess; the chain doesn't
share state in-process beyond the work-record file the subprocesses
read and write. That keeps the chain re-runnable from any point —
restart at the failing step without re-running prior work.

Usage:
    chain.py <task_body_or_@file>
        [--implementer GEN] [--critic GEN] [--reviewer GEN]
        [--run-timeout-s N] [--stub-mode]

Defaults are read from `.claude/operators/<role>.id`. A `GEN` argument
is a `<sibling>/<gen-id>` path relative to `.claude/hyperagents/`.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path("/home/brentw/src/tau").resolve()
ROLE_EVAL = REPO / ".claude" / "hyperagents-eval" / "role_eval.py"
OPERATORS_DIR = REPO / ".claude" / "operators"
ARCHIVE_BASE = REPO / ".claude" / "hyperagents"


def read_operator(role: str) -> str:
    """Read `.claude/operators/<role>.id` → '<sibling>/<gen-id>'."""
    p = OPERATORS_DIR / f"{role}.id"
    if not p.is_file():
        raise SystemExit(f"missing operator manifest: {p}")
    line = p.read_text().strip()
    # Allow trailing comments after '#'
    if "#" in line:
        line = line.split("#", 1)[0].strip()
    if not line:
        raise SystemExit(f"empty operator manifest: {p}")
    return line


def plugin_dir_for(role_path: str) -> Path:
    """'<sibling>/<gen-id>' → absolute path to the candidate scaffold."""
    return (ARCHIVE_BASE / role_path / "agents" / role_path.split("/", 1)[1]).resolve() \
        if "/" in role_path else (ARCHIVE_BASE / role_path).resolve()


def plugin_dir_for_strict(role_path: str) -> Path:
    """Parse '<sibling>/<gen-id>' robustly."""
    if "/" not in role_path:
        raise SystemExit(f"operator manifest must be '<sibling>/<gen-id>', got: {role_path}")
    sibling, gen = role_path.split("/", 1)
    p = ARCHIVE_BASE / sibling / "agents" / gen
    if not p.is_dir():
        raise SystemExit(f"operator scaffold not found at {p}")
    return p.resolve()


def run_role(role: str, plugin_dir: Path, out_dir: Path, *,
             stub: bool, run_timeout_s: int, task=None, max_probes=1):
    """Invoke role_eval.py for one role; return (parsed scores.json, rc)."""
    cmd = [
        sys.executable, str(ROLE_EVAL),
        "--plugin-dir", str(plugin_dir),
        "--out",        str(out_dir),
        "--role",       role,
        "--run-timeout-s", str(run_timeout_s),
        "--max-probes", str(max_probes),
    ]
    if task is not None:
        cmd += ["--task", task]
    if stub:
        cmd += ["--stub-mode"]
    print(f"\n[chain] → {role}  plugin={plugin_dir.name}  out={out_dir}")
    rc = subprocess.run(cmd).returncode
    sf = out_dir / "scores.json"
    scores = json.loads(sf.read_text()) if sf.is_file() else None
    if scores:
        n = scores.get("n_examples")
        pr = scores.get("primary")
        notes = (scores.get("notes") or "")[:120]
        print(f"[chain] ← {role}  rc={rc}  primary={pr}  n={n}  notes={notes}")
    else:
        print(f"[chain] ← {role}  rc={rc}  (no scores.json)")
    return scores, rc


def latest_record_id(work_dir: Path):
    files = sorted(work_dir.glob("wr-*.json"))
    return files[-1].name if files else None


def pin_task_in_eval_config(sibling_dir: Path, task_body: str) -> bool:
    """Append `task_body` to <sibling>/eval_config.json's `tasks` list if absent.

    Returns True if the task was newly added (caller may then write a
    parent_scores signal); False if it was already present.
    """
    cfg_path = sibling_dir / "eval_config.json"
    if not cfg_path.is_file():
        return False
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    tasks = cfg.get("tasks") or []
    # Deduplicate by exact body match — the eval probe list grows monotonically
    # so a task that surfaced evolutionary pressure stays in the regression set.
    if task_body in tasks:
        return False
    tasks.append(task_body)
    cfg["tasks"] = tasks
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    return True


def write_parent_scores_signal(sibling_dir: Path, gen_id: str,
                               task_body: str, record_summary: dict) -> Path:
    """Write `runs/<gen_id>/scores.json` reflecting the just-finished task.

    The meta-agent reads this file during mutation to know what its parent
    just did poorly. Format mirrors role_eval.py's emit shape.
    """
    runs_dir = sibling_dir / "runs" / gen_id
    runs_dir.mkdir(parents=True, exist_ok=True)
    out = {
        "version": 1,
        "primary": float(record_summary.get("primary", 0.0)),
        "metrics": {
            "pass_rate": float(record_summary.get("primary", 0.0)),
            "tokens": int(record_summary.get("tokens", 0) or 0),
            "task_verdicts": [{
                "task": task_body[:1500],
                "passed": bool(record_summary.get("passed", False)),
                "why": record_summary.get("why", "")[:800],
            }],
            "role": record_summary.get("role", "implementer"),
        },
        "n_examples": 1,
        "evaluator_version": "tau-role-eval@1.0.0+chain-signal",
        "wall_clock_s": float(record_summary.get("wall_clock_s", 0.0) or 0.0),
        "notes": record_summary.get("notes", "chain-emitted signal"),
    }
    sf = runs_dir / "scores.json"
    sf.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    return sf


def drive_admit_cycle(sibling: str, run_timeout_s: int) -> dict:
    """Drive `/hyperagents:step --name <sibling>` through one full
    select → mutate → eval → admit cycle.

    Spawned as a single `claude -p` session that calls the slash command
    repeatedly until `pending.next` settles at `done` or `error`. Returns
    a summary dict including whether a new generation was admitted.
    """
    archive = ARCHIVE_BASE / sibling
    archive_json = archive / "archive.json"
    pending_json = archive / "pending.json"

    before_entries = []
    if archive_json.is_file():
        before_entries = json.loads(archive_json.read_text(encoding="utf-8")).get("entries") or []
    before_count = len(before_entries)

    prompt = (
        f"Drive `/hyperagents:step --name {sibling}` to completion: invoke it "
        f"repeatedly, in sequence, until that sibling's `pending.json` settles "
        f"at `next: done` or `next: error`. Each step is its own slash-command "
        f"invocation. Do not skip steps. Report each step's commit message in "
        f"order, then a final summary line: ADMITTED <new-gen-id> | NO-ADMIT | "
        f"ERROR <message>."
    )
    cmd = [
        "claude", "-p",
        "--output-format", "json",
        "--dangerously-skip-permissions",
    ]
    rc = -1
    stdout = ""
    stderr = ""
    try:
        r = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True,
            timeout=run_timeout_s,
        )
        rc = r.returncode
        # claude -p --output-format json returns a JSON envelope with 'result'
        try:
            obj = json.loads(r.stdout or "")
            stdout = obj.get("result", "") or ""
        except (json.JSONDecodeError, ValueError, TypeError):
            stdout = r.stdout or ""
        stderr = (r.stderr or "")[:800]
    except subprocess.TimeoutExpired as e:
        stdout = (e.stdout or "") if isinstance(e.stdout, str) else (e.stdout or b"").decode("utf-8", "replace")
        stderr = "timeout"

    after_entries = []
    if archive_json.is_file():
        after_entries = json.loads(archive_json.read_text(encoding="utf-8")).get("entries") or []

    admitted = len(after_entries) > before_count
    new_gen_id = after_entries[-1].get("id") if admitted else None
    new_primary = after_entries[-1].get("primary_score") if admitted else None

    return {
        "admitted": admitted,
        "new_gen_id": new_gen_id,
        "new_primary_score": new_primary,
        "rc": rc,
        "before_gen_count": before_count,
        "after_gen_count": len(after_entries),
        "claude_stdout_tail": stdout[-1500:],
        "stderr_tail": stderr,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("task", help="task body text, or '@PATH' to read from file")
    p.add_argument("--implementer", default=None,
                   help="override `<sibling>/<gen-id>` for implementer")
    p.add_argument("--critic", default=None,
                   help="override `<sibling>/<gen-id>` for critic")
    p.add_argument("--reviewer", default=None,
                   help="override `<sibling>/<gen-id>` for reviewer")
    p.add_argument("--run-timeout-s", type=int, default=1500)
    p.add_argument("--stub-mode", action="store_true")
    p.add_argument("--skip-implementer", action="store_true",
                   help="don't run implementer; chain starts from critic on the latest pending record")
    p.add_argument("--no-evolve", action="store_true",
                   help="don't trigger an admit cycle on non-READY ship decisions (default: evolve)")
    p.add_argument("--evolve-timeout-s", type=int, default=5400,
                   help="wall-clock cap for the admit-cycle claude session (default 5400s = 90min)")
    args = p.parse_args()

    task = args.task
    if task.startswith("@"):
        task = Path(task[1:]).read_text()

    # Resolve operators.
    role_paths = {
        "implementer": args.implementer or read_operator("implementer"),
        "critic":      args.critic      or read_operator("critic"),
        "reviewer":    args.reviewer    or read_operator("reviewer"),
    }
    plugin_dirs = {r: plugin_dir_for_strict(rp) for r, rp in role_paths.items()}

    work_dir = REPO / ".claude" / "work-records"

    # Implementer phase
    impl_scores = None
    if not args.skip_implementer:
        out_impl = Path(tempfile.mkdtemp(prefix="chain-impl-"))
        impl_scores, _ = run_role(
            "implementer", plugin_dirs["implementer"], out_impl,
            stub=args.stub_mode, run_timeout_s=args.run_timeout_s,
            task=task,
        )

    record_id = latest_record_id(work_dir)
    print(f"[chain] latest record after implementer: {record_id}")

    # Critic phase
    out_crit = Path(tempfile.mkdtemp(prefix="chain-crit-"))
    crit_scores, _ = run_role(
        "critic", plugin_dirs["critic"], out_crit,
        stub=args.stub_mode, run_timeout_s=args.run_timeout_s,
        max_probes=1,
    )

    # Reviewer phase
    out_rev = Path(tempfile.mkdtemp(prefix="chain-rev-"))
    rev_scores, _ = run_role(
        "reviewer", plugin_dirs["reviewer"], out_rev,
        stub=args.stub_mode, run_timeout_s=args.run_timeout_s,
        max_probes=1,
    )

    # Final summary.
    rec_path = work_dir / record_id if record_id else None
    rec = json.loads(rec_path.read_text()) if (rec_path and rec_path.is_file()) else {}
    impl_b = rec.get("implementer") or {}
    crit_b = rec.get("critic")      or {}
    rev_b  = rec.get("reviewer")    or {}

    print("\n=========================  chain complete  =========================")
    print(f"record:    {record_id}")
    print(f"task:      {(rec.get('task') or {}).get('body','')[:140]}")
    print(f"impl:      gen={impl_b.get('gen_id')}  diff_lines={len((impl_b.get('diff') or '').splitlines())}  files={impl_b.get('files_changed')}")
    print(f"           wall={impl_b.get('wall_clock_s')}s  tokens={impl_b.get('tokens')}  base_sha={impl_b.get('base_sha')}")
    findings = crit_b.get("findings") or []
    blocking = [f for f in findings if (f.get("severity") or "").upper() == "BLOCKING"]
    print(f"critic:    gen={crit_b.get('gen_id')}  findings={len(findings)}  blocking={len(blocking)}  most-important={crit_b.get('single_most_important_id')}")
    print(f"           wall={crit_b.get('wall_clock_s')}s  tokens={crit_b.get('tokens')}  reviewed_base_sha={crit_b.get('reviewed_base_sha')}")
    print(f"reviewer:  gen={rev_b.get('gen_id')}  verdict={rev_b.get('verdict')}  tests={rev_b.get('tests')}")
    print(f"           wall={rev_b.get('wall_clock_s')}s  tokens={rev_b.get('tokens')}  reviewed_base_sha={rev_b.get('reviewed_base_sha')}")
    print(f"\nship decision: ", end="")
    if rev_b.get("verdict") == "PASS" and len(blocking) == 0:
        ship = "READY"
        print("READY (reviewer PASS + no BLOCKING critic findings)")
    elif rev_b.get("verdict") == "PASS" and len(blocking) > 0:
        ship = "HOLD"
        print(f"HOLD (reviewer PASS but {len(blocking)} BLOCKING critic findings unaddressed)")
    elif rev_b.get("verdict") in ("FAIL", "PARTIAL"):
        ship = "BLOCK"
        print(f"BLOCK (reviewer {rev_b.get('verdict')})")
    else:
        ship = "UNKNOWN"
        print("UNKNOWN (no reviewer verdict)")

    # Evolution trigger: a non-READY ship decision IS the signal — pin the
    # task as a regression probe, write the failure as parent_scores, and
    # drive one admit-cycle on the implementer. The mutation candidate is
    # judged against the same task that just failed; if it does better,
    # it replaces the current operator.
    if not args.no_evolve and ship in {"HOLD", "BLOCK"}:
        impl_sibling = role_paths["implementer"].split("/", 1)[0]
        impl_gen     = role_paths["implementer"].split("/", 1)[1]
        sibling_dir  = ARCHIVE_BASE / impl_sibling
        impl_passed  = (ship == "READY")  # by construction here: False
        signal = {
            "primary":      (impl_b.get("passed_count", 0) / max(impl_b.get("tasks_count", 1), 1))
                            if "passed_count" in impl_b else (0.0 if not impl_passed else 1.0),
            "passed":       impl_passed,
            "tokens":       impl_b.get("tokens", 0),
            "wall_clock_s": impl_b.get("wall_clock_s", 0.0),
            "role":         "implementer",
            "why": (
                f"ship={ship}; reviewer={rev_b.get('verdict')}; "
                f"critic BLOCKING={len(blocking)}"
            ),
            "notes": "chain triggered admit cycle on this signal",
        }
        added = pin_task_in_eval_config(sibling_dir, (rec.get("task") or {}).get("body", ""))
        scores_path = write_parent_scores_signal(
            sibling_dir, impl_gen, (rec.get("task") or {}).get("body", ""), signal,
        )
        print(f"\n[chain] evolution trigger: ship={ship}")
        print(f"[chain] eval_config probe { 'appended' if added else 'already present' }")
        print(f"[chain] parent_scores written: {scores_path}")
        print(f"[chain] driving /hyperagents:step --name {impl_sibling}  "
              f"(timeout {args.evolve_timeout_s}s)")
        result = drive_admit_cycle(impl_sibling, args.evolve_timeout_s)
        print(f"[chain] cycle rc={result['rc']}")
        print(f"[chain] gens: {result['before_gen_count']} -> {result['after_gen_count']}")
        if result["admitted"]:
            print(f"[chain] ADMITTED new gen: {result['new_gen_id']} "
                  f"primary={result.get('new_primary_score')}")
        else:
            print(f"[chain] NO admission this cycle")
        tail = result.get("claude_stdout_tail") or ""
        if tail:
            print(f"[chain] cycle tail: {tail[-600:]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

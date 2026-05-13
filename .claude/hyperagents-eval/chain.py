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
        print("READY (reviewer PASS + no BLOCKING critic findings)")
    elif rev_b.get("verdict") == "PASS" and len(blocking) > 0:
        print(f"HOLD (reviewer PASS but {len(blocking)} BLOCKING critic findings unaddressed)")
    elif rev_b.get("verdict") in ("FAIL", "PARTIAL"):
        print(f"BLOCK (reviewer {rev_b.get('verdict')})")
    else:
        print("UNKNOWN (no reviewer verdict)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

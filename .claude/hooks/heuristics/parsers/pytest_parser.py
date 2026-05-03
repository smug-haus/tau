"""pytest output parser — extracts pass/fail/error counts from pytest output."""
import re


def parse(output: str) -> dict:
    """Parse pytest output and return pass/failure counts.

    Returns dict with keys:
      passes  (int): number of passing tests
      failures (int): number of failing tests
      errors  (int): number of errors
    """
    passes = 0
    failures = 0
    errors = 0

    # Match pytest summary line: "===== 5 passed, 2 failed, 1 error in 1.23s ====="
    summary_pattern = re.compile(
        r'=+ .+ =+$', re.MULTILINE
    )
    for line in output.splitlines():
        line = line.strip()
        # Summary line contains "passed", "failed", "error"
        if re.search(r'=+ .+ =+', line):
            m = re.search(r'(\d+) passed', line)
            if m:
                passes = int(m.group(1))
            m = re.search(r'(\d+) failed', line)
            if m:
                failures = int(m.group(1))
            m = re.search(r'(\d+) error', line)
            if m:
                errors = int(m.group(1))

    # Fallback: count PASSED / FAILED in individual test lines if no summary found
    if passes == 0 and failures == 0 and errors == 0:
        for line in output.splitlines():
            if re.search(r'\bPASSED\b', line):
                passes += 1
            elif re.search(r'\bFAILED\b', line):
                failures += 1
            elif re.search(r'\bERROR\b', line):
                errors += 1

    return {"passes": passes, "failures": failures, "errors": errors}

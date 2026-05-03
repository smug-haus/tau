"""vitest output parser — extracts pass/fail counts from Vitest output."""
import re


def parse(output: str) -> dict:
    """Parse Vitest output and return pass/failure counts.

    Returns dict with keys:
      passes   (int): number of passing tests
      failures (int): number of failing tests
    """
    passes = 0
    failures = 0

    for line in output.splitlines():
        line = line.strip()

        # Vitest summary: " Tests  2 failed | 5 passed (7)"
        # Also matches:   " Tests  5 passed (5)"
        if re.match(r'Tests?\s', line) and not re.match(r'Test Files', line):
            m = re.search(r'(\d+) passed', line)
            if m:
                passes = int(m.group(1))
            m = re.search(r'(\d+) failed', line)
            if m:
                failures = int(m.group(1))

        # Fallback: "Test Files" line (suite-level)
        elif re.match(r'Test Files', line) and passes == 0 and failures == 0:
            m = re.search(r'(\d+) passed', line)
            if m:
                passes = int(m.group(1))
            m = re.search(r'(\d+) failed', line)
            if m:
                failures = int(m.group(1))

    # Verbose reporter fallback: count ✓ / × lines
    if passes == 0 and failures == 0:
        for line in output.splitlines():
            stripped = line.strip()
            if re.match(r'[✓✔]', stripped):
                passes += 1
            elif re.match(r'[×✗]', stripped):
                failures += 1

    return {"passes": passes, "failures": failures}

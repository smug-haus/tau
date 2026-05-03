"""jest/mocha output parser — extracts pass/fail counts from Jest or Mocha output."""
import re


def parse(output: str) -> dict:
    """Parse Jest or Mocha output and return pass/failure counts.

    Returns dict with keys:
      passes   (int): number of passing tests
      failures (int): number of failing tests
    """
    passes = 0
    failures = 0

    for line in output.splitlines():
        line = line.strip()

        # Jest format: "Tests:  2 failed, 5 passed, 7 total"
        if re.match(r'Tests:', line):
            m = re.search(r'(\d+) passed', line)
            if m:
                passes = int(m.group(1))
            m = re.search(r'(\d+) failed', line)
            if m:
                failures = int(m.group(1))

        # Jest test suites line (also informative but we prefer Tests: line)
        # "Test Suites: 1 failed, 2 passed, 3 total"
        # Only use if Tests: line not found
        elif re.match(r'Test Suites:', line) and passes == 0 and failures == 0:
            m = re.search(r'(\d+) passed', line)
            if m:
                passes = int(m.group(1))
            m = re.search(r'(\d+) failed', line)
            if m:
                failures = int(m.group(1))

    # Mocha fallback: "X passing" / "X failing"
    if passes == 0 and failures == 0:
        for line in output.splitlines():
            line = line.strip()
            m = re.match(r'(\d+) passing', line)
            if m:
                passes = int(m.group(1))
            m = re.match(r'(\d+) failing', line)
            if m:
                failures = int(m.group(1))

    return {"passes": passes, "failures": failures}

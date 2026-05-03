"""go test output parser — extracts pass/fail counts from `go test` output."""
import re


def parse(output: str) -> dict:
    """Parse `go test` output and return pass/failure counts.

    Returns dict with keys:
      passes   (int): number of passing tests/packages
      failures (int): number of failing tests/packages
    """
    passes = 0
    failures = 0

    for line in output.splitlines():
        line = line.strip()

        # Package-level results
        # "ok  \tgithub.com/foo/bar\t0.123s"
        if re.match(r'^ok\s+\S', line):
            passes += 1
        # "FAIL\tgithub.com/foo/bar\t0.123s"
        elif re.match(r'^FAIL\s+\S', line):
            failures += 1

        # Individual test results
        # "--- PASS: TestFoo (0.00s)"
        elif re.match(r'^--- PASS:', line):
            passes += 1
        # "--- FAIL: TestBar (0.00s)"
        elif re.match(r'^--- FAIL:', line):
            failures += 1

    return {"passes": passes, "failures": failures}

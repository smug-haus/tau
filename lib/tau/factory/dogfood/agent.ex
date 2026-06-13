defmodule Tau.Factory.Dogfood.Agent do
  @moduledoc """
  Scripted deterministic `agent_bin` for the `mix tau.factory.dogfood` harness.

  Writes a real, executable shell script to `dest_path`. The same script
  handles BOTH the oracle (test_author) and implementing phases, detecting
  the phase from the git worktree state:

  **Oracle phase** (detached HEAD at `origin/unit-N`):
    1. Verifies the frozen gating test (`test/sandbox_test.exs`) exists.
    2. Emits the D-326 `work_ready` `{:packet,4}` frame with
       `branch="unit-N"` and the current HEAD SHA.
    3. Exits 0.

  **Implementing phase** (on `unit-N` branch):
    1. Writes `lib/sandbox.ex` implementing `Sandbox.answer/0 returning 42`.
    2. Stages and commits the file.
    3. Emits the D-326 `work_ready` `{:packet,4}` frame.
    4. Exits 0.

  Phase detection: `git rev-parse --abbrev-ref HEAD` returns `"HEAD"` in
  detached mode (oracle) and the branch name in branch mode (implementing).

  ## Why detached HEAD for oracle?

  The oracle Worker checks out `origin/unit-N` (detached HEAD) so it does NOT
  hold the `unit-N` branch lock. This lets the implementing Worker check out
  the named `unit-N` branch immediately after work_ready, without waiting for
  the oracle worktree to be reclaimed — eliminating the `position_unverified`
  race (D-358 / SPEC-FACTORY-CORE §4 B11 workaround).

  ## Binary framing

  Port `{:packet, 4}` framing: the BEAM strips the 4-byte big-endian length
  prefix, so the script must write exactly `<4-byte-BE-len><json-bytes>`.
  We use `python3` temp files for the binary framing — available on all
  supported platforms and avoids POSIX sh octal-escape portability issues.

  All git output is redirected to stderr so the Port's `{:packet, 4}` parser
  only receives the binary packet bytes on stdout.

  This module is a pure functional module — no process state.
  """

  @doc """
  Write the scripted agent executable to `dest_path` and make it executable.

  Returns `dest_path` on success; raises on write failure.
  """
  @spec write(String.t()) :: String.t()
  def write(dest_path) do
    File.write!(dest_path, script_content())
    File.chmod!(dest_path, 0o755)
    dest_path
  end

  # ---------------------------------------------------------------------------
  # Private — script content
  # ---------------------------------------------------------------------------

  defp script_content do
    ~S"""
    #!/bin/sh
    set -e

    # All git output goes to stderr — the Port's {:packet,4} parser sees
    # only the binary packet bytes on stdout.

    # Detect phase from git HEAD state.
    # Detached HEAD ("HEAD") = oracle phase (checked out via origin/unit-N).
    # Named branch = implementing phase (checked out via unit-N local branch).
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

    if [ "$CURRENT_BRANCH" = "HEAD" ]; then
      # -----------------------------------------------------------------------
      # Oracle phase: detached HEAD at origin/unit-N.
      # The gating test is already committed by Sandbox.seed on unit-N.
      # Just verify it exists and emit work_ready.
      # -----------------------------------------------------------------------
      git config user.email "dogfood@tau.test" >&2
      git config user.name "Tau Dogfood Agent" >&2

      # Verify the gating test exists (committed in the sandbox seed).
      if [ ! -f test/sandbox_test.exs ]; then
        echo "[dogfood agent] ERROR: test/sandbox_test.exs not found in oracle checkout" >&2
        exit 1
      fi

      # Emit work_ready with branch="unit-1" (the feature branch, not "HEAD")
      # and the current HEAD SHA (the sandbox seed commit).
      HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
      BRANCH="unit-1"
    else
      # -----------------------------------------------------------------------
      # Implementing phase: on the unit-N branch.
      # Write the production file, commit, and emit work_ready.
      # -----------------------------------------------------------------------
      git config user.email "dogfood@tau.test" >&2
      git config user.name "Tau Dogfood Agent" >&2

      # Write lib/sandbox.ex via a python3 temp file.
      mkdir -p lib
      WRITE_PY=$(mktemp /tmp/dogfood_write_XXXXXX.py)
      cat > "$WRITE_PY" << 'WRITE_PYEOF'
    content = (
        "defmodule Sandbox do\n"
        '  @moduledoc "Sandbox production module seeded by the dogfood harness."\n'
        "\n"
        '  @doc "Returns 42. Seeded by the dogfood scripted agent (P5c-7/AC-12)."\n'
        "  @spec answer() :: integer()\n"
        "  def answer, do: 42\n"
        "end\n"
    )
    open("lib/sandbox.ex", "w").write(content)
    WRITE_PYEOF
      python3 "$WRITE_PY" >&2
      rm -f "$WRITE_PY"

      git add lib/sandbox.ex >&2
      git commit -m "add Sandbox.answer/0 returning 42 (dogfood scripted agent, AC-12)" >&2

      HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
      BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    # Emit the {:packet,4}-framed work_ready JSON via a python3 temp file.
    PACKET_PY=$(mktemp /tmp/dogfood_packet_XXXXXX.py)
    cat > "$PACKET_PY" << 'PACKET_PYEOF'
    import sys, struct
    branch, head_sha = sys.argv[1], sys.argv[2]
    payload = (
        '{"type":"work_ready","branch":"' + branch +
        '","head_sha":"' + head_sha + '"}'
    ).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(payload)) + payload)
    sys.stdout.buffer.flush()
    PACKET_PYEOF
    python3 "$PACKET_PY" "$BRANCH" "$HEAD_SHA"
    rm -f "$PACKET_PY"

    exit 0
    """
  end
end

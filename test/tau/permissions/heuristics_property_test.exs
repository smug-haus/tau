defmodule Tau.Permissions.HeuristicsPropertyTest do
  @moduledoc """
  Property + example coverage for issue #22:
  `Tau.Permissions.Heuristics.destructive_bash?/1` must flag every
  command containing one of the canonical destructive patterns and
  let benign commands through.

  We deliberately accept false positives (e.g. a comment containing
  `rm -rf` would also flag) because the consumer is the
  `:accept_edits` auto-allow gate — a flag flips `:allow` to `:deny`,
  which falls through to an interactive prompt; it never escalates to
  destructive action. False negatives, on the other hand, would
  silently auto-allow a destructive command, so the property is
  "every member of the catalogue, embedded anywhere, is flagged".
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Permissions.Heuristics

  @moduletag :property

  # Canonical destructive patterns. Each entry is a literal string
  # that must trigger the heuristic — these mirror the regex set in
  # `Heuristics`.
  @destructive [
    "rm -r /tmp/x",
    "rm -rf /var/log",
    "rm -f /etc/hosts",
    "sudo apt-get install evil",
    "dd if=/dev/zero of=/dev/sda",
    "mkfs.ext4 /dev/sda1",
    "shred /etc/passwd",
    ":(){ :|:&};:",
    "echo data > /dev/sda",
    "cat /tmp/x > /dev/sdb"
  ]

  # Plausibly-benign commands that must NOT flag.
  @benign [
    "npm test",
    "ls -la",
    "git status",
    "echo hello",
    "mix test",
    "cargo build --release",
    "python -m pytest",
    "make",
    "grep -r foo .",
    "cat README.md"
  ]

  property "every destructive pattern is flagged when embedded in a command" do
    check all(
            base <- StreamData.member_of(@destructive),
            prefix <- StreamData.string(:alphanumeric, max_length: 8),
            suffix <- StreamData.string(:alphanumeric, max_length: 8)
          ) do
      cmd = "#{prefix} #{base} #{suffix}"
      assert Heuristics.destructive_bash?(%{"command" => cmd}),
             "expected destructive flag for: #{inspect(cmd)}"
    end
  end

  property "benign commands are not flagged" do
    check all(cmd <- StreamData.member_of(@benign)) do
      refute Heuristics.destructive_bash?(%{"command" => cmd})
    end
  end

  property "atom :command key is honoured" do
    check all(cmd <- StreamData.member_of(@destructive)) do
      assert Heuristics.destructive_bash?(%{command: cmd})
    end
  end

  describe "examples from issue #22" do
    test "rm -r" do
      assert Heuristics.destructive_bash?(%{"command" => "rm -r /tmp/x"})
    end

    test "rm -f" do
      assert Heuristics.destructive_bash?(%{"command" => "rm -f /etc/hosts"})
    end

    test "rm -rf" do
      assert Heuristics.destructive_bash?(%{"command" => "rm -rf /"})
    end

    test "sudo" do
      assert Heuristics.destructive_bash?(%{"command" => "sudo rm /etc/x"})
    end

    test "dd" do
      assert Heuristics.destructive_bash?(%{"command" => "dd if=/dev/zero of=/dev/sda"})
    end

    test "mkfs" do
      assert Heuristics.destructive_bash?(%{"command" => "mkfs.ext4 /dev/sda1"})
    end

    test "shred" do
      assert Heuristics.destructive_bash?(%{"command" => "shred -u secrets.txt"})
    end

    test "fork bomb" do
      assert Heuristics.destructive_bash?(%{"command" => ":(){ :|:&};:"})
    end

    test "raw disk write" do
      assert Heuristics.destructive_bash?(%{"command" => "echo wipe > /dev/sda"})
    end

    test "raw disk write with whitespace variation" do
      assert Heuristics.destructive_bash?(%{"command" => "cat x >/dev/sdb"})
    end
  end

  describe "non-destructive examples" do
    test "npm test" do
      refute Heuristics.destructive_bash?(%{"command" => "npm test"})
    end

    test "ls -la" do
      refute Heuristics.destructive_bash?(%{"command" => "ls -la"})
    end

    test "git status" do
      refute Heuristics.destructive_bash?(%{"command" => "git status"})
    end

    test "rm without destructive flags is not flagged" do
      # Bare `rm foo.txt` has no `-r` / `-f`, so the heuristic does
      # not fire. Single-file `rm` falls through to `:allow` under
      # `:accept_edits`; that's a deliberate choice — see
      # Heuristics moduledoc on false-positive tolerance.
      refute Heuristics.destructive_bash?(%{"command" => "rm foo.txt"})
    end
  end

  describe "edge cases" do
    test "nil args" do
      refute Heuristics.destructive_bash?(nil)
    end

    test "empty map" do
      refute Heuristics.destructive_bash?(%{})
    end

    test "non-string command value" do
      refute Heuristics.destructive_bash?(%{"command" => 42})
    end

    test "missing command key" do
      refute Heuristics.destructive_bash?(%{"path" => "/tmp/x"})
    end
  end
end

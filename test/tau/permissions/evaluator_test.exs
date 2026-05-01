defmodule Tau.Permissions.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Tau.Permissions.{Evaluator, Parser}

  defp rule_set(perms), do: Parser.compile(perms) |> List.to_tuple()

  describe "deny precedence" do
    test "deny wins over allow regardless of order" do
      rs = rule_set(%{allow: ["Bash"], deny: ["Bash(rm *)"]})
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "rm -rf /"}, %{}) == :deny
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "echo ok"}, %{}) == :allow
    end
  end

  describe "default mode" do
    test "no rules → :ask" do
      assert Evaluator.evaluate({}, "Bash", %{}, %{}) == :ask
    end

    test "blanket allow" do
      rs = rule_set(%{allow: ["Read"]})
      assert Evaluator.evaluate(rs, "Read", %{"path" => "x"}, %{}) == :allow
    end

    test "glob match" do
      rs = rule_set(%{allow: ["Bash(npm *)"]})
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "npm test"}, %{}) == :allow
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "git status"}, %{}) == :ask
    end

    test "ask rule" do
      rs = rule_set(%{ask: ["Write"]})
      assert Evaluator.evaluate(rs, "Write", %{}, %{}) == :ask
    end
  end

  describe "modes" do
    test ":plan only allows Read/Grep/Glob" do
      assert Evaluator.evaluate({}, "Read", %{}, %{}, :plan) == :allow
      assert Evaluator.evaluate({}, "Bash", %{}, %{}, :plan) == :deny
      assert Evaluator.evaluate({}, "Write", %{}, %{}, :plan) == :deny
    end

    test ":bypass allows everything except deny rules" do
      rs = rule_set(%{deny: ["Bash(rm *)"]})
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "rm /"}, %{}, :bypass) == :deny
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "ls"}, %{}, :bypass) == :allow
    end

    test ":dont_ask defaults to deny on no match" do
      assert Evaluator.evaluate({}, "Bash", %{}, %{}, :dont_ask) == :deny
    end

    test ":accept_edits + non-Bash tool retains :ask for unknown tools" do
      # Read/Write/Edit/Grep auto-allow under :accept_edits; anything
      # else (here: WebFetch) falls through to :ask.
      assert Evaluator.evaluate({}, "WebFetch", %{}, %{}, :accept_edits) == :ask
    end

    test ":accept_edits + Bash + destructive command denies" do
      assert Evaluator.evaluate({}, "Bash", %{"command" => "rm -rf /"}, %{}, :accept_edits) ==
               :deny

      assert Evaluator.evaluate({}, "Bash", %{"command" => "sudo apt install"}, %{}, :accept_edits) ==
               :deny

      assert Evaluator.evaluate({}, "Bash", %{"command" => ":(){ :|:&};:"}, %{}, :accept_edits) ==
               :deny
    end

    test ":accept_edits + Bash + non-destructive command allows" do
      assert Evaluator.evaluate({}, "Bash", %{"command" => "npm test"}, %{}, :accept_edits) ==
               :allow

      assert Evaluator.evaluate({}, "Bash", %{"command" => "ls -la"}, %{}, :accept_edits) ==
               :allow
    end

    test ":accept_edits + Bash + missing command falls through to allow" do
      # No command argument means nothing to inspect; the heuristic
      # returns false, so the auto-allow fires. Higher layers should
      # have already rejected calls without a command via the tool
      # schema.
      assert Evaluator.evaluate({}, "Bash", %{}, %{}, :accept_edits) == :allow
    end

    test ":accept_edits respects rule-set deny ahead of heuristic" do
      rs = rule_set(%{deny: ["Bash(npm *)"]})

      assert Evaluator.evaluate(rs, "Bash", %{"command" => "npm test"}, %{}, :accept_edits) ==
               :deny
    end
  end

  describe "matchers" do
    test "domain matcher on WebFetch" do
      rs = rule_set(%{allow: ["WebFetch(domain:github.com)"]})

      assert Evaluator.evaluate(rs, "WebFetch", %{"url" => "https://github.com/x"}, %{}) == :allow

      assert Evaluator.evaluate(rs, "WebFetch", %{"url" => "https://api.github.com/x"}, %{}) ==
               :allow

      assert Evaluator.evaluate(rs, "WebFetch", %{"url" => "https://evil.com/x"}, %{}) == :ask
    end

    test "regex matcher" do
      rs = rule_set(%{deny: ["Bash(re:^sudo)"]})
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "sudo rm"}, %{}) == :deny
      assert Evaluator.evaluate(rs, "Bash", %{"command" => "ls"}, %{}) == :ask
    end
  end
end

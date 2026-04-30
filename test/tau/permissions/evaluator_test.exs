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

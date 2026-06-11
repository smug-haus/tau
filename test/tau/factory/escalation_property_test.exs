defmodule Tau.Factory.EscalationPropertyTest do
  @moduledoc """
  StreamData property suite for `Tau.Factory.Escalation` (SPEC-FACTORY-CORE
  §5, §6 D-317, AC-6).

  Pinned interface:

    `classify(trigger) :: {e, scope}`

    e     ∈ {:"E-RETRY-EXHAUSTED", :"E-AMBIGUITY", :"E-CHALLENGE",
             :"E-DESTRUCTIVE", :"E-BUDGET", :"E-RED-MAIN",
             :"E-CONFLICT", :"E-UNCLASSIFIED"}

    scope ∈ {:unit, :global}

  The classifier MUST be total over `term()`: any input returns `{e, scope}`
  and never raises. Unknown inputs → `{:"E-UNCLASSIFIED", :global}`.

  Known trigger shapes (pinned):

    {:retry_exhausted, _}  → {:"E-RETRY-EXHAUSTED", :unit}
    {:ambiguity, _}        → {:"E-AMBIGUITY", :unit}
    {:challenge, _}        → {:"E-CHALLENGE", :unit}
    {:destructive, _}      → {:"E-DESTRUCTIVE", :unit}   (per-action, treated as :unit)
    {:budget, _}           → {:"E-BUDGET", :global}
    {:red_main, _}         → {:"E-RED-MAIN", :global}
    {:conflict, _}         → {:"E-CONFLICT", :unit}
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  @esc_mod Tau.Factory.Escalation

  # The complete total escalation set E (SPEC-FACTORY-CORE §5 D-317).
  @valid_e_atoms [
    :"E-RETRY-EXHAUSTED",
    :"E-AMBIGUITY",
    :"E-CHALLENGE",
    :"E-DESTRUCTIVE",
    :"E-BUDGET",
    :"E-RED-MAIN",
    :"E-CONFLICT",
    :"E-UNCLASSIFIED"
  ]

  @valid_scopes [:unit, :global]

  # ---------------------------------------------------------------------------
  # Totality property (AC-6 / D-317)
  # ---------------------------------------------------------------------------

  @tag :ac_6
  @tag :d_317
  property "totality: classify/1 returns {e, scope} for any term() and never raises (AC-6 / D-317)" do
    check all(trigger <- StreamData.term()) do
      result =
        try do
          @esc_mod.classify(trigger)
        rescue
          e -> {:raised, e}
        catch
          kind, val -> {:thrown, kind, val}
        end

      assert match?({_, _}, result),
             "classify/1 did not return a 2-tuple for trigger=#{inspect(trigger)}, got #{inspect(result)}"

      refute match?({:raised, _}, result),
             "classify/1 raised for trigger=#{inspect(trigger)}: #{inspect(result)}"

      refute match?({:thrown, _, _}, result),
             "classify/1 threw for trigger=#{inspect(trigger)}: #{inspect(result)}"

      {e, scope} = result

      assert e in @valid_e_atoms,
             "classify/1 returned unknown e=#{inspect(e)} for trigger=#{inspect(trigger)}"

      assert scope in @valid_scopes,
             "classify/1 returned unknown scope=#{inspect(scope)} for trigger=#{inspect(trigger)}"
    end
  end

  @tag :ac_6
  @tag :d_317
  property "totality: unknown/arbitrary triggers map to E-UNCLASSIFIED :global (AC-6 / D-317)" do
    # Generate terms that are NOT any of the known tagged-tuple trigger shapes.
    # We use integer and binary generators which cannot match known 2-tuple triggers.
    check all(
            trigger <-
              StreamData.one_of([
                StreamData.integer(),
                StreamData.binary(),
                StreamData.atom(:alphanumeric),
                StreamData.constant(nil),
                StreamData.constant(:unknown_trigger),
                StreamData.list_of(StreamData.integer(), max_length: 5)
              ])
          ) do
      {e, scope} = @esc_mod.classify(trigger)

      # Unknown triggers must not be misclassified as a known specific reason.
      # They must land in E-UNCLASSIFIED (the catch-all).
      assert e == :"E-UNCLASSIFIED",
             "Expected E-UNCLASSIFIED for non-trigger term=#{inspect(trigger)}, got #{inspect(e)}"

      assert scope == :global,
             "Expected :global scope for E-UNCLASSIFIED, got #{inspect(scope)} for trigger=#{inspect(trigger)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Known-trigger example assertions (AC-6 / D-317)
  # ---------------------------------------------------------------------------

  @tag :ac_6
  @tag :d_317
  test "known trigger {:retry_exhausted, _} → {E-RETRY-EXHAUSTED, :unit} (AC-6 / D-317)" do
    assert @esc_mod.classify({:retry_exhausted, %{pr_id: "pr-42", attempts: 4}}) ==
             {:"E-RETRY-EXHAUSTED", :unit}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:ambiguity, _} → {E-AMBIGUITY, :unit} (AC-6 / D-317)" do
    assert @esc_mod.classify({:ambiguity, "spec gap in SPEC-FACTORY-CORE §4 B2"}) ==
             {:"E-AMBIGUITY", :unit}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:challenge, _} → {E-CHALLENGE, :unit} (AC-6 / D-317)" do
    assert @esc_mod.classify({:challenge, %{upheld_count: 3}}) ==
             {:"E-CHALLENGE", :unit}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:destructive, _} → {E-DESTRUCTIVE, :unit} (AC-6 / D-317)" do
    assert @esc_mod.classify({:destructive, :force_push}) ==
             {:"E-DESTRUCTIVE", :unit}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:budget, _} → {E-BUDGET, :global} (AC-6 / D-317)" do
    assert @esc_mod.classify({:budget, %{dimension: :token, spent: 1_000_000}}) ==
             {:"E-BUDGET", :global}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:red_main, _} → {E-RED-MAIN, :global} (AC-6 / D-317)" do
    assert @esc_mod.classify({:red_main, %{failed_check: "mix test", exit_code: 1}}) ==
             {:"E-RED-MAIN", :global}
  end

  @tag :ac_6
  @tag :d_317
  test "known trigger {:conflict, _} → {E-CONFLICT, :unit} (AC-6 / D-317)" do
    assert @esc_mod.classify({:conflict, "unresolvable merge conflict on main"}) ==
             {:"E-CONFLICT", :unit}
  end

  @tag :ac_6
  @tag :d_317
  test "bare atom :unknown_trigger → {E-UNCLASSIFIED, :global} (AC-6 / D-317)" do
    assert @esc_mod.classify(:unknown_trigger) ==
             {:"E-UNCLASSIFIED", :global}
  end

  @tag :ac_6
  @tag :d_317
  test "nil trigger → {E-UNCLASSIFIED, :global} (AC-6 / D-317)" do
    assert @esc_mod.classify(nil) ==
             {:"E-UNCLASSIFIED", :global}
  end
end

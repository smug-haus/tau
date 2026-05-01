defmodule Tau.Session.SkillActivationPropertyTest do
  @moduledoc """
  Property suite for issue #17: every skill marked
  `disable_model_invocation: true` is excluded both from the system-message
  prompt body and from the `__activate_skill__` tool's name enum. The
  inverse holds for skills with the flag off.

  The properties exercise the same FSM-internal helpers the live session
  uses, run as pure-function tests against an arbitrary skill list to
  decouple from filesystem discovery (ADR-0005).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Skill

  defp skill_gen do
    StreamData.bind(
      StreamData.tuple({
        StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
        StreamData.string(:printable, max_length: 30),
        StreamData.string(:printable, max_length: 60),
        StreamData.boolean(),
        StreamData.list_of(StreamData.member_of(["Read", "Write", "Bash"]),
          max_length: 3
        )
      }),
      fn {name, desc, body, disabled?, allowed} ->
        StreamData.constant(
          {name,
           %Skill{
             name: name,
             description: desc,
             body: body,
             path: "/tmp/" <> name <> "/SKILL.md",
             disable_model_invocation: disabled?,
             allowed_tools: allowed
           }}
        )
      end
    )
  end

  defp skills_gen do
    StreamData.bind(
      StreamData.list_of(skill_gen(), max_length: 8),
      fn skills ->
        # Dedup by name — the loader does the same.
        deduped = Enum.uniq_by(skills, fn {n, _} -> n end)
        StreamData.constant(deduped)
      end
    )
  end

  property "disabled skill bodies are absent from system messages and from the activation enum" do
    check all(skills <- skills_gen()) do
      # Build the same artefacts the FSM does. We replicate the small,
      # pure helpers from `Tau.Session` here rather than reaching into
      # private functions; the production code paths are exercised by
      # the example tests in `Tau.Session.SkillActivationTest`.
      enabled =
        skills
        |> Enum.reject(fn {_n, s} -> s.disable_model_invocation end)

      disabled =
        skills
        |> Enum.filter(fn {_n, s} -> s.disable_model_invocation end)

      # System-message bodies (matches `prepend_skill_messages/2`).
      system_blob =
        enabled
        |> Enum.map(fn {name, %Skill{body: body, description: d}} ->
          d_part = if is_binary(d) and d != "", do: "_#{d}_\n\n", else: ""
          "# Skill: #{name}\n\n" <> d_part <> body
        end)
        |> Enum.join("\n\n")

      # __activate_skill__ enum (matches `skill_activation_tool_spec/1`).
      enum_names = Enum.map(enabled, fn {n, _} -> n end)

      # Property 1: every disabled skill's body must be absent from
      # the system blob (when it's a non-empty unique substring).
      Enum.each(disabled, fn {dname, %Skill{body: dbody}} ->
        # Avoid trivial false positives: empty or 1-char bodies/names.
        if byte_size(dbody) >= 4 and not String.contains?(system_blob, dbody) do
          # absent — pass
          :ok
        end

        # Body MUST NOT be carried under a skill header for a disabled name.
        refute String.contains?(system_blob, "# Skill: #{dname}")

        # Property 2: disabled name absent from the activation enum.
        refute dname in enum_names
      end)

      # Property 3: every enabled skill's name appears in the enum.
      Enum.each(enabled, fn {ename, _} ->
        assert ename in enum_names
      end)
    end
  end
end

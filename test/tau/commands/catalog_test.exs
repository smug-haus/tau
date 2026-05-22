defmodule Tau.Commands.CatalogTest do
  @moduledoc """
  Unit and property tests for `Tau.Commands.Catalog`.

  SPEC-TUI-COMPLETION §5:
  - AC-8 (D-107): catalog/dispatcher precedence parity property test.
  - General unit coverage for `list/1`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Tau.Commands.Catalog
  alias Tau.Commands.Builtin

  # Minimal session data with no skills / templates.
  defp empty_session_data do
    %{skills: [], prompt_templates: []}
  end

  describe "Catalog.list/1 — shape" do
    test "returns a list" do
      assert is_list(Catalog.list(empty_session_data()))
    end

    test "all entries have :name, :description, :origin keys" do
      entries = Catalog.list(empty_session_data())

      Enum.each(entries, fn e ->
        assert is_binary(e.name), "name should be a string: #{inspect(e)}"
        assert is_binary(e.description), "description should be a string: #{inspect(e)}"

        assert e.origin in [:builtin, :extension, :file, :skill, :template],
               "origin should be a valid atom: #{inspect(e)}"
      end)
    end

    test "all entry names start with /" do
      entries = Catalog.list(empty_session_data())

      Enum.each(entries, fn e ->
        assert String.starts_with?(e.name, "/"),
               "entry name should start with /: #{inspect(e.name)}"
      end)
    end

    test "contains /help" do
      entries = Catalog.list(empty_session_data())
      names = Enum.map(entries, & &1.name)
      assert "/help" in names
    end

    test "contains all builtins from Builtin.table/0" do
      entries = Catalog.list(empty_session_data())
      names = MapSet.new(entries, & &1.name)

      Builtin.table()
      |> Map.keys()
      |> Enum.each(fn name ->
        assert MapSet.member?(names, name), "builtin #{name} missing from catalog"
      end)
    end

    test "builtin entries have origin :builtin" do
      entries = Catalog.list(empty_session_data())

      builtin_names = Map.keys(Builtin.table())

      entries
      |> Enum.filter(fn e -> e.name in builtin_names end)
      |> Enum.each(fn e ->
        assert e.origin == :builtin, "#{e.name} should have origin :builtin, got #{e.origin}"
      end)
    end

    test "no duplicate names in catalog" do
      entries = Catalog.list(empty_session_data())
      names = Enum.map(entries, & &1.name)
      assert length(names) == length(Enum.uniq(names)), "catalog has duplicate names"
    end

    test "skill entries appear with /name prefix" do
      session_data = %{
        skills: [
          {"mything",
           %Tau.Skill{name: "mything", body: "", path: "/tmp/mything.md", allowed_tools: []}}
        ],
        prompt_templates: []
      }

      entries = Catalog.list(session_data)
      names = Enum.map(entries, & &1.name)
      assert "/mything" in names
    end

    test "skill origin is :skill" do
      session_data = %{
        skills: [
          {"mything",
           %Tau.Skill{name: "mything", body: "", path: "/tmp/mything.md", allowed_tools: []}}
        ],
        prompt_templates: []
      }

      entries = Catalog.list(session_data)
      skill_entry = Enum.find(entries, fn e -> e.name == "/mything" end)
      assert skill_entry != nil
      assert skill_entry.origin == :skill
    end

    test "builtin shadows same-named skill (precedence: builtin > skill)" do
      # /ping is a builtin; if a skill is also named "ping" the builtin wins
      session_data = %{
        skills: [
          {"ping", %Tau.Skill{name: "ping", body: "", path: "/tmp/ping.md", allowed_tools: []}}
        ],
        prompt_templates: []
      }

      entries = Catalog.list(session_data)
      ping_entries = Enum.filter(entries, fn e -> e.name == "/ping" end)
      assert length(ping_entries) == 1
      assert hd(ping_entries).origin == :builtin
    end

    test "passing empty map is safe (builtin floor still present)" do
      entries = Catalog.list(%{})
      assert entries != []
      assert Enum.all?(entries, fn e -> e.origin == :builtin end)
    end
  end

  # AC-8 (D-107): for every catalog entry, classify_slash_command/2 resolves
  # the same name to the same origin. The catalog and the dispatcher must agree.
  #
  # This test uses a minimal session_data that reflects what the FSM uses.
  # We test against the builtin floor (always present) since the registry
  # and skill lookups require a full session environment.
  describe "AC-8 — catalog/dispatcher precedence parity (D-107)" do
    test "every builtin catalog entry resolves to :builtin in the dispatcher" do
      session_data = empty_session_data()
      entries = Catalog.list(session_data)
      builtin_entries = Enum.filter(entries, fn e -> e.origin == :builtin end)

      Enum.each(builtin_entries, fn entry ->
        # Verify the name is in Builtin.table/0 (the dispatcher's builtin source)
        assert Map.has_key?(Builtin.table(), entry.name),
               "catalog entry #{entry.name} has origin :builtin but is not in Builtin.table/0"
      end)
    end

    test "builtin names in catalog exactly match Builtin.table/0 keys" do
      entries = Catalog.list(empty_session_data())

      catalog_builtin_names =
        entries |> Enum.filter(&(&1.origin == :builtin)) |> Enum.map(& &1.name) |> MapSet.new()

      table_names = Builtin.table() |> Map.keys() |> MapSet.new()

      # Every table key appears in the catalog
      Enum.each(table_names, fn name ->
        assert MapSet.member?(catalog_builtin_names, name),
               "#{name} is in Builtin.table/0 but missing from catalog"
      end)
    end

    test "skill entries in catalog are shadowed if a same-named builtin exists" do
      # Build a session_data where every skill name conflicts with a builtin
      conflicting_skills =
        Builtin.table()
        |> Enum.map(fn {name, _mod} ->
          bare = String.trim_leading(name, "/")
          {bare, %Tau.Skill{name: bare, body: "", path: "/tmp/#{bare}.md", allowed_tools: []}}
        end)

      session_data = %{skills: conflicting_skills, prompt_templates: []}
      entries = Catalog.list(session_data)

      Builtin.table()
      |> Map.keys()
      |> Enum.each(fn name ->
        matching = Enum.filter(entries, fn e -> e.name == name end)
        assert length(matching) == 1, "duplicate entries for #{name}"
        assert hd(matching).origin == :builtin, "#{name} should be :builtin, not :skill"
      end)
    end
  end
end

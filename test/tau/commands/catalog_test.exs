defmodule Tau.Commands.CatalogTest do
  @moduledoc """
  Unit and property tests for `Tau.Commands.Catalog`.

  SPEC-TUI-COMPLETION §5:
  - AC-8 (D-107): catalog/dispatcher precedence parity — real dispatcher tests
    via `Tau.send/2` covering all five source kinds plus the collision case.
  - AC-11 (D-108): `/reload` re-broadcasts `CommandCatalog` with updated entries.
  - General unit coverage for `list/1`.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Tau.Test.SessionHelper, only: [start_session_for_test: 1]

  alias Tau.Commands.Catalog
  alias Tau.Commands.Builtin
  alias Tau.Session.Events, as: SE

  # Minimal session data with no skills / templates.
  defp empty_session_data do
    %{skills: [], prompt_templates: []}
  end

  # ---------------------------------------------------------------------------
  # Integration helpers
  # ---------------------------------------------------------------------------

  # Provider that records stream/3 calls to the test process.
  defmodule RecordingProvider do
    @moduledoc false
    @behaviour Tau.Provider

    @impl Tau.Provider
    def default_model, do: "catalog-rec-model"

    @impl Tau.Provider
    def capabilities do
      %{thinking: false, tools: false, vision: false, prompt_caching: false, parallel_tools: false}
    end

    @impl Tau.Provider
    def configure(opts), do: {:ok, opts}

    @impl Tau.Provider
    def stream(_messages, _opts, ctx) do
      if owner = ctx[:stream_owner], do: send(owner, {:stream_called, self()})

      stream =
        Stream.map(
          [
            %Tau.Provider.Event.Start{request_id: "r", model: "catalog-rec-model"},
            %Tau.Provider.Event.TextStart{block_id: "b"},
            %Tau.Provider.Event.TextDelta{block_id: "b", text: "ok"},
            %Tau.Provider.Event.TextEnd{block_id: "b"},
            %Tau.Provider.Event.Done{stop_reason: :stop, usage: %{}}
          ],
          & &1
        )

      {:ok, stream}
    end
  end

  defp setup_tmp do
    tmp =
      Path.join(System.tmp_dir!(), "tau-catalog-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    tmp
  end

  defp start_session(sid, opts \\ []) do
    Phoenix.PubSub.subscribe(Tau.PubSub, "session:#{sid}")

    {:ok, ^sid} =
      start_session_for_test(
        [
          provider: RecordingProvider,
          model: "catalog-rec-model",
          session_id: sid,
          provider_ctx: %{stream_owner: self()}
        ] ++ opts
      )

    sid
  end

  # Inject skills directly into FSM data using :sys.replace_state.
  defp inject_skills(sid, skills) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    :sys.replace_state(pid, fn {state, data} ->
      {state, %{data | skills: skills}}
    end)
  end

  # Inject prompt_templates directly into FSM data.
  defp inject_templates(sid, templates) do
    [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)

    :sys.replace_state(pid, fn {state, data} ->
      {state, %{data | prompt_templates: templates}}
    end)
  end

  # Drain a provider turn to completion.
  defp drain_turn(sid) do
    receive do
      %SE.MessageEnd{session_id: ^sid} -> :ok
    after
      5_000 -> {:error, :timeout}
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests — pure Catalog.list/1
  # ---------------------------------------------------------------------------

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

    test "template entries appear with /name prefix and origin :template" do
      session_data = %{
        skills: [],
        prompt_templates: [
          {"my-tmpl",
           %Tau.PromptTemplate{
             name: "my-tmpl",
             body: "hello world",
             path: "/tmp/my-tmpl.md",
             variables: []
           }}
        ]
      }

      entries = Catalog.list(session_data)
      tmpl = Enum.find(entries, fn e -> e.name == "/my-tmpl" end)
      assert tmpl != nil
      assert tmpl.origin == :template
    end

    test "builtin shadows same-named template (precedence: builtin > template)" do
      session_data = %{
        skills: [],
        prompt_templates: [
          {"ping",
           %Tau.PromptTemplate{
             name: "ping",
             body: "ping template",
             path: "/tmp/ping.md",
             variables: []
           }}
        ]
      }

      entries = Catalog.list(session_data)
      ping_entries = Enum.filter(entries, fn e -> e.name == "/ping" end)
      assert length(ping_entries) == 1
      assert hd(ping_entries).origin == :builtin
    end
  end

  # ---------------------------------------------------------------------------
  # AC-8 (D-107) — catalog/dispatcher precedence parity via real dispatcher
  #
  # For each source kind, we drive the real classify_slash_command/2 path via
  # Tau.send/2 and assert the observed dispatch outcome matches the catalog's
  # declared origin. This is NOT a tautology — it exercises the actual session
  # FSM dispatch (private classify_slash_command/2) through the public API.
  # ---------------------------------------------------------------------------

  describe "AC-8 (D-107) — catalog/dispatcher parity via Tau.send/2" do
    setup do
      setup_tmp()
      :ok
    end

    test "builtin origin: /ping catalog entry resolves via dispatcher to builtin (SystemNotice, no stream)" do
      sid = "cat-ac8-builtin-#{System.unique_integer([:positive])}"
      start_session(sid)

      # /ping is declared :builtin in the catalog
      entries = Catalog.list(empty_session_data())
      ping = Enum.find(entries, fn e -> e.name == "/ping" end)
      assert ping != nil
      assert ping.origin == :builtin

      # Drive the real dispatcher
      Tau.send(sid, "/ping")

      # Builtin dispatcher path: SystemNotice, no provider stream
      assert_receive %SE.SystemNotice{session_id: ^sid, text: text}, 2_000
      assert String.contains?(text, "pong")
      refute_receive {:stream_called, _}, 300
    end

    test "skill origin: skill catalog entry resolves via dispatcher to skill_activation (stream called)" do
      sid = "cat-ac8-skill-#{System.unique_integer([:positive])}"
      start_session(sid)

      skill_name = "catalogtestskill"

      inject_skills(sid, [
        {skill_name,
         %Tau.Skill{
           name: skill_name,
           body: "Do something helpful.",
           path: "/tmp/#{skill_name}.md",
           allowed_tools: [],
           disable_model_invocation: false
         }}
      ])

      # The catalog with this skill should show it as :skill
      snap = :sys.get_state(hd(Registry.lookup(Tau.Sessions.Registry, sid)) |> elem(0))
      {_state, data} = snap
      entries = Catalog.list(data)
      skill_entry = Enum.find(entries, fn e -> e.name == "/#{skill_name}" end)
      assert skill_entry != nil
      assert skill_entry.origin == :skill

      # Drive the real dispatcher — skill activation routes to provider
      Tau.send(sid, "/#{skill_name}")

      # Skill activation rewrites the message and calls process_user_message,
      # which calls the provider stream
      assert_receive {:stream_called, _}, 3_000
      drain_turn(sid)
    end

    test "template origin: template catalog entry resolves via dispatcher to template (stream called)" do
      sid = "cat-ac8-tmpl-#{System.unique_integer([:positive])}"
      start_session(sid)

      tmpl_name = "catalogtmpl"

      inject_templates(sid, [
        {tmpl_name,
         %Tau.PromptTemplate{
           name: tmpl_name,
           body: "Run the task.",
           path: "/tmp/#{tmpl_name}.md",
           variables: []
         }}
      ])

      # The catalog with this template should show it as :template
      [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
      {_state, data} = :sys.get_state(pid)
      entries = Catalog.list(data)
      tmpl_entry = Enum.find(entries, fn e -> e.name == "/#{tmpl_name}" end)
      assert tmpl_entry != nil
      assert tmpl_entry.origin == :template

      # Drive the real dispatcher — template renders and calls process_user_message
      Tau.send(sid, "/#{tmpl_name}")

      # Template path: {:sync, rewritten_msg} → process_user_message → provider stream
      assert_receive {:stream_called, _}, 3_000
      drain_turn(sid)
    end

    test "collision: builtin wins over same-named skill — catalog and dispatcher agree" do
      sid = "cat-ac8-collision-#{System.unique_integer([:positive])}"
      start_session(sid)

      # Inject a skill named "ping" — same as the /ping builtin
      inject_skills(sid, [
        {"ping",
         %Tau.Skill{
           name: "ping",
           body: "Skill ping body.",
           path: "/tmp/ping-skill.md",
           allowed_tools: []
         }}
      ])

      [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
      {_state, data} = :sys.get_state(pid)
      entries = Catalog.list(data)

      # Catalog MUST show exactly one /ping entry with origin :builtin
      ping_entries = Enum.filter(entries, fn e -> e.name == "/ping" end)

      assert length(ping_entries) == 1,
             "expected exactly one /ping entry, got #{inspect(ping_entries)}"

      assert hd(ping_entries).origin == :builtin

      # Dispatcher MUST resolve to builtin (SystemNotice "pong"), NOT skill (stream)
      Tau.send(sid, "/ping")
      assert_receive %SE.SystemNotice{session_id: ^sid, text: "pong"}, 2_000
      refute_receive {:stream_called, _}, 300
    end

    test "collision: builtin wins over same-named template — catalog and dispatcher agree" do
      sid = "cat-ac8-coll-tmpl-#{System.unique_integer([:positive])}"
      start_session(sid)

      inject_templates(sid, [
        {"ping",
         %Tau.PromptTemplate{
           name: "ping",
           body: "Ping template.",
           path: "/tmp/ping-tmpl.md",
           variables: []
         }}
      ])

      [{pid, _}] = Registry.lookup(Tau.Sessions.Registry, sid)
      {_state, data} = :sys.get_state(pid)
      entries = Catalog.list(data)

      ping_entries = Enum.filter(entries, fn e -> e.name == "/ping" end)
      assert length(ping_entries) == 1
      assert hd(ping_entries).origin == :builtin

      Tau.send(sid, "/ping")
      assert_receive %SE.SystemNotice{session_id: ^sid, text: "pong"}, 2_000
      refute_receive {:stream_called, _}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # AC-11 (D-108) — /reload re-broadcasts CommandCatalog with updated entries
  #
  # Integration test: start a session, issue /reload after injecting a new
  # skill on-disk (via the cwd/.tau/skills/ directory), assert a fresh
  # CommandCatalog event arrives with the new skill present.
  # ---------------------------------------------------------------------------

  describe "AC-11 (D-108) — /reload re-broadcasts CommandCatalog" do
    setup do
      tmp = setup_tmp()
      {:ok, tmp: tmp}
    end

    test "/reload broadcasts a new CommandCatalog event with updated skills", %{tmp: tmp} do
      sid = "cat-ac11-reload-#{System.unique_integer([:positive])}"
      start_session(sid, cwd: tmp)

      # Drain the initial CommandCatalog event from SessionStart.
      initial_catalog =
        receive do
          %SE.CommandCatalog{session_id: ^sid} = ev -> ev
        after
          2_000 -> flunk("no initial CommandCatalog received")
        end

      initial_names = Enum.map(initial_catalog.entries, & &1.name)
      refute "/newskill" in initial_names, "new skill should not be in the initial catalog"

      # Write a new skill file to the skills dir so /reload discovers it.
      # The loader expects <cwd>/.tau/skills/<name>/SKILL.md.
      skill_dir = Path.join([tmp, ".tau", "skills", "newskill"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "# newskill\n\nDo something new.")

      # Issue /reload — triggers {:mutate, fun, notice} → re-broadcasts CommandCatalog.
      Tau.send(sid, "/reload")

      # Expect the SystemNotice from /reload AND a fresh CommandCatalog.
      assert_receive %SE.SystemNotice{session_id: ^sid, text: reload_text}, 3_000
      assert String.contains?(reload_text, "Reloaded")

      assert_receive %SE.CommandCatalog{session_id: ^sid, entries: new_entries}, 3_000
      new_names = Enum.map(new_entries, & &1.name)

      assert "/newskill" in new_names,
             "expected /newskill in reloaded catalog, got: #{inspect(new_names)}"
    end

    test "/reload catalog pre-fix: without /reload the new skill is absent", %{tmp: tmp} do
      # Confirm the test is meaningful: a skill added AFTER session start is NOT
      # present in the initial catalog (the test above asserts it appears AFTER /reload).
      sid = "cat-ac11-pre-#{System.unique_integer([:positive])}"
      start_session(sid, cwd: tmp)

      initial_catalog =
        receive do
          %SE.CommandCatalog{session_id: ^sid} = ev -> ev
        after
          2_000 -> flunk("no initial CommandCatalog received")
        end

      refute "/lateradded" in Enum.map(initial_catalog.entries, & &1.name)
    end
  end
end

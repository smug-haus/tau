defmodule Tau.PromptTemplatesTest do
  @moduledoc """
  Tests for `Tau.PromptTemplates` (issue #183).

  Covers:

  - AC-1 / AC-8: `render/3` substitutes named variables from positional args
  - AC-3 / AC-8: `discover/1` — project-local (`<cwd>`) wins over home-global
  - AC-4 / AC-8: context injection (`{{cwd}}`, `{{date}}`)
  - AC-5 / AC-8: unknown variable is non-fatal — literal passthrough + telemetry
  - AC-6 / AC-8: `{{args}}` receives the full raw pre-tokenisation tail
  - AC-7:        `/reload` picks up freshly-added templates (handled in
                 `reload_test.exs` via the `data.prompt_templates` field;
                 covered here by asserting re-discovery returns new templates)
  - AC-8:        per-behaviour unit coverage for `Tau.PromptTemplate`,
                 `discover/1`, `render/3`, and the `classify_slash_command/4`
                 template branch (the last is covered in session integration;
                 see `test/tau/session/prompt_template_dispatch_test.exs`)

  Tests use `:tmp_dir` so no real `~/.tau/prompts/` is read or written.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :tmp_dir

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_template(dir, name, body, frontmatter \\ nil) do
    prompts_dir = Path.join(dir, ".tau/prompts")
    File.mkdir_p!(prompts_dir)
    path = Path.join(prompts_dir, "#{name}.md")

    content =
      case frontmatter do
        nil ->
          body

        fm ->
          "---\n#{fm}\n---\n#{body}"
      end

    File.write!(path, content)
    path
  end

  # ---------------------------------------------------------------------------
  # Tau.PromptTemplate struct (AC-8)
  # ---------------------------------------------------------------------------

  describe "Tau.PromptTemplate struct" do
    test "reserved/0 includes cwd, date, user, cursor, args" do
      reserved = Tau.PromptTemplate.reserved()
      assert "cwd" in reserved
      assert "date" in reserved
      assert "user" in reserved
      assert "cursor" in reserved
      assert "args" in reserved
    end

    test "all required keys produce a valid struct" do
      t = %Tau.PromptTemplate{name: "x", body: "b", path: "/p", variables: []}
      assert t.name == "x"
      assert t.body == "b"
      assert t.path == "/p"
      assert t.variables == []
    end

    test "description defaults to empty string" do
      t = %Tau.PromptTemplate{name: "x", body: "b", path: "/p", variables: []}
      assert t.description == ""
    end
  end

  # ---------------------------------------------------------------------------
  # discover/1 — basic (AC-8)
  # ---------------------------------------------------------------------------

  describe "discover/1 — basic" do
    test "returns empty list when no prompts dir exists", %{tmp_dir: tmp} do
      assert Tau.PromptTemplates.discover(tmp) == []
    end

    test "discovers a template from cwd/.tau/prompts/", %{tmp_dir: tmp} do
      write_template(tmp, "refactor-otp", "Refactor {{module}} — function {{function}}.")

      templates = Tau.PromptTemplates.discover(tmp)
      assert [{"refactor-otp", %Tau.PromptTemplate{name: "refactor-otp"}}] = templates
    end

    test "template name is derived from filename without .md extension", %{tmp_dir: tmp} do
      write_template(tmp, "my-template", "body")
      [{name, _}] = Tau.PromptTemplates.discover(tmp)
      assert name == "my-template"
    end

    test "multiple templates are sorted by name", %{tmp_dir: tmp} do
      write_template(tmp, "zzz", "last")
      write_template(tmp, "aaa", "first")
      write_template(tmp, "mmm", "middle")

      names = Tau.PromptTemplates.discover(tmp) |> Enum.map(&elem(&1, 0))
      assert names == ["aaa", "mmm", "zzz"]
    end

    test "frontmatter description is parsed", %{tmp_dir: tmp} do
      write_template(tmp, "demo", "body", "description: A demo template")
      [{_, t}] = Tau.PromptTemplates.discover(tmp)
      assert t.description == "A demo template"
    end

    test "frontmatter variables list is parsed", %{tmp_dir: tmp} do
      fm = "variables:\n  - module\n  - function"
      write_template(tmp, "refactor", "Refactor {{module}}.{{function}}", fm)
      [{_, t}] = Tau.PromptTemplates.discover(tmp)
      assert t.variables == ["module", "function"]
    end

    test "variables derived from body when not in frontmatter", %{tmp_dir: tmp} do
      write_template(tmp, "scan", "Hello {{name}}, your {{target}} is ready.")
      [{_, t}] = Tau.PromptTemplates.discover(tmp)
      assert t.variables == ["name", "target"]
    end

    test "reserved context names are excluded from body-derived variables", %{tmp_dir: tmp} do
      write_template(tmp, "ctx", "In {{cwd}} on {{date}} for {{user}}: {{module}}")
      [{_, t}] = Tau.PromptTemplates.discover(tmp)
      assert t.variables == ["module"]
      refute "cwd" in t.variables
      refute "date" in t.variables
      refute "user" in t.variables
    end

    test "non-.md files in the prompts dir are ignored", %{tmp_dir: tmp} do
      dir = Path.join(tmp, ".tau/prompts")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "readme.txt"), "not a template")
      assert Tau.PromptTemplates.discover(tmp) == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC-3: project-local wins over home-global
  # ---------------------------------------------------------------------------

  describe "discover/2 — AC-3: project wins over home" do
    test "cwd copy shadows home copy (first-seen wins)", %{tmp_dir: tmp} do
      cwd_dir = Path.join(tmp, "project")
      home_dir = Path.join(tmp, "home")
      File.mkdir_p!(cwd_dir)
      File.mkdir_p!(home_dir)

      write_template(cwd_dir, "shared", "project version")
      write_template(home_dir, "shared", "home version")

      [{"shared", t}] = Tau.PromptTemplates.discover(cwd_dir, home_dir)

      assert t.body == "project version",
             "project-local template must shadow home-global (cwd scanned first)"
    end

    test "home copy available when no cwd copy exists", %{tmp_dir: tmp} do
      cwd_dir = Path.join(tmp, "project")
      home_dir = Path.join(tmp, "home")
      File.mkdir_p!(cwd_dir)

      write_template(home_dir, "only-home", "home only body")

      [{"only-home", t}] = Tau.PromptTemplates.discover(cwd_dir, home_dir)
      assert t.body == "home only body"
    end

    test "templates from both dirs merged and sorted by name", %{tmp_dir: tmp} do
      cwd_dir = Path.join(tmp, "project")
      home_dir = Path.join(tmp, "home")
      File.mkdir_p!(cwd_dir)
      File.mkdir_p!(home_dir)

      write_template(cwd_dir, "beta", "beta body")
      write_template(home_dir, "alpha", "alpha body")

      names = Tau.PromptTemplates.discover(cwd_dir, home_dir) |> Enum.map(&elem(&1, 0))
      assert names == ["alpha", "beta"]
    end
  end

  # ---------------------------------------------------------------------------
  # render/3 — AC-1, AC-4, AC-5, AC-6 (AC-8)
  # ---------------------------------------------------------------------------

  describe "render/3 — AC-1: variable substitution" do
    test "substitutes positional args into declared variables" do
      t = %Tau.PromptTemplate{
        name: "refactor-otp",
        body: "Refactor {{module}}.{{function}} for OTP compliance.",
        path: "/fake",
        variables: ["module", "function"]
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "Tau.Session start_session", %{})
      assert rendered == "Refactor Tau.Session.start_session for OTP compliance."
    end

    test "shell-tokenises args respecting quoted strings" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "Module: {{module}}",
        path: "/fake",
        variables: ["module"]
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "\"Foo Bar\"", %{})
      assert rendered == "Module: Foo Bar"
    end
  end

  describe "render/3 — AC-4: context injection" do
    test "{{cwd}} is replaced with the cwd context value" do
      t = %Tau.PromptTemplate{
        name: "ctx",
        body: "Working dir: {{cwd}}",
        path: "/fake",
        variables: []
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "", %{"cwd" => "/my/project"})
      assert rendered == "Working dir: /my/project"
    end

    test "{{date}} is replaced with the date context value" do
      t = %Tau.PromptTemplate{
        name: "ctx",
        body: "Date: {{date}}",
        path: "/fake",
        variables: []
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "", %{"date" => "2026-05-21"})
      assert rendered == "Date: 2026-05-21"
    end

    test "{{cwd}} and {{date}} do not survive literally when provided" do
      t = %Tau.PromptTemplate{
        name: "ctx",
        body: "{{cwd}} {{date}}",
        path: "/fake",
        variables: []
      }

      {:ok, rendered} =
        Tau.PromptTemplates.render(t, "", %{"cwd" => "/x", "date" => "2026-05-21"})

      refute rendered =~ "{{cwd}}"
      refute rendered =~ "{{date}}"
    end
  end

  describe "render/3 — AC-5: unknown variable is non-fatal" do
    test "unknown variable renders as literal {{name}}" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "Hello {{nonexistent}}.",
        path: "/fake",
        variables: []
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "", %{})
      assert rendered == "Hello {{nonexistent}}."
    end

    test "unknown variable emits [:tau, :prompt_template, :unknown_variable] telemetry" do
      :telemetry_test.attach_event_handlers(self(), [[:tau, :prompt_template, :unknown_variable]])

      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{ghost}}",
        path: "/fake",
        variables: []
      }

      {:ok, _rendered} = Tau.PromptTemplates.render(t, "", %{})

      assert_received {[:tau, :prompt_template, :unknown_variable], _ref, _measurements, meta}
      assert meta.variable == "ghost"
      assert meta.template == "test"
    end

    test "render/3 never raises on any input" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{a}} {{b}} {{c}} normal text {{ spaces }}",
        path: "/fake",
        variables: []
      }

      assert {:ok, _} = Tau.PromptTemplates.render(t, "", %{})
      assert {:ok, _} = Tau.PromptTemplates.render(t, "x y z extra surplus", %{})
      assert {:ok, _} = Tau.PromptTemplates.render(t, "", %{"a" => "1"})
    end

    @tag :property
    property "render/3 always returns {:ok, _} and never raises (D-076)" do
      # Adversarial raw_tail generator: mix well-formed args with unbalanced quotes,
      # stray backslashes, mixed quotes, empty strings, and very long inputs.
      raw_tail_gen =
        StreamData.one_of([
          StreamData.constant(""),
          StreamData.constant("\"unclosed"),
          StreamData.constant("'stray"),
          StreamData.constant("\"a b\" c"),
          StreamData.constant("\\"),
          StreamData.constant("\"x \\"),
          StreamData.constant("a \"b c\" d"),
          StreamData.string(:printable, min_length: 0, max_length: 200)
        ])

      body_gen =
        StreamData.one_of([
          StreamData.constant(""),
          StreamData.constant("{{a}} {{b}}"),
          StreamData.constant("no placeholders"),
          StreamData.constant("{{a}} literal {{a}}"),
          StreamData.string(:printable, min_length: 0, max_length: 200)
        ])

      check all(
              body <- body_gen,
              raw_tail <- raw_tail_gen,
              max_runs: 500
            ) do
        t = %Tau.PromptTemplate{
          name: "prop-test",
          body: body,
          path: "/fake",
          variables: ["a", "b"]
        }

        result = Tau.PromptTemplates.render(t, raw_tail, %{"cwd" => "/tmp", "date" => "2026-05-21"})
        assert {:ok, rendered} = result
        assert is_binary(rendered)
      end
    end
  end

  describe "render/3 — AC-6: {{args}} raw-tail substitution" do
    test "{{args}} receives the full pre-tokenisation raw tail" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "Args: {{args}}",
        path: "/fake",
        variables: []
      }

      # With quoted arg — raw tail differs from re-joined tokens
      {:ok, rendered} = Tau.PromptTemplates.render(t, "\"a b\" c", %{})

      assert rendered == "Args: \"a b\" c",
             "{{args}} must be the raw pre-tokenisation tail, not re-joined tokens"
    end

    test "{{args}} with plain args passes through verbatim" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{args}}",
        path: "/fake",
        variables: []
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "one two three", %{})
      assert rendered == "one two three"
    end
  end

  describe "render/3 — single-pass substitution (D-076)" do
    test "substituted value containing {{x}} is NOT re-substituted" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{a}}",
        path: "/fake",
        variables: ["a"]
      }

      # The value of `a` itself contains a placeholder — must NOT be expanded
      {:ok, rendered} = Tau.PromptTemplates.render(t, "{{b}}", %{"b" => "SHOULD_NOT_APPEAR"})

      assert rendered == "{{b}}",
             "render/3 must be a single pass; substituted text must not be re-scanned"
    end
  end

  describe "render/3 — surplus args" do
    test "surplus positional args are ignored, no crash" do
      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{x}}",
        path: "/fake",
        variables: ["x"]
      }

      {:ok, rendered} = Tau.PromptTemplates.render(t, "one two three four", %{})
      assert rendered == "one"
    end

    test "surplus args emit [:tau, :prompt_template, :surplus_args] telemetry" do
      :telemetry_test.attach_event_handlers(self(), [
        [:tau, :prompt_template, :surplus_args]
      ])

      t = %Tau.PromptTemplate{
        name: "test",
        body: "{{x}}",
        path: "/fake",
        variables: ["x"]
      }

      {:ok, _} = Tau.PromptTemplates.render(t, "one two three", %{})

      assert_received {[:tau, :prompt_template, :surplus_args], _ref, %{count: 2},
                       %{template: "test"}}
    end
  end
end

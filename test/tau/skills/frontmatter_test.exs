defmodule Tau.Skills.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Tau.Skills.Frontmatter

  test "parses a basic frontmatter block" do
    body = """
    ---
    name: deploy
    description: Deploy the app
    ---
    body
    """

    {fm, body_out} = Frontmatter.parse(body)
    assert fm["name"] == "deploy"
    assert fm["description"] == "Deploy the app"
    assert String.trim(body_out) == "body"
  end

  test "parses booleans and quoted strings" do
    body = """
    ---
    name: x
    enabled: true
    disabled: false
    description: "with spaces"
    ---
    body
    """

    {fm, _} = Frontmatter.parse(body)
    assert fm["enabled"] == true
    assert fm["disabled"] == false
    assert fm["description"] == "with spaces"
  end

  test "parses simple lists" do
    body = """
    ---
    paths:
      - "src/**/*.ts"
      - test/**/*.exs
    ---
    body
    """

    {fm, _} = Frontmatter.parse(body)
    assert fm["paths"] == ["src/**/*.ts", "test/**/*.exs"]
  end

  test "no frontmatter returns body unchanged" do
    {fm, body} = Frontmatter.parse("just a body\n")
    assert fm == %{}
    assert body == "just a body\n"
  end
end

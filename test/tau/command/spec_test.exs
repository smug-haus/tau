defmodule Tau.Command.SpecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tau.Command.Spec

  # ---------------------------------------------------------------------------
  # Fixture command modules
  # ---------------------------------------------------------------------------

  defmodule DeployCommand do
    use Tau.Command

    @impl Tau.Command
    def name, do: "/deploy"

    @impl Tau.Command
    def description, do: "Deploy to an environment."

    command_spec do
      arg(:env, required: true)
      flag(:no_cache, default: false)
      option(:branch, default: "main")
    end

    @impl Tau.Command
    def execute(args, _ctx), do: {:replace, inspect(args)}
  end

  defmodule OptionalArgCommand do
    use Tau.Command

    @impl Tau.Command
    def name, do: "/note"

    @impl Tau.Command
    def description, do: "Optional positional."

    command_spec do
      arg(:title, default: "untitled")
    end

    @impl Tau.Command
    def execute(args, _ctx), do: {:replace, inspect(args)}
  end

  defmodule LegacyCommand do
    @behaviour Tau.Command

    @impl Tau.Command
    def name, do: "/legacy"

    @impl Tau.Command
    def description, do: "Old-style command without a spec."

    @impl Tau.Command
    def execute(args, _ctx), do: {:replace, args}
  end

  # ---------------------------------------------------------------------------
  # Macro compiles a spec correctly
  # ---------------------------------------------------------------------------

  describe "command_spec/1" do
    test "compiles to a parameters/0 callback returning the entry list" do
      assert function_exported?(DeployCommand, :parameters, 0)

      assert DeployCommand.parameters() == [
               %{kind: :arg, name: :env, required: true},
               %{kind: :flag, name: :no_cache, default: false},
               %{kind: :option, name: :branch, default: "main"}
             ]
    end

    test "single-entry block compiles" do
      assert OptionalArgCommand.parameters() == [
               %{kind: :arg, name: :title, required: false, default: "untitled"}
             ]
    end

    test "command without a spec does not export parameters/0" do
      refute function_exported?(LegacyCommand, :parameters, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Tokeniser
  # ---------------------------------------------------------------------------

  describe "tokenize/1" do
    test "splits on whitespace" do
      assert Spec.tokenize("a b  c") == {:ok, ["a", "b", "c"]}
    end

    test "empty string → []" do
      assert Spec.tokenize("") == {:ok, []}
    end

    test "double-quoted strings preserve inner whitespace" do
      assert Spec.tokenize(~s(/foo "hello world" --x)) ==
               {:ok, ["/foo", "hello world", "--x"]}
    end

    test "single-quoted strings preserve inner whitespace" do
      assert Spec.tokenize("'a b' c") == {:ok, ["a b", "c"]}
    end

    test "escaped double-quote inside double-quoted string" do
      assert Spec.tokenize(~S("he said \"hi\"")) == {:ok, [~s(he said "hi")]}
    end

    test "unterminated double quote → error" do
      assert Spec.tokenize(~s("oops)) == {:error, :unterminated_quote}
    end

    test "unterminated single quote → error" do
      assert Spec.tokenize("'oops") == {:error, :unterminated_quote}
    end
  end

  # ---------------------------------------------------------------------------
  # Binder
  # ---------------------------------------------------------------------------

  describe "bind/2" do
    test "binds positional, flag, and option" do
      assert {:ok, %{env: "production", no_cache: true, branch: "feature"}} =
               Spec.parse(DeployCommand.parameters(), "production --no-cache --branch=feature")
    end

    test "supports --option <value> form (space-separated)" do
      assert {:ok, %{branch: "feature"}} =
               Spec.parse(DeployCommand.parameters(), "production --branch feature")
    end

    test "--no-<flag> sets the flag to false" do
      assert {:ok, %{no_cache: false}} =
               Spec.parse(DeployCommand.parameters(), "production --no-no_cache")
    end

    test "missing required arg returns {:error, {:missing_arg, name}}" do
      assert {:error, {:missing_arg, :env}} =
               Spec.parse(DeployCommand.parameters(), "--branch=feature")
    end

    test "unknown long flag returns {:error, {:unknown_token, ...}}" do
      assert {:error, {:unknown_token, "--whatever"}} =
               Spec.parse(DeployCommand.parameters(), "production --whatever")
    end

    test "surplus positional returns {:error, {:unknown_token, ...}}" do
      assert {:error, {:unknown_token, "extra"}} =
               Spec.parse(DeployCommand.parameters(), "production extra")
    end

    test "option without a value returns {:error, {:missing_value, name}}" do
      assert {:error, {:missing_value, :branch}} =
               Spec.parse(DeployCommand.parameters(), "production --branch")
    end

    test "explicit value on a flag is rejected" do
      assert {:error, {:unknown_token, "--no_cache"}} =
               Spec.parse(DeployCommand.parameters(), "production --no_cache=foo")
    end

    test "defaults applied when arg/flag/option not given" do
      assert {:ok, %{env: "stage", no_cache: false, branch: "main"}} =
               Spec.parse(DeployCommand.parameters(), "stage")
    end

    test "optional positional with default" do
      assert {:ok, %{title: "untitled"}} =
               Spec.parse(OptionalArgCommand.parameters(), "")
    end

    test "single + double-quoted positional bound verbatim" do
      assert {:ok, %{title: "hello world"}} =
               Spec.parse(OptionalArgCommand.parameters(), ~s("hello world"))
    end
  end

  describe "format_error/1" do
    test "missing_arg" do
      assert Spec.format_error({:missing_arg, :env}) == "Missing required argument: env"
    end

    test "unknown_token" do
      assert Spec.format_error({:unknown_token, "--x"}) == "Unknown argument: --x"
    end

    test "missing_value" do
      assert Spec.format_error({:missing_value, :branch}) ==
               "Option --branch requires a value"
    end

    test "unterminated_quote" do
      assert Spec.format_error(:unterminated_quote) ==
               "Unterminated quoted string in arguments"
    end
  end

  # ---------------------------------------------------------------------------
  # Property: random spec + random tail → either parses or returns a tagged
  # error. Never raises.
  # ---------------------------------------------------------------------------

  @moduletag :property

  defp name_gen do
    StreamData.bind(
      StreamData.string(?a..?z, min_length: 1, max_length: 8),
      fn s -> StreamData.constant(String.to_atom(s)) end
    )
  end

  defp arg_entry_gen do
    StreamData.bind(name_gen(), fn name ->
      StreamData.bind(StreamData.boolean(), fn req ->
        StreamData.constant(%{kind: :arg, name: name, required: req})
      end)
    end)
  end

  defp flag_entry_gen do
    StreamData.bind(name_gen(), fn name ->
      StreamData.constant(%{kind: :flag, name: name, default: false})
    end)
  end

  defp option_entry_gen do
    StreamData.bind(name_gen(), fn name ->
      StreamData.constant(%{kind: :option, name: name, default: nil})
    end)
  end

  defp entry_gen do
    StreamData.one_of([arg_entry_gen(), flag_entry_gen(), option_entry_gen()])
  end

  # Strip duplicate names (the macro can't produce them, and the binder's
  # behaviour with duplicates is unspecified).
  defp spec_gen do
    StreamData.bind(StreamData.list_of(entry_gen(), max_length: 5), fn entries ->
      StreamData.constant(Enum.uniq_by(entries, & &1.name))
    end)
  end

  defp tail_gen do
    StreamData.string(:printable, max_length: 60)
  end

  property "parse/2 always returns {:ok, _} or {:error, _} — never raises" do
    check all(spec <- spec_gen(), tail <- tail_gen(), max_runs: 200) do
      result =
        try do
          Spec.parse(spec, tail)
        rescue
          e -> {:raised, Exception.message(e)}
        end

      assert match?({:ok, %{}}, result) or match?({:error, _}, result),
             "got #{inspect(result)} for spec=#{inspect(spec)} tail=#{inspect(tail)}"
    end
  end

  property "successful parse always populates every spec name as a key" do
    check all(spec <- spec_gen(), tail <- tail_gen(), max_runs: 200) do
      case Spec.parse(spec, tail) do
        {:ok, bound} ->
          for entry <- spec do
            assert Map.has_key?(bound, entry.name),
                   "expected #{inspect(entry.name)} in #{inspect(bound)}"
          end

        {:error, _} ->
          :ok
      end
    end
  end
end

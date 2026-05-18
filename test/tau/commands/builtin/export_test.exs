defmodule Tau.Commands.Builtin.ExportTest do
  @moduledoc """
  Unit tests for `Tau.Commands.Builtin.Export`.
  """
  use ExUnit.Case, async: false

  alias Tau.Commands.Builtin.Export

  setup do
    tmp = Path.join(System.tmp_dir!(), "tau-export-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:tau, :data_dir, tmp)

    on_exit(fn ->
      # Use soft rm_rf — spawned export tasks may still hold the dir open
      # on WSL/Windows when on_exit fires.
      File.rm_rf(tmp)
      Application.delete_env(:tau, :data_dir)
    end)

    {:ok, tmp_dir: tmp}
  end

  describe "name/0" do
    test "returns \"/export\"" do
      assert Export.name() == "/export"
    end
  end

  describe "run/2 — format validation" do
    test "unknown format returns error" do
      data = %{id: "s1", metadata: %{}, messages: []}
      assert {:error, msg} = Export.run("pdf", data)
      assert String.contains?(msg, "Unknown export format: pdf")
    end

    test "empty format defaults to jsonl (returns notice)" do
      data = %{id: "s2", metadata: %{}, messages: []}
      assert {:notice, _} = Export.run("", data)
    end

    test "explicit jsonl format returns notice" do
      data = %{id: "s3", metadata: %{}, messages: []}
      assert {:notice, _} = Export.run("jsonl", data)
    end

    test "explicit html format returns notice" do
      data = %{id: "s4", metadata: %{}, messages: []}
      assert {:notice, _} = Export.run("html", data)
    end

    test "format is case-insensitive" do
      data = %{id: "s5", metadata: %{}, messages: []}
      assert {:notice, _} = Export.run("JSONL", data)
      assert {:notice, _} = Export.run("HTML", data)
    end

    test "unknown format includes the format name in error" do
      data = %{id: "s6", metadata: %{}, messages: []}
      {:error, msg} = Export.run("xml", data)
      assert String.contains?(msg, "xml")
    end
  end

  describe "run/2 — immediate return does not block" do
    test "returns immediately (fire-and-forget dispatch)" do
      data = %{id: "s7", metadata: %{}, messages: []}
      # Should return fast — no blocking write on the calling process.
      {time_us, result} = :timer.tc(fn -> Export.run("jsonl", data) end)
      assert {:notice, _} = result
      # Should be well under 500ms (generous budget for a fire-and-forget)
      assert time_us < 500_000
    end
  end

  describe "behaviour compliance" do
    test "implements Tau.Commands.Builtin" do
      Code.ensure_loaded!(Export)
      assert function_exported?(Export, :name, 0)
      assert function_exported?(Export, :run, 2)
    end
  end
end

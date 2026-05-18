defmodule Tau.BuildTest do
  use ExUnit.Case, async: true

  alias Tau.Build

  describe "version/0" do
    test "returns a binary starting with the app version" do
      app_version = to_string(Application.spec(:tau, :vsn))
      assert is_binary(Build.version())
      assert String.starts_with?(Build.version(), app_version)
    end

    test "matches the semver + optional git-descriptor shape" do
      assert Build.version() =~ ~r/^\d+\.\d+\.\d+(\+[0-9a-f]+(\.dirty)?)?$/
    end

    test "is parseable by Version.parse/1" do
      assert {:ok, %Version{}} = Version.parse(Build.version())
    end
  end

  describe "descriptor/2 (pure)" do
    test "no git → empty suffix" do
      assert Build.descriptor(nil, false) == ""
      assert Build.descriptor(nil, true) == ""
    end

    test "clean tree → +sha" do
      assert Build.descriptor("d4d35ee", false) == "+d4d35ee"
    end

    test "dirty tree → +sha.dirty" do
      assert Build.descriptor("d4d35ee", true) == "+d4d35ee.dirty"
    end

    test "produced suffixes form valid SemVer build metadata" do
      assert {:ok, %Version{}} = Version.parse("0.2.0" <> Build.descriptor("d4d35ee", false))
      assert {:ok, %Version{}} = Version.parse("0.2.0" <> Build.descriptor("d4d35ee", true))
    end
  end
end

defmodule Tau.Build do
  @moduledoc """
  Build provenance — version string stamped with git short-hash at compile time.

  The release version drives Burrito's runtime extraction-cache path
  (`<app>_erts-<erts>_<release-version>`). Stamping the git short-hash
  makes that path unique per commit, so a fresh build is never served from
  a stale extraction.
  """

  # Recompile this module when HEAD moves or the index changes, so the
  # stamped descriptor stays current. Guarded on existence: a Hex package
  # build has no `.git`.
  for path <- [".git/HEAD", ".git/index"], File.exists?(path) do
    @external_resource path
  end

  @doc """
  Pure descriptor builder: maps a `{sha_or_nil, dirty?}` pair to the
  version suffix.

  Clean → `"+<sha>"`, dirty → `"+<sha>.dirty"`, no git → `""`.
  """
  @spec descriptor(String.t() | nil, boolean()) :: String.t()
  def descriptor(nil, _dirty?), do: ""
  def descriptor(sha, true) when is_binary(sha), do: "+" <> sha <> ".dirty"
  def descriptor(sha, false) when is_binary(sha), do: "+" <> sha

  # Compile-time git descriptor. The module body cannot call this module's
  # own functions (they are not compiled yet), so the probe and the
  # descriptor mapping are inlined here — the same compile-ordering
  # constraint `mix.exs` documents for its own `git_descriptor/0`. The
  # `rescue` guarantees the build never fails on a git error; absent git
  # (e.g. a Hex package build) degrades to `""`.
  @git_descriptor (try do
                     if System.find_executable("git") do
                       case System.cmd("git", ["rev-parse", "--short", "HEAD"],
                              stderr_to_stdout: true
                            ) do
                         {sha, 0} ->
                           dirty? =
                             case System.cmd("git", ["status", "--porcelain"],
                                    stderr_to_stdout: true
                                  ) do
                               {out, 0} -> String.trim(out) != ""
                               _ -> false
                             end

                           "+" <> String.trim(sha) <> if(dirty?, do: ".dirty", else: "")

                         _ ->
                           ""
                       end
                     else
                       ""
                     end
                   rescue
                     _ -> ""
                   end)

  @version Mix.Project.config()[:version]

  @doc """
  The full build version: app version plus git descriptor.

  Examples: `"0.2.0+d4d35ee"`, `"0.2.0+d4d35ee.dirty"`, or bare `"0.2.0"`
  when built without git.
  """
  @spec version() :: String.t()
  def version, do: @version <> @git_descriptor
end

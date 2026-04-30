# Generate priv/schemas/settings.schema.json from Tau.Settings.Schema.
#
# Invoked by:    mix tau.gen.schema
# Source:        lib/tau/settings/schema.ex
#
# Output goes to `<app_priv>/schemas/settings.schema.json`. Using
# Application.app_dir/2 (rather than File.cwd!()) keeps the script
# correct regardless of where it's invoked from (`mix run`, `iex -S mix`
# after `cd`, escript, …) — the priv dir is always relative to the
# compiled app, not the user's shell.
#
# The output is gitignored — regenerate locally before opening a
# `.tau/settings.json` in your editor for completion, or wire this
# into a release-build step if you ship the schema with a published
# artifact.

schema = Tau.Settings.Schema.json_schema()

out_dir = Application.app_dir(:tau, "priv/schemas")
out_path = Path.join(out_dir, "settings.schema.json")

File.mkdir_p!(out_dir)
File.write!(out_path, [Jason.encode_to_iodata!(schema, pretty: true), "\n"])

IO.puts("Wrote #{out_path} (#{File.stat!(out_path).size} bytes)")

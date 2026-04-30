# Generate priv/schemas/settings.schema.json from Tau.Settings.Schema.
#
# Invoked by:    mix tau.gen.schema
# Source:        lib/tau/settings/schema.ex
#
# The output is gitignored — regenerate locally before opening a `.tau/settings.json`
# in your editor for completion, or wire this into a release-build step if you ship
# the schema with a published artifact.

schema = Tau.Settings.Schema.json_schema()

out_dir = Path.join(File.cwd!(), "priv/schemas")
out_path = Path.join(out_dir, "settings.schema.json")

File.mkdir_p!(out_dir)
File.write!(out_path, [Jason.encode_to_iodata!(schema, pretty: true), "\n"])

IO.puts("Wrote #{out_path} (#{File.stat!(out_path).size} bytes)")

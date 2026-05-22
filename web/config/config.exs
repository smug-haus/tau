# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tau_web,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint.
# TauWebWeb.Endpoint is the actual Phoenix Endpoint module (phx.new naming convention).
# TauWeb.Endpoint is the canonical public name used in configuration lookups and
# in the SPEC-WEB-DASHBOARD §4 B4 PubSub-reuse contract; both keys carry the
# pubsub_server setting so that `Application.get_env(:tau_web, TauWeb.Endpoint)`
# returns the correct value.
config :tau_web, TauWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TauWebWeb.ErrorHTML, json: TauWebWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tau.PubSub,
  live_view: [signing_salt: "n4BS+YXr"]

# Canonical config key used by SPEC-WEB-DASHBOARD §4 B4 and AC-4 gating test.
config :tau_web, TauWeb.Endpoint, pubsub_server: Tau.PubSub

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tau_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tau_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

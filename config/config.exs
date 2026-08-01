# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :uhuru,
  ecto_repos: [Uhuru.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :uhuru, UhuruWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UhuruWeb.ErrorHTML, json: UhuruWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Uhuru.PubSub,
  live_view: [signing_salt: "qlxbrb3S"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  uhuru: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  uhuru: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Provider adapters — Granville is the default local provider, Together AI
# is an opt-in adapter for stronger models. API keys/secrets are loaded at
# runtime, see config/runtime.exs.
config :uhuru, Uhuru.Providers.Granville,
  socket_path: "/tmp/granville.sock",
  # ranked: true means every request is two model calls (rank+redact, then
  # inference), roughly doubling latency versus a single completion.
  timeout_ms: 120_000

config :uhuru, Uhuru.Providers.Together,
  model: "meta-llama/Llama-3.1-8B-Instruct-Turbo",
  base_url: "https://api.together.xyz/v1",
  timeout_ms: 60_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

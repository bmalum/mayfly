defmodule Mayfly.MixProject do
  use Mix.Project

  @version "1.0.0-rc.1"
  @source_url "https://github.com/bmalum/mayfly"

  def project do
    [
      app: :mayfly,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A lightweight AWS Lambda custom runtime for Elixir",
      package: package(),
      name: "Mayfly",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      releases: releases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :telemetry],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  # Mayfly has no application callback on purpose: nothing starts unless the
  # release's bootstrap runs Mayfly.Boot (or you call Mayfly.start_link/1).
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Used to smoke-test Mayfly.Release against this repository itself
  # (MIX_ENV=test so test/support handlers are compiled in).
  defp releases do
    [
      lambda: [
        steps: [
          &Mayfly.Release.prepare/1,
          :assemble,
          &Mayfly.Release.bootstrap/1,
          &Mayfly.Release.zip/1
        ],
        mayfly: [handler: Mayfly.Test.Handlers.Echo]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Docs" => "https://elixir-aws-lambda.dev/docs"},
      files:
        ~w(lib priv guides layer lambda.Dockerfile .dockerignore mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "mayfly.png",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/deployment.md",
        "guides/layers.md",
        "guides/architecture.md",
        "guides/streaming.md",
        "guides/observability.md",
        "guides/migrating-from-0.x.md"
      ],
      groups_for_extras: [Guides: ~r/guides\/.*/],
      groups_for_modules: [
        "Writing functions": [
          Mayfly.Handler,
          Mayfly.Context,
          Mayfly.Response,
          Mayfly.ErrorPayload
        ],
        Runtime: [
          Mayfly,
          Mayfly.Boot,
          Mayfly.Supervisor,
          Mayfly.Poller,
          Mayfly.RuntimeAPI,
          Mayfly.HTTP
        ],
        Observability: [Mayfly.Telemetry, Mayfly.LogFormatter],
        "Build & local dev": [
          Mayfly.Release,
          Mayfly.LocalRuntime,
          Mix.Tasks.Lambda.Build,
          Mix.Tasks.Lambda.Invoke
        ]
      ],
      assets: %{"mayfly.png" => "assets/mayfly.png"},
      canonical: "https://elixir-aws-lambda.dev/docs"
    ]
  end
end

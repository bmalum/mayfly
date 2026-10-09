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
        plt_add_apps: [:mix, :ex_unit, :telemetry, :inets, :ssl, :public_key],
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts"
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
        ~w(lib priv guides layer skills lambda.Dockerfile .dockerignore mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  # SEO for the published docs site (elixir-aws-lambda.dev/docs).
  defp docs_head(:html) do
    """
    <meta name="description" content="Mayfly documentation: run Elixir on AWS Lambda with a lightweight custom runtime. Handler behaviour, mix release build, Erlang layers, response streaming, Managed Instances, observability.">
    <meta name="robots" content="index, follow">
    <meta name="theme-color" content="#5b21b6">
    <meta property="og:type" content="website">
    <meta property="og:site_name" content="Mayfly – Elixir on AWS Lambda">
    <meta property="og:title" content="Mayfly documentation – Elixir AWS Lambda runtime">
    <meta property="og:description" content="Run Elixir on AWS Lambda: handler behaviour, mix release build, Erlang layers, response streaming, Managed Instances.">
    <meta property="og:image" content="https://elixir-aws-lambda.dev/og-image.png">
    <meta name="twitter:card" content="summary_large_image">
    <link rel="icon" type="image/png" href="https://elixir-aws-lambda.dev/elixir-drop-only.png">
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"TechArticle","isPartOf":{"@type":"WebSite","name":"Mayfly","url":"https://elixir-aws-lambda.dev/"},
     "about":{"@type":"SoftwareSourceCode","name":"Mayfly","codeRepository":"https://github.com/bmalum/mayfly","programmingLanguage":"Elixir","runtimePlatform":"AWS Lambda provided.al2023"},
     "author":{"@type":"Organization","name":"Karrer","url":"https://karrer.solutions"}}
    </script>
    """
  end

  defp docs_head(_), do: ""

  defp docs do
    [
      main: "readme",
      logo: "mayfly.png",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting-started.md",
        "guides/events.md",
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
        "Event sources": [
          Mayfly.Events,
          Mayfly.Events.HTTP,
          Mayfly.Events.HTTP.Request,
          Mayfly.Events.SQS,
          Mayfly.Events.SQS.Record,
          Mayfly.Events.SNS,
          Mayfly.Events.SNS.Record,
          Mayfly.Events.S3,
          Mayfly.Events.S3.Record,
          Mayfly.Events.EventBridge,
          Mayfly.Events.Kinesis,
          Mayfly.Events.Kinesis.Record,
          Mayfly.Events.DynamoDB,
          Mayfly.Events.DynamoDB.Record
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
      canonical: "https://elixir-aws-lambda.dev/docs",
      before_closing_head_tag: &docs_head/1
    ]
  end
end

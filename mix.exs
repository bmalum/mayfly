defmodule Mayfly.MixProject do
  use Mix.Project

  def project do
    [
      app: :mayfly,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      
      # Docs
      name: "Mayfly",
      source_url: "https://github.com/bmalum/mayfly",
      homepage_url: "https://github.com/bmalum/mayfly",
      docs: [
        main: "readme",
        logo: "mayfly.png",
        extras: ["README.md", "CHANGELOG.md", "guides/getting-started.md", "guides/deployment.md"],
        groups_for_extras: [
          "Guides": ~r/guides\/.*/
        ],
        assets: %{"mayfly.png" => "assets/mayfly.png"},
        canonical: "https://elixir-aws-lambda.dev/docs"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Mayfly, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end

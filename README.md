# 🪰 Mayfly - a AWS Custom Elixir Runtime
<img width="20%" align="right" src="./mayfly.png" />

This package makes it easy to run AWS Lambda Functions written in Elixir. A small maintained Lambda Runtime for Elixir hopefully not as annoying as a mayfly itself. This package includes the Elixir Runtime API Implementation and Mix Tasks to get started.

The Elixir runtime client is an experimental package. It is subject to change and intended only for evaluation purposes.


## Getting Started

add Dependency to your Elixir project:

```elixir
def deps do
  [
    {:mayfly, git: "https://github.com/bmalum/mayfly", branch: "main"}}
  ]
end
```

generate the Lambda ZIP: 

```bash
mix lambda.build --zip
```


## Roadmap

- [ ] Build with Docker Image for x86/arm64
- [ ] Build Locally
- [ ] Create ZIP File
- [ ] CDK Sample

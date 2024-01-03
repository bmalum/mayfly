# 🪰 Mayfly - a AWS Custom Elixir Runtime
<img width="20%" align="right" src="https://private-user-images.githubusercontent.com/4885852/293922502-87a6e597-8f7c-45a1-9092-6c8016faf3c5.JPG?jwt=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3MDQyODgwNzYsIm5iZiI6MTcwNDI4Nzc3NiwicGF0aCI6Ii80ODg1ODUyLzI5MzkyMjUwMi04N2E2ZTU5Ny04ZjdjLTQ1YTEtOTA5Mi02YzgwMTZmYWYzYzUuSlBHP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI0MDEwMyUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNDAxMDNUMTMxNjE2WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9MzQ0M2IxZGU2NTMwYzAzZGE1NDk5YzI4NDgxY2FjNjczMWE1NzZmNWFiMGM2MmE1YTRhYjZkYWY2NDhlYjExNyZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QmYWN0b3JfaWQ9MCZrZXlfaWQ9MCZyZXBvX2lkPTAifQ.EQYeXZeXAY6hXRC5INHHgT6RCJukGYsfSkBwDCWdIWk" />

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

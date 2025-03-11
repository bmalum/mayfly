# 🪰 Mayfly - AWS Custom Elixir Runtime
<img width="20%" align="right" src="./mayfly.png" />

Mayfly is a lightweight, efficient AWS Lambda Custom Runtime for Elixir applications. It enables you to run Elixir code in AWS Lambda with minimal overhead and configuration.

## Features

- **Full Elixir Support**: Run any Elixir code in AWS Lambda
- **Simple API**: Easy-to-use interface for Lambda functions
- **Proper Error Handling**: Standardized error reporting
- **Build Tools**: Mix tasks for packaging and deployment

## Installation

Add Mayfly to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mayfly, git: "https://github.com/bmalum/mayfly", branch: "main"}
  ]
end
```

## Usage

### Creating a Lambda Function

1. Create a module with a function that accepts a map and returns `{:ok, result}` or `{:error, reason}`:

```elixir
defmodule MyLambda do
  def handle(payload) do
    # Process the payload
    {:ok, %{message: "Hello from Elixir!", received: payload}}
  end
end
```

2. Build your Lambda package:

```bash
mix lambda.build --zip
```

3. Deploy to AWS Lambda:
   - Upload the generated `lambda.zip` file to AWS Lambda
   - Set the handler environment variable to `Elixir.MyLambda.handle`

### Configuration Options

#### Environment Variables

- `_HANDLER`: The Elixir function to call, in the format `Elixir.Module.function`
- `AWS_LAMBDA_RUNTIME_API`: Set automatically by AWS Lambda

#### Build Options

The `lambda.build` mix task supports the following options:

- `--zip`: Create a ZIP file for deployment
- `--outdir`: Specify the output directory (default: current directory)
- `--docker`: Build using Docker (useful for cross-platform compatibility)

Example:
```bash
mix lambda.build --zip --docker
```

### Error Handling

Mayfly provides standardized error handling for Lambda functions:

1. Return `{:error, reason}` from your handler function
2. Raise an exception (will be caught and formatted properly)

Errors are formatted according to the AWS Lambda error response format.

## Examples

### Basic Handler

```elixir
defmodule Example.Basic do
  def handle(payload) do
    {:ok, %{
      message: "Hello from Elixir!",
      received: payload
    }}
  end
end
```

### Error Handling

```elixir
defmodule Example.WithError do
  def handle(%{"should_fail" => true}) do
    {:error, "Requested failure"}
  end
  
  def handle(%{"raise_error" => true}) do
    raise "Demonstrating error handling"
  end
  
  def handle(payload) do
    {:ok, %{status: "success", payload: payload}}
  end
end
```

## Troubleshooting

### Common Issues

1. **Handler Not Found**: Ensure the `_HANDLER` environment variable is correctly set to `Elixir.Module.function`
2. **Timeout Errors**: Check if your function exceeds the Lambda timeout limit
3. **Memory Issues**: Increase the Lambda memory allocation if needed

## Roadmap

- [ ] Build with Docker Image for x86/arm64
- [ ] Build Locally
- [ ] Create ZIP File
- [ ] CDK Sample

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

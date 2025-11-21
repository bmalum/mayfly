# Getting Started with Mayfly

This guide will walk you through creating your first Elixir Lambda function using Mayfly.

## Prerequisites

- Elixir ~> 1.15 installed
- Mix build tool
- AWS Account with Lambda access
- AWS CLI configured (optional, for deployment)

## Installation

Add Mayfly to your project's dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mayfly, git: "https://github.com/bmalum/mayfly", branch: "main"}
  ]
end
```

Then fetch the dependencies:

```bash
mix deps.get
```

## Creating Your First Lambda Function

### 1. Define Your Handler

Create a new module with a handler function. The handler receives a map (the Lambda event) and returns `{:ok, result}` or `{:error, reason}`:

```elixir
defmodule MyApp.HelloHandler do
  @moduledoc """
  A simple Lambda function that greets the world.
  """

  def handle(event) do
    name = Map.get(event, "name", "World")
    
    {:ok, %{
      message: "Hello, #{name}!",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  end
end
```

### 2. Build Your Lambda Package

Use the provided Mix task to build a deployment package:

```bash
mix lambda.build --zip
```

This will:
- Build a release in the `lambda` environment
- Generate a `bootstrap` script
- Create a `lambda.zip` file ready for deployment

### 3. Deploy to AWS Lambda

#### Using AWS Console

1. Go to the [AWS Lambda Console](https://console.aws.amazon.com/lambda)
2. Click "Create function"
3. Choose "Author from scratch"
4. Configure:
   - **Function name**: `my-elixir-function`
   - **Runtime**: Custom runtime on Amazon Linux 2023
   - **Architecture**: x86_64 (or arm64 if you built with Docker)
5. Click "Create function"
6. In the "Code" section, click "Upload from" → ".zip file"
7. Upload your `lambda.zip` file
8. In "Runtime settings", click "Edit" and set:
   - **Handler**: `Elixir.MyApp.HelloHandler.handle`
9. Click "Save"

#### Using AWS CLI

```bash
# Create the function
aws lambda create-function \
  --function-name my-elixir-function \
  --runtime provided.al2023 \
  --role arn:aws:iam::YOUR_ACCOUNT_ID:role/lambda-execution-role \
  --handler Elixir.MyApp.HelloHandler.handle \
  --zip-file fileb://lambda.zip \
  --timeout 30 \
  --memory-size 512

# Update existing function
aws lambda update-function-code \
  --function-name my-elixir-function \
  --zip-file fileb://lambda.zip
```

### 4. Test Your Function

In the AWS Lambda Console:

1. Click the "Test" tab
2. Create a new test event:
```json
{
  "name": "Elixir Developer"
}
```
3. Click "Test"

You should see a response like:
```json
{
  "message": "Hello, Elixir Developer!",
  "timestamp": "2025-11-21T10:30:00Z"
}
```

## Handler Patterns

### Basic Handler

```elixir
def handle(event) do
  {:ok, %{result: "success"}}
end
```

### With Error Handling

```elixir
def handle(event) do
  case validate(event) do
    :ok -> 
      result = process(event)
      {:ok, result}
    
    {:error, reason} -> 
      {:error, reason}
  end
end
```

### With Pattern Matching

```elixir
def handle(%{"action" => "create"} = event) do
  # Handle create action
  {:ok, %{status: "created"}}
end

def handle(%{"action" => "delete"} = event) do
  # Handle delete action
  {:ok, %{status: "deleted"}}
end

def handle(_event) do
  {:error, "Unknown action"}
end
```

## Environment Variables

Configure your handler using the `_HANDLER` environment variable in Lambda:

```
_HANDLER=Elixir.MyApp.HelloHandler.handle
```

The format is: `Elixir.ModuleName.function_name`

## Next Steps

- Learn about [Deployment Strategies](deployment.html)
- Explore [API Gateway Integration](deployment.html#api-gateway-integration)
- See [Error Handling Best Practices](deployment.html#error-handling)

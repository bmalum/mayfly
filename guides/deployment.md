# Deployment Guide

This guide covers advanced deployment scenarios and best practices for Mayfly Lambda functions.

## Build Options

### Local Build

Build on your local machine (same architecture as Lambda):

```bash
mix lambda.build --zip
```

### Docker Build

Build using Docker for cross-platform compatibility:

```bash
mix lambda.build --docker --zip
```

This ensures your build matches the Lambda execution environment exactly.

### Custom Output Directory

Specify where to save the build artifacts:

```bash
mix lambda.build --zip --outdir ./deploy
```

## API Gateway Integration

When integrating with API Gateway, structure your responses according to the proxy integration format:

```elixir
defmodule MyApp.ApiHandler do
  def handle(event) do
    # Extract request details
    path = event["path"]
    method = event["httpMethod"]
    body = event["body"]
    
    # Process request
    response_body = process_request(method, path, body)
    
    # Return API Gateway proxy response
    {:ok, %{
      statusCode: 200,
      headers: %{
        "Content-Type" => "application/json",
        "Access-Control-Allow-Origin" => "*"
      },
      body: Jason.encode!(response_body)
    }}
  end
  
  defp process_request("GET", "/users", _body) do
    %{users: ["Alice", "Bob"]}
  end
  
  defp process_request("POST", "/users", body) do
    user = Jason.decode!(body)
    %{created: user}
  end
  
  defp process_request(_method, _path, _body) do
    %{error: "Not found"}
  end
end
```

### Handling Different HTTP Methods

```elixir
def handle(%{"httpMethod" => "GET"} = event) do
  handle_get(event)
end

def handle(%{"httpMethod" => "POST"} = event) do
  handle_post(event)
end

def handle(%{"httpMethod" => "PUT"} = event) do
  handle_put(event)
end

def handle(%{"httpMethod" => "DELETE"} = event) do
  handle_delete(event)
end
```

## Error Handling

### Returning Errors

Return errors using the standard tuple format:

```elixir
def handle(event) do
  case validate_input(event) do
    :ok -> 
      {:ok, process(event)}
    
    {:error, message} -> 
      {:error, message}
  end
end
```

Mayfly will automatically format errors according to Lambda's error response format:

```json
{
  "errorType": "RuntimeError",
  "errorMessage": "Invalid input",
  "stackTrace": "..."
}
```

### Raising Exceptions

You can also raise exceptions, which Mayfly will catch and format:

```elixir
def handle(event) do
  unless Map.has_key?(event, "required_field") do
    raise "Missing required field"
  end
  
  {:ok, process(event)}
end
```

### Custom Error Types

Define custom error structs for better error handling:

```elixir
defmodule MyApp.ValidationError do
  defexception [:message, :field]
end

def handle(event) do
  case validate(event) do
    :ok -> 
      {:ok, process(event)}
    
    {:error, field} -> 
      raise MyApp.ValidationError, 
        message: "Validation failed", 
        field: field
  end
end
```

## Event Sources

### S3 Events

```elixir
defmodule MyApp.S3Handler do
  def handle(%{"Records" => records}) do
    results = Enum.map(records, fn record ->
      bucket = get_in(record, ["s3", "bucket", "name"])
      key = get_in(record, ["s3", "object", "key"])
      
      process_s3_object(bucket, key)
    end)
    
    {:ok, %{processed: length(results)}}
  end
end
```

### EventBridge Events

```elixir
defmodule MyApp.EventBridgeHandler do
  def handle(%{"detail-type" => detail_type, "detail" => detail}) do
    case detail_type do
      "Order Placed" -> 
        process_order(detail)
      
      "User Registered" -> 
        process_registration(detail)
      
      _ -> 
        {:ok, %{status: "ignored"}}
    end
  end
end
```

### SQS Events

```elixir
defmodule MyApp.SqsHandler do
  def handle(%{"Records" => records}) do
    results = Enum.map(records, fn record ->
      body = record["body"] |> Jason.decode!()
      process_message(body)
    end)
    
    {:ok, %{
      batchItemFailures: []  # Return failed message IDs for retry
    }}
  end
end
```

## Performance Optimization

### Memory Configuration

Start with 512MB and adjust based on your function's needs:

```bash
aws lambda update-function-configuration \
  --function-name my-function \
  --memory-size 1024
```

More memory also means more CPU power.

### Timeout Configuration

Set appropriate timeouts (default is 3 seconds):

```bash
aws lambda update-function-configuration \
  --function-name my-function \
  --timeout 30
```

### Cold Start Optimization

- Keep dependencies minimal
- Use provisioned concurrency for critical functions
- Consider Lambda SnapStart (when available for custom runtimes)

## Environment Variables

Set environment variables for configuration:

```bash
aws lambda update-function-configuration \
  --function-name my-function \
  --environment Variables="{
    _HANDLER=Elixir.MyApp.Handler.handle,
    DATABASE_URL=postgres://...,
    API_KEY=secret123
  }"
```

Access in your code:

```elixir
def handle(event) do
  db_url = System.get_env("DATABASE_URL")
  api_key = System.get_env("API_KEY")
  
  # Use configuration
  {:ok, process(event, db_url, api_key)}
end
```

## Monitoring and Logging

### Structured Logging

Use Logger for structured logging:

```elixir
require Logger

def handle(event) do
  Logger.info("Processing event", event_type: event["type"])
  
  result = process(event)
  
  Logger.info("Event processed successfully", 
    event_type: event["type"],
    duration_ms: 123
  )
  
  {:ok, result}
end
```

Logs appear in CloudWatch Logs automatically.

### Metrics

Track custom metrics using CloudWatch:

```elixir
def handle(event) do
  start_time = System.monotonic_time(:millisecond)
  
  result = process(event)
  
  duration = System.monotonic_time(:millisecond) - start_time
  Logger.info("MONITORING|#{duration}|milliseconds|ProcessingTime")
  
  {:ok, result}
end
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Deploy Lambda

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26'
      
      - name: Install dependencies
        run: mix deps.get
      
      - name: Build Lambda package
        run: mix lambda.build --docker --zip
      
      - name: Deploy to AWS
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
        run: |
          aws lambda update-function-code \
            --function-name my-function \
            --zip-file fileb://lambda.zip
```

## Best Practices

1. **Keep handlers simple** - Move business logic to separate modules
2. **Use pattern matching** - Handle different event types cleanly
3. **Return early** - Validate input and return errors quickly
4. **Log appropriately** - Use structured logging for better observability
5. **Test locally** - Write unit tests for your handler logic
6. **Monitor performance** - Track cold starts and execution times
7. **Handle errors gracefully** - Always return proper error responses
8. **Use environment variables** - Keep configuration out of code
9. **Version your functions** - Use Lambda versions and aliases
10. **Set appropriate timeouts** - Don't use default 3s for long-running tasks

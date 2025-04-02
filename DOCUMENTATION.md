# Mayfly Documentation

This document provides detailed information about using the Mayfly Elixir runtime for AWS Lambda.

## Architecture

Mayfly implements the [AWS Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html) to enable Elixir code to run in AWS Lambda. The runtime:

1. Starts an Elixir application
2. Polls the Lambda Runtime API for invocations
3. Executes the specified handler function
4. Returns the result to the Lambda Runtime API

## Core Components

### AWSLambda

The main application module that starts the supervision tree and initializes the Lambda event loop.

### AWSLambda.Loop

A GenServer that continuously polls for new invocations and processes them. It:
- Fetches invocations from the Lambda Runtime API
- Resolves and executes the handler function
- Sends responses back to the Lambda Runtime API

### AWSLambda.Runtime

Handles communication with the AWS Lambda Runtime API, providing functions for:
- Fetching invocations
- Sending successful responses
- Reporting errors

### AWSLambda.Handler

Manages handler resolution and execution:
- Resolves the handler module and function from environment variables
- Executes the handler function with proper error handling
- Provides a default handler when none is specified

### AWSLambda.Error

Provides standardized error handling and formatting:
- Converts various error types to a standardized Lambda error format
- Formats stacktraces for error reporting

## Handler Function

Your handler function should:

1. Accept a single map parameter (the decoded JSON payload)
2. Return either `{:ok, result}` or `{:error, reason}`

Example:

```elixir
def my_handler(payload) do
  case process_data(payload) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
  end
end
```

## Deployment Process

1. **Build**: `mix lambda.build --zip` creates a deployment package
2. **Deploy**: Upload the ZIP file to AWS Lambda
3. **Configure**: Set the handler environment variable

### Detailed Deployment Steps

1. Add Mayfly to your dependencies:
   ```elixir
   def deps do
     [
       {:mayfly, git: "https://github.com/bmalum/mayfly", branch: "main"}
     ]
   end
   ```

2. Create your handler function:
   ```elixir
   defmodule MyApp.Handler do
     def process(payload) do
       # Your business logic here
       {:ok, %{result: "Success", data: transformed_data}}
     end
   end
   ```

3. Build the Lambda package:
   ```bash
   mix lambda.build --zip
   ```

4. Create a Lambda function in AWS:
   - Runtime: Custom runtime
   - Handler: `Elixir.MyApp.Handler.process`
   - Upload the generated `lambda.zip` file

## Advanced Usage

### Custom Error Types

You can define custom error types for better error reporting:

```elixir
defmodule MyApp.ValidationError do
  defexception message: "Validation failed"
end

def handler(payload) do
  case validate(payload) do
    :ok -> {:ok, process(payload)}
    {:error, reason} -> raise MyApp.ValidationError, message: reason
  end
end
```

### Handling Binary Data

To handle binary data in responses:

```elixir
def generate_image(payload) do
  # Generate image data
  image_data = create_image(payload)
  
  {:ok, %{
    isBase64Encoded: true,
    body: Base.encode64(image_data),
    headers: %{"Content-Type" => "image/png"}
  }}
end
```

### API Gateway Integration

When integrating with API Gateway, structure your response like this:

```elixir
def api_handler(payload) do
  {:ok, %{
    statusCode: 200,
    headers: %{
      "Content-Type" => "application/json"
    },
    body: Jason.encode!(%{message: "Hello from Elixir!"})
  }}
end
```

## Environment Variables

- `_HANDLER`: The Elixir function to call, in the format `Elixir.Module.function`
- `AWS_LAMBDA_RUNTIME_API`: Set automatically by AWS Lambda
- `LOGLEVEL`: Set to `debug` for more verbose logging (optional)

## Troubleshooting

### Common Issues

1. **Handler Not Found**: Ensure the `_HANDLER` environment variable is correctly set to `Elixir.Module.function`
2. **Timeout Errors**: Check if your function exceeds the Lambda timeout limit
3. **Memory Issues**: Increase the Lambda memory allocation if needed
4. **Cold Start Performance**: Consider increasing the memory allocation to improve cold start times

### Debugging

To enable debug logging, set the `LOGLEVEL` environment variable to `debug`.

### Common Error Messages

- **"Handler not found"**: The specified handler module or function doesn't exist
- **"Invalid response format"**: The handler function returned an invalid response format
- **"Initialization error"**: An error occurred during the Lambda initialization phase

## Best Practices

1. **Keep Functions Small**: Focus on a single responsibility
2. **Handle Errors Properly**: Always return `{:ok, result}` or `{:error, reason}`
3. **Validate Input**: Always validate and sanitize input data
4. **Use Proper Logging**: Use Logger for debugging and monitoring
5. **Optimize Cold Starts**: Minimize dependencies and code size
6. **Use Environment Variables**: For configuration and secrets
7. **Test Locally**: Test your functions locally before deployment

## Performance Considerations

- **Memory Allocation**: Higher memory allocation also means more CPU power
- **Cold Starts**: First invocation will be slower due to the JVM startup time
- **Connection Pooling**: Reuse connections for external services
- **Stateless Design**: Don't rely on state between invocations

## Security Considerations

- **Input Validation**: Always validate and sanitize input data
- **Secrets Management**: Use environment variables or AWS Secrets Manager
- **Least Privilege**: Use IAM roles with minimal permissions
- **Dependency Scanning**: Regularly scan dependencies for vulnerabilities

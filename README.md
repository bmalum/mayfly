# 🪰 Mayfly

<div align="center">
  <img width="300" src="./mayfly.png" alt="Mayfly Logo"/>
  <h3>A lightweight AWS Lambda Custom Runtime for Elixir</h3>
  
  ![Version](https://img.shields.io/badge/version-0.1.0-blue)
  ![Elixir](https://img.shields.io/badge/elixir-%3E%3D%201.15-blueviolet)
  ![License](https://img.shields.io/badge/license-MIT-green)
</div>

## Why Mayfly?

**Mayfly** lets you leverage the full power of Elixir in AWS Lambda without compromise. Run your Elixir code in a serverless environment with:

- **Zero Boilerplate** - Focus on your business logic, not Lambda implementation details
- **Native Elixir Experience** - Use the same coding patterns and libraries you love
- **Optimized Performance** - Designed specifically for Elixir's strengths in AWS Lambda
- **Proper Error Handling** - Get meaningful stack traces and error reports

Unlike generic custom runtimes, Mayfly is purpose-built for Elixir, bringing the language's reliability and expressiveness to serverless functions.

## Quick Start

```elixir
# 1. Add Mayfly to your dependencies
# In mix.exs
def deps do
  [
    {:mayfly, github: "bmalum/mayfly"}
  ]
end

# 2. Create your handler function
defmodule MyFunction do
  def handle(event) do
    {:ok, %{message: "Hello from Elixir!", event: event}}
  end
end

# 3. Build and deploy
# Terminal
$ mix lambda.build --zip
# Upload lambda.zip to AWS Lambda and set handler to "Elixir.MyFunction.handle"
```

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Configuration](#configuration)
- [Error Handling](#error-handling)
- [Deployment](#deployment)
- [Performance](#performance)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Community & Contributing](#community--contributing)
- [License](#license)

## Features

- **Full Elixir Support**: Run any Elixir code in AWS Lambda, including GenServers and OTP applications
- **Simple API**: Clean, idiomatic interface for Lambda functions with minimal boilerplate
- **Robust Error Handling**: Get meaningful error reports with proper Elixir stacktraces
- **Build Tooling**: Mix tasks for packaging and deployment with Docker and local build support
- **Flexible Integration**: Works seamlessly with API Gateway, S3, EventBridge and other AWS services

## Requirements

- Elixir ~> 1.15
- AWS Account with Lambda access
- Mix

## Installation

Add Mayfly to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mayfly, github: "bmalum/mayfly"}
  ]
end
```

Run `mix deps.get` to fetch the dependency.

## Usage

### Creating a Lambda Function

1. **Define your handler function**

   Create a module with a function that accepts a map and returns `{:ok, result}` or `{:error, reason}`:

   ```elixir
   defmodule MyLambda do
     def handle(payload) do
       # Process the payload
       {:ok, %{message: "Hello from Elixir!", received: payload}}
     end
   end
   ```

2. **Build your Lambda package**

   ```bash
   mix lambda.build --zip
   ```

3. **Deploy to AWS Lambda**
   - Create a new Lambda function in the AWS Console
   - Select "Custom runtime" as the runtime
   - Upload the generated `lambda.zip` file
   - Set the handler environment variable to `Elixir.MyLambda.handle`

### Advanced Examples

#### API Gateway Integration

When integrating with API Gateway, structure your response like this:

```elixir
defmodule Api.Handler do
  def process(event) do
    {:ok, %{
      statusCode: 200,
      headers: %{
        "Content-Type" => "application/json"
      },
      body: Jason.encode!(%{
        message: "Hello from Elixir!",
        path: event["path"],
        method: event["httpMethod"]
      })
    }}
  end
end
```

#### Error Handling

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

#### Handling Binary Data

```elixir
defmodule ImageGenerator do
  def generate(payload) do
    # Generate image data
    image_data = create_image(payload)
    
    {:ok, %{
      isBase64Encoded: true,
      body: Base.encode64(image_data),
      headers: %{"Content-Type" => "image/png"}
    }}
  end
  
  defp create_image(payload) do
    # Implementation details...
  end
end
```

## Documentation

### Online Documentation

Full documentation with guides and API reference is available:

- **[Getting Started Guide](guides/getting-started.md)** - Step-by-step tutorial for your first Lambda function
- **[Deployment Guide](guides/deployment.md)** - Advanced deployment scenarios and best practices
- **[API Reference](https://hexdocs.pm/mayfly)** - Complete module and function documentation

### Generate Documentation Locally

Generate and view the documentation on your machine:

```bash
mix docs
open doc/index.html
```

### Quick Links

- [Handler Patterns](guides/getting-started.md#handler-patterns)
- [API Gateway Integration](guides/deployment.md#api-gateway-integration)
- [Error Handling](guides/deployment.md#error-handling)
- [Event Sources](guides/deployment.md#event-sources)
- [Performance Optimization](guides/deployment.md#performance-optimization)

## Configuration

### Environment Variables

- `_HANDLER`: Required - The Elixir function to call, in the format `Elixir.Module.function`
- `AWS_LAMBDA_RUNTIME_API`: Automatically set by AWS Lambda
- `LOGLEVEL`: Optional - Set to `debug` for more verbose logging

### Build Options

The `lambda.build` mix task supports the following options:

- `--zip`: Create a ZIP file for deployment
- `--outdir`: Specify the output directory (default: current directory)
- `--docker`: Build using Docker (useful for cross-platform compatibility)

Example:
```bash
mix lambda.build --zip --docker
```

### Custom Docker Build Environment

You can provide your own `lambda.Dockerfile` in your project root to customize the build environment. This is useful when:
- Your dependencies require specific system libraries
- You need a different Erlang/Elixir version
- You want to add native dependencies for NIFs

Create a `lambda.Dockerfile` in your project root:
```dockerfile
FROM amazonlinux:2023

# Add your custom system dependencies
RUN yum install -y imagemagick-devel libxml2-devel

# Install Erlang/Elixir (customize versions as needed)
RUN yum install -y wget tar gcc make && \
    wget https://github.com/erlang/otp/releases/download/OTP-27.2/otp_src_27.2.tar.gz && \
    tar -zxf otp_src_27.2.tar.gz && \
    cd otp_src_27.2 && \
    ./configure --without-javac && \
    make -j$(nproc) && make install && \
    cd / && rm -rf otp_src_27.2*

ENV MIX_ENV=lambda
WORKDIR /mnt/code
RUN mix local.rebar --force && mix local.hex --force
```

If no `lambda.Dockerfile` is found in your project, Mayfly will use the default one from the library.

## Error Handling

Mayfly provides standardized error handling for Lambda functions:

1. **Return `{:error, reason}`**: For expected errors
   ```elixir
   def handle(payload) do
     case validate(payload) do
       :ok -> {:ok, process(payload)}
       {:error, reason} -> {:error, reason}
     end
   end
   ```

2. **Raise an exception**: For unexpected errors
   ```elixir
   def handle(payload) do
     # This will be caught and formatted properly
     result = payload["a"] + payload["b"]
     {:ok, %{sum: result}}
   end
   ```

Errors are formatted according to the AWS Lambda error response format with proper stacktraces.

## Deployment

### Detailed Deployment Steps

1. **Build the Lambda package**:
   ```bash
   mix lambda.build --zip
   ```

2. **Create a new Lambda function**:
   - Open the AWS Lambda Console
   - Click "Create function"
   - Choose "Author from scratch"
   - Name your function
   - Select "Custom runtime" for Runtime
   - Create or select an execution role
   - Click "Create function"

3. **Upload the deployment package**:
   - In the Function code section, click "Upload from"
   - Select ".zip file"
   - Upload the generated `lambda.zip` file
   - Click "Save"

4. **Configure the handler**:
   - In the Runtime settings section, click "Edit"
   - Set the Handler to `Elixir.YourModule.function_name`
   - Click "Save"

5. **Test your function**:
   - Click "Test"
   - Configure a test event
   - Click "Test" to invoke your function

## Performance

### Optimizing Cold Starts

- Increase memory allocation (which also increases CPU power)
- Minimize dependencies in your application
- Consider provisioned concurrency for critical functions

### Memory and Timeout Configuration

- Start with at least 512MB of memory for reasonable performance
- Adjust timeout based on your function's processing needs
- Monitor execution times to fine-tune these settings

## Troubleshooting

### Common Issues

1. **Handler Not Found**: Ensure the `_HANDLER` environment variable is correctly set to `Elixir.Module.function`
2. **Timeout Errors**: Check if your function exceeds the Lambda timeout limit
3. **Memory Issues**: Increase the Lambda memory allocation if needed
4. **Cold Start Performance**: Consider increasing the memory allocation to improve cold start times

### Debugging Tips

- Set `LOGLEVEL` environment variable to `debug` for verbose logging
- Review CloudWatch logs for detailed error information
- Test locally before deployment when possible

## Roadmap

- [ ] Build with Docker Image for x86/arm64
- [ ] Build Locally
- [ ] Create ZIP File
- [ ] CDK Sample
- [ ] HexDocs and Hex.pm publishing
- [ ] GitHub Actions CI/CD templates
- [ ] Performance benchmarks and optimizations
- [ ] Framework integrations (Phoenix, etc.)

## Community & Contributing

We welcome contributions of all kinds! Here's how you can help:

- **Bug Reports**: Open an issue describing the bug and how to reproduce it
- **Feature Requests**: Open an issue describing the desired feature
- **Code Contributions**: Submit a pull request with your changes
- **Documentation**: Help improve or translate documentation
- **Examples**: Share how you're using Mayfly in your projects

Before contributing, please review our:
- Code of Conduct (link)
- Contributing Guidelines (link)

## License

Mayfly is licensed under the MIT License. See the LICENSE file for details.

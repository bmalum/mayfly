# Deployment

## Choosing how ERTS gets to Lambda

| | ERTS layer (`layer: true`) | Bundled ERTS |
|---|---|---|
| Zip size | 1–5 MB | 25–50 MB |
| Build host | any OS, no Docker | Amazon Linux 2023 or `--docker` |
| Build time | seconds | seconds + one-off 20–40 min image build |
| NIF dependencies | need the layer *and* Linux-built NIFs (`--docker`) | works |
| OTP version | must equal the layer's OTP version exactly (checked at start) | whatever you build with |

Recommendation: layer for everything without NIFs; bundled ERTS via Docker
otherwise. Public layer ARNs and the naming scheme are in [layers.md](layers.md).

## Release configuration

```elixir
releases: [
  lambda: [
    steps: [&Mayfly.Release.prepare/1, :assemble, &Mayfly.Release.bootstrap/1, &Mayfly.Release.zip/1],
    mayfly: [handler: MyApp.Handler, layer: true],
    # any Mix.Release option:
    applications: [my_app: :permanent],
    include_erts: false                     # implied by layer: true
  ]
]
```

`Mayfly.Release.prepare/1` sets `strip_beams: true`, `include_executables_for: [:unix]`
and a `vm.args` with `+S 1:1 +sbwt none` unless you provide these yourself.
Umbrella apps: define the release in the umbrella root `mix.exs` as usual.

### Runtime configuration

`config/runtime.exs` works normally. The generated `bootstrap` sets
`RELEASE_TMP=/tmp` because Lambda's `/var/task` is read-only, so the release
can write its generated `sys.config` there.

### The generated bootstrap

```bash
#!/bin/bash
set -eu
export LAMBDA_TASK_ROOT="${LAMBDA_TASK_ROOT:-...}"
export RELEASE_TMP="${RELEASE_TMP:-/tmp}"
export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}"
export _HANDLER="${_HANDLER:-MyApp.Handler}"
export PATH="${MAYFLY_ERTS:-/opt/erlang}/bin:$PATH"     # layer builds only, plus an
# ERTS presence/version check that fails fast with a readable message
exec "$LAMBDA_TASK_ROOT/bin/lambda" eval "Mayfly.Boot.main()"
```

Lambda's **Handler** setting populates `_HANDLER` and therefore overrides the
default baked in at build time.

## Building with Docker (bundled ERTS)

```bash
mix lambda.build --docker --arch x86_64     # or arm64
mix lambda.build --docker --release other --env staging --outdir ./deploy
```

The task uses `docker`, or `finch` if docker is not installed
(`CONTAINER_CLI=...` overrides). It builds `lambda.Dockerfile` (yours if
present, else Mayfly's) for the requested platform, runs `mix deps.get && mix release` inside the container
with a separate `MIX_BUILD_PATH`, and copies `lambda.zip` out. `path:`
dependencies outside the project are mounted read-only into the container.
Add system packages for NIFs by copying Mayfly's Dockerfile into your project
and extending the `dnf install` line.

## HTTP events (Function URLs, API Gateway)

Function URLs and API Gateway do not pass your JSON body as the event; they
wrap it in an HTTP event (`"version": "2.0"`, `"rawPath"`, `"headers"`,
`"body"` as a string). Match on it explicitly:

```elixir
def handle(%{"requestContext" => %{"http" => %{"method" => m, "path" => p}}, "body" => body}, ctx, state) do
  with {:ok, json} <- JSON.decode(body || "{}") do
    route(m, p, json, ctx, state)
  else
    _ -> {:ok, %{statusCode: 400, body: "invalid JSON"}}
  end
end
```

Test locally with `mix lambda.invoke MyApp.Handler '{"x":1}' --http --method POST --path /items`.

## Infrastructure as code

### AWS SAM

```yaml
Resources:
  Hello:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: provided.al2023
      Architectures: [arm64]
      Handler: MyApp.Handler
      CodeUri: _build/prod/rel/lambda/lambda.zip
      Layers:
        - arn:aws:lambda:eu-central-1:ACCOUNT:layer:mayfly-erlang-27-3-4-arm64:1
      LoggingConfig:
        LogFormat: JSON
        ApplicationLogLevel: INFO
      FunctionUrlConfig:
        AuthType: NONE
        InvokeMode: RESPONSE_STREAM      # only for streaming handlers
```

### Terraform

```hcl
resource "aws_lambda_function" "hello" {
  function_name = "hello"
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "MyApp.Handler"
  filename      = "${path.module}/_build/prod/rel/lambda/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/_build/prod/rel/lambda/lambda.zip")
  layers        = [var.mayfly_layer_arn]
  role          = aws_iam_role.lambda.arn
  timeout       = 30
  memory_size   = 512

  logging_config {
    log_format = "JSON"
  }
}
```

### CDK (TypeScript)

```ts
new lambda.Function(this, "Hello", {
  runtime: lambda.Runtime.PROVIDED_AL2023,
  architecture: lambda.Architecture.ARM_64,
  handler: "MyApp.Handler",
  code: lambda.Code.fromAsset("_build/prod/rel/lambda/lambda.zip"),
  layers: [lambda.LayerVersion.fromLayerVersionArn(this, "Erlang", mayflyLayerArn)],
  loggingFormat: lambda.LoggingFormat.JSON,
});
```

## CI

```yaml
- uses: erlef/setup-beam@v1
  with: { elixir-version: "1.18", otp-version: "27" }
- run: mix deps.get
- run: MIX_ENV=prod mix release lambda             # layer: true → no Docker needed
- run: aws lambda update-function-code --function-name hello \
         --zip-file fileb://_build/prod/rel/lambda/lambda.zip
```

Pin the OTP major in CI to the layer's (27 here). If you bundle ERTS, replace
the release step with `mix lambda.build --docker --arch arm64`.

## Lambda Managed Instances

Nothing changes in the package. Create a capacity provider, then create the
function with `--capacity-provider-config` (memory ≥ 2048 MB, invoked by
published version) and Mayfly reads `AWS_LAMBDA_MAX_CONCURRENCY` and starts
that many pollers:

```bash
aws lambda create-capacity-provider --capacity-provider-name mayfly \
  --vpc-config SubnetIds=subnet-…,SecurityGroupIds=sg-… \
  --permissions-config CapacityProviderOperatorRoleArn=arn:aws:iam::ACCOUNT:role/lmi-operator \
  --instance-requirements '{"Architectures":["arm64"],"AllowedInstanceTypes":["m7g.large"]}' \
  --capacity-provider-scaling-config '{"MaxVCpuCount":16}'

aws lambda create-function … --memory-size 2048 \
  --capacity-provider-config '{"LambdaManagedInstancesCapacityProviderConfig":{"CapacityProviderArn":"arn:…:capacity-provider:mayfly","PerExecutionEnvironmentMaxConcurrency":8,"ExecutionEnvironmentMemoryGiBPerVCpu":2}}'
aws lambda publish-version --function-name my-fn      # invoke my-fn:1
```

The operator role needs the `AWSLambdaManagedEC2ResourceOperator` policy.
Mayfly's `bootstrap` keeps all vCPUs as schedulers in this mode. Your handler must
be safe to run concurrently (it runs in separate processes; `init/1` state is
shared read-only), and should watch `Mayfly.Context.remaining_time_ms/1`
because Managed Instances do not terminate a handler at its deadline.

## Memory and timeouts

Start with 512 MB (more memory = more CPU). Cold start is dominated by BEAM
boot (~150–300 ms on arm64 with a stripped release); keep `init/1` lean.
Streaming functions are billed for the full duration even if the client
disconnects.

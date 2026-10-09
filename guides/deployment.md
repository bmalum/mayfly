# Deployment

## Choosing how the runtime gets to Lambda

| | Zip + ERTS layer (`layer: true`) | Zip + bundled ERTS | Container image (`--image`) |
|---|---|---|---|
| Artifact | 1–5 MB zip | 25–50 MB zip | 60–70 MB compressed image in ECR (≈270 MB unpacked, 10 GB limit) |
| Build host | any OS, no Docker | Amazon Linux 2023 or `--docker` | docker or finch (release built inside the container) |
| Build time | seconds | seconds + one-off 20–40 min image build | same as `--docker`, plus a few seconds for the image |
| NIF dependencies | need the layer *and* Linux-built NIFs (`--docker`) | works | works; add system libraries in `lambda.image.Dockerfile` |
| OTP version | must equal the layer's exactly (checked at start) | whatever you build with | whatever you build with |
| Cold start (arm64, 512 MB, measured) | ~540 ms median | ~505 ms median | ~430 ms median after the first pull; the very first start of a new image ≈1.2 s |
| Deploy | `update-function-code --zip-file` (2–4 s) | `update-function-code --zip-file` (10–14 s) | `update-function-code --image-uri` after `push` |
| Function URL / API GW / streaming / Managed Instances | yes | yes | yes |
| SnapStart | no | no | no (managed runtimes only) |

Recommendation: layer for everything without NIFs; bundled ERTS via Docker
when you want a zip anyway; container image when the function needs native
libraries (ImageMagick, Rust, C NIFs), when your pipeline already builds
images, or when you want to run the exact artefact locally. Public layer ARNs
and the naming scheme are in [layers.md](layers.md).

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

## Container image

```bash
mix lambda.build --image --arch arm64                # -> my_app-lambda:latest
mix lambda.build --image --arch arm64 --push 123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-app
```

`--image` builds the release inside the Amazon Linux 2023 build container
exactly like `--docker` (so NIFs compile there, no local toolchain needed) and
copies it into an image based on `public.ecr.aws/lambda/provided:al2023` at
`/var/task`, with your handler as the image `CMD`. The generated Dockerfile:

```dockerfile
FROM public.ecr.aws/lambda/provided:al2023
COPY . ${LAMBDA_TASK_ROOT}/
RUN ln -sf ${LAMBDA_TASK_ROOT}/bootstrap /var/runtime/bootstrap
CMD ["MyApp.Handler"]
```

Both release flavours work: a bundled-ERTS release is self-contained; a
`layer: true` release gets `/opt/erlang` copied from the build image instead
(smaller image, ~90 MB unpacked). Drop a `lambda.image.Dockerfile` into your
project to replace the generated one, for instance to `dnf install` ImageMagick
or copy configuration files; it receives the build args `RELEASE_DIR`,
`BUILD_IMAGE` and `HANDLER`.

The base image's entrypoint exports its argument as `_HANDLER` and runs
`/var/runtime/bootstrap`, through the Runtime Interface Emulator when
`AWS_LAMBDA_RUNTIME_API` is unset. So the image runs locally as is:

```bash
docker run --rm --platform linux/arm64 -p 9000:8080 my_app-lambda:latest
curl -d '{"name":"x"}' http://localhost:9000/2015-03-31/functions/function/invocations
```

`--push` logs in to ECR (`aws ecr get-login-password`), tags, pushes and
prints the `create-function` command with the image digest. The build passes
`--provenance=false --sbom=false`: BuildKit otherwise wraps the image in an
OCI index with attestation manifests, which Lambda rejects with "image
manifest, config or layer media type … is not supported".

```bash
aws ecr create-repository --repository-name my-app --image-scanning-configuration scanOnPush=true
aws lambda create-function --function-name my-app --package-type Image \
  --code ImageUri=123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-app@sha256:… \
  --architectures arm64 --role arn:aws:iam::123456789012:role/lambda-role \
  --logging-config LogFormat=JSON
# later:
aws lambda update-function-code --function-name my-app --image-uri …@sha256:…
```

No `--runtime`, no `--layers`, no `--handler`: the handler is the image
`CMD` (override per function with `--image-config Command=Other.Handler`).
SAM: `PackageType: Image`, `ImageUri`, `Metadata: {Dockerfile, DockerContext}`
or push yourself; Terraform: `package_type = "Image"`, `image_uri`; CDK:
`lambda.DockerImageFunction` / `Code.fromEcrImage`. Everything else (Function
URLs, streaming, JSON logs, Managed Instances) is unchanged.

Measured on the playground (bcrypt C NIF, arm64, 512 MB, 63 MB compressed /
268 MB unpacked, 10 forced cold starts): `initDurationMs` median 433 ms, p90
547 ms, min 386 ms; the first start after the push took 1188 ms while Lambda
pulled and cached the image. Warm invocations 2–10 ms plus the handler's own
work. That is on par with the zip variants once the image is cached; budget
the first-pull second for brand-new image digests.

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

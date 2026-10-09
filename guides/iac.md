# Infrastructure as code

Mayfly ships working SAM, Terraform and CDK definitions in
[`templates/`](https://github.com/bmalum/mayfly/tree/main/templates) (also in
the Hex package under `deps/mayfly/templates`). Each resolves the public Erlang
layer for the deployment region from an embedded map covering all 16 regions ×
OTP 27/28/29 × both architectures; the map is re-rendered by the weekly layer
workflow (`layer/render-templates.sh`), so the templates in `main` always carry
current ARNs. The quickest way to get them is the generator:

```bash
mix lambda.new hello --iac sam                 # or terraform | cdk; --arch x86_64, --otp 28, --region us-east-1
mix lambda.new hello --iac terraform --http-api  # add an API Gateway HTTP API in front of the function
```

It creates the Mix project (handler with an HTTP branch, release config,
`.tool-versions` pinned to the layer's exact OTP from the catalog, an ExUnit
test through `Mayfly.LocalRuntime`, README) plus the IaC files with the
function name, handler, architecture and OTP filled in. All three were
deployed, invoked and destroyed from the generated projects on 2026-10-09.

### Function URL or API Gateway?

By default every template exposes the function through a **Function URL**
(IAM auth, `BUFFERED` or `RESPONSE_STREAM`): no extra service, no cost,
streaming supported. `--http-api` adds an **API Gateway HTTP API** with a
`$default` route, a JSON access log group and the Lambda permission: use it
when you need custom domains, JWT authorizers, usage plans, WAF, or several
functions behind one host. The handler code is identical (`Mayfly.Events.HTTP`
decodes both payload shapes); only the IaC changes, and `mix lambda.doctor`
reads whichever you generated. Verified: the SAM variant deployed, `GET
/hello?name=…` and `POST /items` with a JSON body returned 200 through the
API endpoint, access log line present.

### AWS SAM (`template.yaml`, `samconfig.toml`, `Makefile` in the project root)

```bash
sam build        # BuildMethod: makefile -> MIX_ENV=prod mix release lambda, no Docker
sam deploy --guided   # afterwards: sam deploy
sam delete
```

`AWS::Serverless::Function` with `provided.al2023`, `Architectures`,
`LoggingConfig: JSON`, `Tracing: Active`, a Function URL (parameters
`FunctionUrlAuthType`, `FunctionUrlInvokeMode`), a log group with retention,
and `Layers` chosen via `Mappings.MayflyLayers[region][otp<major><arch>]`
(`x86_64` is written `x8664`: mapping keys must be alphanumeric). Parameters
`Architecture` and `OtpMajor` select the layer; `OtpMajor` must match the OTP
you build with.

### Terraform (`infra/main.tf`, `variables.tf`, `locals.tf`)

```bash
MIX_ENV=prod mix release lambda
cd infra && terraform init && terraform apply -auto-approve
terraform destroy -auto-approve
```

`aws_lambda_function` + IAM role with `AWSLambdaBasicExecutionRole`, log group,
optional `aws_lambda_function_url`. `locals.tf` holds the static layer map
(reproducible plans); `var.layer_arn` overrides it, and the file documents a
`data "http"` variant that resolves the catalog at plan time.

### CDK (`infra/lib/mayfly-function.ts`, `bin/app.ts`)

```bash
MIX_ENV=prod mix release lambda
cd infra && npm install && npx cdk bootstrap && npx cdk deploy --require-approval never
npx cdk destroy --force
```

`MayflyFunction` extends `lambda.Function`: runtime, architecture, handler,
layer, JSON logs, tracing and sane memory/timeout defaults; every other
`FunctionProps` passes through. With an explicit stack region the layer ARN is
resolved at synth time; environment-agnostic stacks get a CloudFormation
`Mapping` and `Fn::FindInMap`. `MayflyFunction.layerArn(region, arch, otpMajor)`
is a plain lookup for other constructs.

### Minimal hand-written snippets

```yaml
# SAM
Hello:
  Type: AWS::Serverless::Function
  Properties:
    Runtime: provided.al2023
    Architectures: [arm64]
    Handler: MyApp.Handler
    CodeUri: _build/prod/rel/lambda/lambda.zip
    Layers: [arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-arm64:4]
    LoggingConfig: { LogFormat: JSON }
```

```hcl
# Terraform
resource "aws_lambda_function" "hello" {
  function_name    = "hello"
  runtime          = "provided.al2023"
  architectures    = ["arm64"]
  handler          = "MyApp.Handler"
  filename         = "_build/prod/rel/lambda/lambda.zip"
  source_code_hash = filebase64sha256("_build/prod/rel/lambda/lambda.zip")
  layers           = [var.mayfly_layer_arn]
  role             = aws_iam_role.lambda.arn
  logging_config { log_format = "JSON" }
}
```

```ts
// CDK
new lambda.Function(this, "Hello", {
  runtime: lambda.Runtime.PROVIDED_AL2023,
  architecture: lambda.Architecture.ARM_64,
  handler: "MyApp.Handler",
  code: lambda.Code.fromAsset("_build/prod/rel/lambda/lambda.zip"),
  layers: [lambda.LayerVersion.fromLayerVersionArn(this, "Erlang", mayflyLayerArn)],
  loggingFormat: lambda.LoggingFormat.JSON,
});
```

`mix lambda.doctor` checks the generated files: the OTP major parameter,
the layer ARN the file selects for its architecture, the architecture and the
runtime, against your toolchain, so a `--otp 28` project built with OTP 27
fails doctor before it fails at boot.

Container images: `PackageType: Image` / `package_type = "Image"` /
`lambda.DockerImageFunction` with the URI printed by `mix lambda.build --image --push`;
no runtime, layers or handler setting (see [Container image](#container-image)).


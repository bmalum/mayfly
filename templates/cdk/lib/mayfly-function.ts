// Elixir on AWS Lambda with Mayfly (https://elixir-aws-lambda.dev).
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import { Construct } from "constructs";

export type MayflyArch = "arm64" | "x86_64";
export type MayflyOtpMajor = "27" | "28" | "29";

// Mayfly public layer ARNs, rendered from https://elixir-aws-lambda.dev/layers/index.json
// by layer/render-templates.sh (mayfly repository). Keys: region -> `otp<major><arch>`,
// with x86_64 written as x8664 (CloudFormation mapping keys must be alphanumeric).
// mayfly-layers:begin (generated 2026-10-06 from the Mayfly catalog)
export const MAYFLY_LAYERS: Record<string, Record<string, string>> = {
  "ap-northeast-1": {
    otp27arm64: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "ap-northeast-2": {
    otp27arm64: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "ap-south-1": {
    otp27arm64: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "ap-southeast-1": {
    otp27arm64: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "ap-southeast-2": {
    otp27arm64: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "ca-central-1": {
    otp27arm64: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "eu-central-1": {
    otp27arm64: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "eu-north-1": {
    otp27arm64: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "eu-west-1": {
    otp27arm64: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "eu-west-2": {
    otp27arm64: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "eu-west-3": {
    otp27arm64: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "sa-east-1": {
    otp27arm64: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "us-east-1": {
    otp27arm64: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "us-east-2": {
    otp27arm64: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "us-west-1": {
    otp27arm64: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
  "us-west-2": {
    otp27arm64: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4",
    otp27x8664: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4",
    otp28arm64: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4",
    otp28x8664: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4",
    otp29arm64: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1",
    otp29x8664: "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1",
  },
};
// mayfly-layers:end

function layerKey(arch: MayflyArch, otpMajor: MayflyOtpMajor): string {
  return `otp${otpMajor}${arch.replace("_", "")}`;
}

export interface MayflyFunctionProps
  extends Omit<lambda.FunctionProps, "runtime" | "code" | "handler" | "architecture" | "layers"> {
  /** Module implementing Mayfly.Handler, e.g. "MyApp.Handler". */
  readonly handler: string;
  /** Path to the release zip (default "../_build/prod/rel/lambda/lambda.zip") or any lambda.Code. */
  readonly code?: lambda.Code | string;
  readonly arch?: MayflyArch;
  /** OTP major the release was built with; must match the layer exactly (checked by bootstrap). */
  readonly otpMajor?: MayflyOtpMajor;
  /** Override the layer (e.g. a self-published one). */
  readonly layerArn?: string;
  /** Extra layers appended after the Mayfly ERTS layer. */
  readonly extraLayers?: lambda.ILayerVersion[];
}

/**
 * A `lambda.Function` preconfigured for a Mayfly release: provided.al2023,
 * the matching public Erlang layer for the stack's region, JSON logging and
 * X-Ray tracing. Everything from `lambda.FunctionProps` except runtime/code/
 * handler/architecture/layers can be passed through.
 */
export class MayflyFunction extends lambda.Function {
  /** Resolves the public Mayfly layer ARN for a region/arch/OTP major, or throws. */
  static layerArn(region: string, arch: MayflyArch = "arm64", otpMajor: MayflyOtpMajor = "27"): string {
    const arn = MAYFLY_LAYERS[region]?.[layerKey(arch, otpMajor)];
    if (!arn) {
      throw new Error(
        `No Mayfly layer for region=${region} arch=${arch} otp=${otpMajor}; see https://elixir-aws-lambda.dev/layers/`
      );
    }
    return arn;
  }

  constructor(scope: Construct, id: string, props: MayflyFunctionProps) {
    const arch = props.arch ?? "arm64";
    const otpMajor = props.otpMajor ?? "27";
    const region = cdk.Stack.of(scope).region;
    const layerArn =
      props.layerArn ??
      (cdk.Token.isUnresolved(region)
        ? cdk.Fn.findInMap("MayflyLayers", region, layerKey(arch, otpMajor))
        : MayflyFunction.layerArn(region, arch, otpMajor));
    const code =
      typeof props.code === "string" || props.code === undefined
        ? lambda.Code.fromAsset(props.code ?? "../_build/prod/rel/lambda/lambda.zip")
        : props.code;

    const { handler, code: _c, arch: _a, otpMajor: _o, layerArn: _l, extraLayers, ...rest } = props;

    super(scope, id, {
      memorySize: 512,
      timeout: cdk.Duration.seconds(30),
      loggingFormat: lambda.LoggingFormat.JSON,
      tracing: lambda.Tracing.ACTIVE,
      logRetention: logs.RetentionDays.TWO_WEEKS,
      ...rest,
      runtime: lambda.Runtime.PROVIDED_AL2023,
      architecture: arch === "arm64" ? lambda.Architecture.ARM_64 : lambda.Architecture.X86_64,
      handler,
      code,
      layers: [
        lambda.LayerVersion.fromLayerVersionArn(scope, `${id}MayflyLayer`, layerArn),
        ...(extraLayers ?? []),
      ],
    });

    // Environment-agnostic stacks (no explicit region) get a CloudFormation
    // mapping so the layer still resolves at deploy time.
    if (cdk.Token.isUnresolved(region) && !props.layerArn) {
      const stack = cdk.Stack.of(scope);
      if (!stack.node.tryFindChild("MayflyLayers")) {
        new cdk.CfnMapping(stack, "MayflyLayers", { mapping: MAYFLY_LAYERS });
      }
    }
  }
}

#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
// mayfly-http-api:begin
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
// mayfly-http-api:end
import { MayflyFunction } from "../lib/mayfly-function";

const app = new cdk.App();

class __STACK_CLASS__ extends cdk.Stack {
  constructor(scope: cdk.App, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const fn = new MayflyFunction(this, "Function", {
      functionName: "__FUNCTION_NAME__",
      handler: "__HANDLER__",
      arch: "__ARCH__",
      otpMajor: "__OTP__",
      environment: { LOGLEVEL: "info" },
    });

    const url = fn.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.AWS_IAM,
      invokeMode: lambda.InvokeMode.BUFFERED,
    });

    // mayfly-http-api:begin
    const api = new apigwv2.HttpApi(this, "HttpApi", {
      apiName: "__FUNCTION_NAME__",
      defaultIntegration: new HttpLambdaIntegration("Default", fn, {
        payloadFormatVersion: apigwv2.PayloadFormatVersion.VERSION_2_0,
      }),
    });
    new cdk.CfnOutput(this, "HttpApiUrl", { value: api.apiEndpoint });
    // mayfly-http-api:end

    new cdk.CfnOutput(this, "FunctionArn", { value: fn.functionArn });
    new cdk.CfnOutput(this, "FunctionUrl", { value: url.url });
  }
}

new __STACK_CLASS__(app, "__FUNCTION_NAME__", {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
  tags: { project: "__FUNCTION_NAME__" },
});

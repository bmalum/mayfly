# Mayfly public layer ARNs (keys: otp<major><arch>, x86_64 written as x8664), rendered from https://elixir-aws-lambda.dev/layers/index.json
# by layer/render-templates.sh (mayfly repository). Static so plans are reproducible.
#
# To resolve at plan time instead, replace the local with:
#   data "http" "mayfly_layer" {
#     url = "https://elixir-aws-lambda.dev/layers/${var.otp_major}/${var.architecture}/${var.region}.json"
#   }
#   layer_arn = jsondecode(data.http.mayfly_layer.response_body).arn
# (provider hashicorp/http). The ARN then changes whenever a new OTP patch is published.

locals {
  # mayfly-layers:begin (generated 2026-10-06 from the Mayfly catalog)
  mayfly_layers = {
    "ap-northeast-1" = {
      otp27arm64 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ap-northeast-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "ap-northeast-2" = {
      otp27arm64 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ap-northeast-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "ap-south-1" = {
      otp27arm64 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ap-south-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "ap-southeast-1" = {
      otp27arm64 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ap-southeast-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "ap-southeast-2" = {
      otp27arm64 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ap-southeast-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "ca-central-1" = {
      otp27arm64 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:ca-central-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "eu-central-1" = {
      otp27arm64 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:eu-central-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "eu-north-1" = {
      otp27arm64 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:eu-north-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "eu-west-1" = {
      otp27arm64 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:eu-west-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "eu-west-2" = {
      otp27arm64 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:eu-west-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "eu-west-3" = {
      otp27arm64 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:eu-west-3:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "sa-east-1" = {
      otp27arm64 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:sa-east-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "us-east-1" = {
      otp27arm64 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:us-east-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "us-east-2" = {
      otp27arm64 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:us-east-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "us-west-1" = {
      otp27arm64 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:us-west-1:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
    "us-west-2" = {
      otp27arm64 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-arm64:4"
      otp27x8664 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-27-3-4-18-x86_64:4"
      otp28arm64 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-arm64:4"
      otp28x8664 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-28-5-0-7-x86_64:4"
      otp29arm64 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-29-1-1-arm64:1"
      otp29x8664 = "arn:aws:lambda:us-west-2:651236577491:layer:mayfly-erlang-29-1-1-x86_64:1"
    }
  }
  # mayfly-layers:end
}

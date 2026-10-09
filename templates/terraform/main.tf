# Elixir on AWS Lambda with Mayfly (https://elixir-aws-lambda.dev).
# Build first: MIX_ENV=prod mix release lambda  ->  _build/prod/rel/lambda/lambda.zip

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.40" }
  }
}

provider "aws" {
  region = var.region
}

data "aws_region" "current" {}

locals {
  layer_key = "otp${var.otp_major}${replace(var.architecture, "_", "")}"
  layer_arn = var.layer_arn != "" ? var.layer_arn : local.mayfly_layers[data.aws_region.current.name][local.layer_key]
}

resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name    = var.function_name
  role             = aws_iam_role.lambda.arn
  runtime          = "provided.al2023"
  handler          = var.handler
  architectures    = [var.architecture]
  filename         = var.zip_path
  source_code_hash = filebase64sha256(var.zip_path)
  layers           = [local.layer_arn]
  memory_size      = var.memory_size
  timeout          = var.timeout

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = merge({ LOGLEVEL = "info" }, var.environment)
  }

  tags       = var.tags
  depends_on = [aws_iam_role_policy_attachment.basic]
}

resource "aws_lambda_function_url" "this" {
  count              = var.function_url ? 1 : 0
  function_name      = aws_lambda_function.this.function_name
  authorization_type = var.function_url_auth_type
  invoke_mode        = var.function_url_invoke_mode
}

output "function_arn" { value = aws_lambda_function.this.arn }
output "function_url" { value = var.function_url ? aws_lambda_function_url.this[0].function_url : null }
output "layer_arn" { value = local.layer_arn }

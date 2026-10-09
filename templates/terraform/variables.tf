variable "region" {
  type    = string
  default = "__REGION__"
}

variable "function_name" {
  type    = string
  default = "__FUNCTION_NAME__"
}

variable "handler" {
  description = "Module implementing Mayfly.Handler"
  type        = string
  default     = "__HANDLER__"
}

variable "architecture" {
  type    = string
  default = "__ARCH__"
  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64"
  }
}

variable "otp_major" {
  description = "OTP major of the Mayfly layer; must match the release's OTP (bootstrap checks the exact version)"
  type        = string
  default     = "__OTP__"
}

variable "layer_arn" {
  description = "Override the layer ARN (e.g. a self-published layer). Empty = use the catalog map in locals.tf"
  type        = string
  default     = ""
}

variable "zip_path" {
  type    = string
  default = "../_build/prod/rel/lambda/lambda.zip"
}

variable "memory_size" {
  type    = number
  default = 512
}

variable "timeout" {
  type    = number
  default = 30
}

variable "environment" {
  type    = map(string)
  default = {}
}

variable "function_url" {
  type    = bool
  default = true
}

variable "function_url_auth_type" {
  type    = string
  default = "AWS_IAM"
}

variable "function_url_invoke_mode" {
  type    = string
  default = "BUFFERED"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = { project = "__FUNCTION_NAME__" }
}

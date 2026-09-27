defmodule Mayfly.Context do
  @moduledoc """
  Per-invocation metadata, built from the `GET /runtime/invocation/next`
  response headers and passed as the second argument to `c:Mayfly.Handler.handle/3`.

  | Field | Header | Notes |
  |---|---|---|
  | `request_id` | `Lambda-Runtime-Aws-Request-Id` | identifies the *event*; may be retried |
  | `invocation_id` | `Lambda-Runtime-Invocation-Id` | identifies this *attempt*; echoed back by the runtime |
  | `deadline_ms` | `Lambda-Runtime-Deadline-Ms` | Unix time in ms |
  | `function_arn` | `Lambda-Runtime-Invoked-Function-Arn` | |
  | `trace_id` | `Lambda-Runtime-Trace-Id` | also exported as `_X_AMZN_TRACE_ID` |
  | `tenant_id` | `Lambda-Runtime-Aws-Tenant-Id` | tenant isolation mode |
  | `client_context` | `Lambda-Runtime-Client-Context` | Mobile SDK, raw JSON |
  | `cognito_identity` | `Lambda-Runtime-Cognito-Identity` | Mobile SDK, raw JSON |

  `env` carries the static function configuration read from the environment
  (`AWS_LAMBDA_FUNCTION_NAME`, `..._VERSION`, `..._MEMORY_SIZE`, `AWS_REGION`,
  `AWS_LAMBDA_LOG_GROUP_NAME`, `AWS_LAMBDA_LOG_STREAM_NAME`).
  """

  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          invocation_id: String.t() | nil,
          deadline_ms: non_neg_integer() | nil,
          function_arn: String.t() | nil,
          trace_id: String.t() | nil,
          tenant_id: String.t() | nil,
          client_context: String.t() | nil,
          cognito_identity: String.t() | nil,
          env: %{optional(atom()) => String.t() | nil}
        }

  defstruct [
    :request_id,
    :invocation_id,
    :deadline_ms,
    :function_arn,
    :trace_id,
    :tenant_id,
    :client_context,
    :cognito_identity,
    env: %{}
  ]

  @doc "Builds a context from lowercased response headers."
  @spec from_headers([{String.t(), String.t()}], map()) :: t()
  def from_headers(headers, env \\ %{}) when is_list(headers) do
    h = Map.new(headers)

    %__MODULE__{
      request_id: h["lambda-runtime-aws-request-id"],
      invocation_id: h["lambda-runtime-invocation-id"],
      deadline_ms: parse_int(h["lambda-runtime-deadline-ms"]),
      function_arn: h["lambda-runtime-invoked-function-arn"],
      trace_id: h["lambda-runtime-trace-id"],
      tenant_id: h["lambda-runtime-aws-tenant-id"],
      client_context: h["lambda-runtime-client-context"],
      cognito_identity: h["lambda-runtime-cognito-identity"],
      env: env
    }
  end

  @doc "Reads the static function configuration from the environment."
  @spec env_from_system() :: map()
  def env_from_system do
    %{
      function_name: System.get_env("AWS_LAMBDA_FUNCTION_NAME"),
      function_version: System.get_env("AWS_LAMBDA_FUNCTION_VERSION"),
      memory_mb: System.get_env("AWS_LAMBDA_FUNCTION_MEMORY_SIZE"),
      region: System.get_env("AWS_REGION"),
      log_group: System.get_env("AWS_LAMBDA_LOG_GROUP_NAME"),
      log_stream: System.get_env("AWS_LAMBDA_LOG_STREAM_NAME")
    }
  end

  @doc """
  Milliseconds until Lambda considers this invocation timed out (`nil` when
  unknown). On Lambda Managed Instances the runtime is *not* killed at the
  deadline, so check this in long loops and stop early.
  """
  @spec remaining_time_ms(t()) :: non_neg_integer() | nil
  def remaining_time_ms(%__MODULE__{deadline_ms: nil}), do: nil

  def remaining_time_ms(%__MODULE__{deadline_ms: deadline}),
    do: max(deadline - System.system_time(:millisecond), 0)

  @doc "Logger metadata for this invocation."
  @spec logger_metadata(t()) :: keyword()
  def logger_metadata(%__MODULE__{} = ctx) do
    [request_id: ctx.request_id, tenant_id: ctx.tenant_id, trace_id: ctx.trace_id]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end
end

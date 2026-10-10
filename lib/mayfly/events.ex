defmodule Mayfly.Events do
  @moduledoc """
  Typed decoders for the event shapes AWS services send to Lambda.

  Handlers receive the raw decoded JSON. These modules turn the common
  envelopes into structs with the fields you actually use, decode base64 and
  nested JSON, and convert DynamoDB attribute values into Elixir terms.

  | Source | Module | Detected by |
  |---|---|---|
  | API Gateway HTTP API (v2), Function URL | `Mayfly.Events.HTTP` | `"version" => "2.0"` |
  | API Gateway REST API (v1), ALB | `Mayfly.Events.HTTP` | `"httpMethod"` / `"requestContext.elb"` |
  | SQS | `Mayfly.Events.SQS` | `eventSource: "aws:sqs"` |
  | SNS | `Mayfly.Events.SNS` | `EventSource: "aws:sns"` |
  | S3 | `Mayfly.Events.S3` | `eventSource: "aws:s3"` |
  | EventBridge | `Mayfly.Events.EventBridge` | `"detail-type"` |
  | Kinesis Data Streams | `Mayfly.Events.Kinesis` | `eventSource: "aws:kinesis"` |
  | DynamoDB Streams | `Mayfly.Events.DynamoDB` | `eventSource: "aws:dynamodb"` |

  Return shapes follow one rule: *decoders* (`Mayfly.Events.HTTP.decode/1`,
  `Mayfly.Events.SQS.decode/1`, …) take a known envelope and return the struct
  directly, since they cannot fail on the shape they were given; `decode/1`
  here dispatches on an *unknown* event and therefore returns `{:ok, struct}`
  or `:unknown`; *response helpers* (`Mayfly.Events.HTTP.json/4`,
  `Mayfly.Events.SQS.process_batch/2`, …) return exactly what a handler
  returns, so they can be the last expression of `handle/3`.

  Use the specific module when you know the source, or `decode/1` to
  dispatch:

      def handle(event, _ctx, _state) do
        case Mayfly.Events.decode(event) do
          {:ok, %Mayfly.Events.HTTP.Request{} = req} -> serve(req)
          {:ok, %Mayfly.Events.SQS{records: records}} -> process(records)
          {:ok, other} -> {:ok, %{ignored: other.__struct__}}
          :unknown -> {:ok, %{raw: event}}
        end
      end

  Every decoder keeps the original map in `:raw` so nothing is lost.
  """

  alias Mayfly.Events.{DynamoDB, EventBridge, HTTP, Kinesis, S3, SNS, SQS}

  @type event ::
          HTTP.Request.t()
          | SQS.t()
          | SNS.t()
          | S3.t()
          | EventBridge.t()
          | Kinesis.t()
          | DynamoDB.t()

  @doc "Detects the event source and decodes it. Returns `:unknown` for anything else."
  @spec decode(map()) :: {:ok, event()} | :unknown
  def decode(%{"version" => "2.0", "requestContext" => %{"http" => _}} = e),
    do: {:ok, HTTP.decode(e)}

  def decode(%{"httpMethod" => _} = e), do: {:ok, HTTP.decode(e)}
  def decode(%{"requestContext" => %{"elb" => _}} = e), do: {:ok, HTTP.decode(e)}
  def decode(%{"detail-type" => _, "source" => _} = e), do: {:ok, EventBridge.decode(e)}

  def decode(%{"Records" => [first | _]} = e) do
    case first do
      %{"eventSource" => "aws:sqs"} -> {:ok, SQS.decode(e)}
      %{"EventSource" => "aws:sns"} -> {:ok, SNS.decode(e)}
      %{"eventSource" => "aws:s3"} -> {:ok, S3.decode(e)}
      %{"eventSource" => "aws:kinesis"} -> {:ok, Kinesis.decode(e)}
      %{"eventSource" => "aws:dynamodb"} -> {:ok, DynamoDB.decode(e)}
      _ -> :unknown
    end
  end

  def decode(_), do: :unknown
end

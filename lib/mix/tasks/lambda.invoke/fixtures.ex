defmodule Mix.Tasks.Lambda.Invoke.Fixtures do
  @moduledoc false
  # Realistic envelopes for `mix lambda.invoke --event <source>`. The user's
  # JSON becomes the payload each source would carry (HTTP body, SQS body,
  # SNS message, EventBridge detail, Kinesis data, DynamoDB NewImage, …).

  @sources ~w(apigw-v1 apigw-v2 alb sqs sns s3 eventbridge kinesis dynamodb)

  @doc "Supported `--event` values."
  def sources, do: @sources

  @doc "Wraps `body` (a JSON string) in the envelope of `source`. Returns a JSON string."
  @spec wrap(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def wrap(source, body, opts \\ [])

  def wrap(source, body, opts) when source in @sources do
    {:ok, JSON.encode!(envelope(source, body, opts))}
  end

  def wrap(source, _body, _opts),
    do: {:error, "unknown --event #{source}; use one of #{Enum.join(@sources, ", ")}"}

  defp envelope("apigw-v2", body, opts) do
    method = method(opts)
    path = Keyword.get(opts, :path, "/")
    now = System.system_time(:millisecond)

    %{
      "version" => "2.0",
      "routeKey" => "$default",
      "rawPath" => path,
      "rawQueryString" => "",
      "headers" => %{
        "content-type" => "application/json",
        "host" => "localhost",
        "user-agent" => "mix lambda.invoke"
      },
      "requestContext" => %{
        "accountId" => "123456789012",
        "apiId" => "local",
        "domainName" => "localhost",
        "http" => %{
          "method" => method,
          "path" => path,
          "protocol" => "HTTP/1.1",
          "sourceIp" => "127.0.0.1",
          "userAgent" => "mix lambda.invoke"
        },
        "requestId" => "local-#{now}",
        "stage" => "$default",
        "timeEpoch" => now
      },
      "body" => body,
      "isBase64Encoded" => false
    }
  end

  defp envelope("apigw-v1", body, opts) do
    method = method(opts)
    path = Keyword.get(opts, :path, "/")

    %{
      "resource" => "/{proxy+}",
      "path" => path,
      "httpMethod" => method,
      "headers" => %{
        "Content-Type" => "application/json",
        "Host" => "localhost",
        "User-Agent" => "mix lambda.invoke"
      },
      "multiValueHeaders" => %{"Content-Type" => ["application/json"]},
      "queryStringParameters" => nil,
      "multiValueQueryStringParameters" => nil,
      "pathParameters" => %{"proxy" => String.trim_leading(path, "/")},
      "stageVariables" => nil,
      "requestContext" => %{
        "resourceId" => "local",
        "resourcePath" => "/{proxy+}",
        "httpMethod" => method,
        "requestId" => "local-#{System.system_time(:millisecond)}",
        "path" => path,
        "accountId" => "123456789012",
        "stage" => "prod",
        "identity" => %{"sourceIp" => "127.0.0.1", "userAgent" => "mix lambda.invoke"},
        "apiId" => "local"
      },
      "body" => body,
      "isBase64Encoded" => false
    }
  end

  defp envelope("alb", body, opts) do
    %{
      "requestContext" => %{
        "elb" => %{
          "targetGroupArn" =>
            "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/local/abc"
        }
      },
      "httpMethod" => method(opts),
      "path" => Keyword.get(opts, :path, "/"),
      "queryStringParameters" => %{},
      "headers" => %{
        "content-type" => "application/json",
        "host" => "localhost",
        "user-agent" => "mix lambda.invoke",
        "x-forwarded-for" => "127.0.0.1"
      },
      "body" => body,
      "isBase64Encoded" => false
    }
  end

  defp envelope("sqs", body, _opts) do
    %{
      "Records" => [
        %{
          "messageId" => uuid(),
          "receiptHandle" => "local-receipt-handle",
          "body" => body,
          "attributes" => %{
            "ApproximateReceiveCount" => "1",
            "SentTimestamp" => to_string(System.system_time(:millisecond)),
            "SenderId" => "local",
            "ApproximateFirstReceiveTimestamp" => to_string(System.system_time(:millisecond))
          },
          "messageAttributes" => %{},
          "md5OfBody" => Base.encode16(:erlang.md5(body), case: :lower),
          "eventSource" => "aws:sqs",
          "eventSourceARN" => "arn:aws:sqs:eu-central-1:123456789012:local-queue",
          "awsRegion" => "eu-central-1"
        }
      ]
    }
  end

  defp envelope("sns", body, _opts) do
    %{
      "Records" => [
        %{
          "EventVersion" => "1.0",
          "EventSubscriptionArn" => "arn:aws:sns:eu-central-1:123456789012:local-topic:#{uuid()}",
          "EventSource" => "aws:sns",
          "Sns" => %{
            "SignatureVersion" => "1",
            "Timestamp" => iso_now(),
            "MessageId" => uuid(),
            "Message" => body,
            "MessageAttributes" => %{},
            "Type" => "Notification",
            "TopicArn" => "arn:aws:sns:eu-central-1:123456789012:local-topic",
            "Subject" => "local"
          }
        }
      ]
    }
  end

  defp envelope("s3", body, _opts) do
    key =
      case JSON.decode(body) do
        {:ok, %{"key" => k}} when is_binary(k) -> URI.encode(k) |> String.replace("%20", "+")
        _ -> "uploads/local+file.json"
      end

    %{
      "Records" => [
        %{
          "eventVersion" => "2.1",
          "eventSource" => "aws:s3",
          "awsRegion" => "eu-central-1",
          "eventTime" => iso_now(),
          "eventName" => "ObjectCreated:Put",
          "s3" => %{
            "s3SchemaVersion" => "1.0",
            "bucket" => %{"name" => "local-bucket", "arn" => "arn:aws:s3:::local-bucket"},
            "object" => %{
              "key" => key,
              "size" => byte_size(body),
              "eTag" => Base.encode16(:erlang.md5(body), case: :lower),
              "sequencer" => "0A1B2C3D4E5F678901"
            }
          }
        }
      ]
    }
  end

  defp envelope("eventbridge", body, opts) do
    %{
      "version" => "0",
      "id" => uuid(),
      "detail-type" => Keyword.get(opts, :detail_type, "LocalEvent"),
      "source" => Keyword.get(opts, :source, "mix.lambda.invoke"),
      "account" => "123456789012",
      "time" => iso_now(),
      "region" => "eu-central-1",
      "resources" => [],
      "detail" => decode_or_string(body)
    }
  end

  defp envelope("kinesis", body, _opts) do
    seq =
      "4959033827149025660855969253836157109592157598913658889#{System.unique_integer([:positive])}"

    %{
      "Records" => [
        %{
          "kinesis" => %{
            "kinesisSchemaVersion" => "1.0",
            "partitionKey" => "local",
            "sequenceNumber" => seq,
            "data" => Base.encode64(body),
            "approximateArrivalTimestamp" => System.system_time(:millisecond) / 1000
          },
          "eventSource" => "aws:kinesis",
          "eventVersion" => "1.0",
          "eventID" => "shardId-000000000000:#{seq}",
          "eventName" => "aws:kinesis:record",
          "invokeIdentityArn" => "arn:aws:iam::123456789012:role/local",
          "awsRegion" => "eu-central-1",
          "eventSourceARN" => "arn:aws:kinesis:eu-central-1:123456789012:stream/local-stream"
        }
      ]
    }
  end

  defp envelope("dynamodb", body, _opts) do
    image =
      case JSON.decode(body) do
        {:ok, %{} = map} -> to_attribute_values(map)
        _ -> %{"payload" => %{"S" => body}}
      end

    keys =
      image
      |> Map.take(["id", "Id", "pk", "PK"])
      |> then(fn k -> if k == %{}, do: %{"id" => %{"S" => "local"}}, else: k end)

    %{
      "Records" => [
        %{
          "eventID" => uuid(),
          "eventVersion" => "1.1",
          "dynamodb" => %{
            "Keys" => keys,
            "NewImage" => image,
            "StreamViewType" => "NEW_AND_OLD_IMAGES",
            "SequenceNumber" => "#{System.unique_integer([:positive])}",
            "SizeBytes" => byte_size(body),
            "ApproximateCreationDateTime" => System.system_time(:second)
          },
          "awsRegion" => "eu-central-1",
          "eventName" => "INSERT",
          "eventSourceARN" =>
            "arn:aws:dynamodb:eu-central-1:123456789012:table/local-table/stream/2026-01-01T00:00:00.000",
          "eventSource" => "aws:dynamodb"
        }
      ]
    }
  end

  @doc false
  # Plain terms → DynamoDB attribute values (inverse of Mayfly.Events.DynamoDB.from_av/1).
  def to_attribute_values(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), to_av(v)} end)

  defp to_av(nil), do: %{"NULL" => true}
  defp to_av(b) when is_boolean(b), do: %{"BOOL" => b}
  defp to_av(n) when is_number(n), do: %{"N" => to_string(n)}
  defp to_av(s) when is_binary(s), do: %{"S" => s}
  defp to_av(l) when is_list(l), do: %{"L" => Enum.map(l, &to_av/1)}
  defp to_av(m) when is_map(m), do: %{"M" => to_attribute_values(m)}

  defp method(opts), do: opts |> Keyword.get(:method, "POST") |> String.upcase()
  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp decode_or_string(body) do
    case JSON.decode(body) do
      {:ok, term} -> term
      _ -> body
    end
  end

  # Not cryptographic; only needs to look like the ids AWS sends.
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :rand.bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0xFFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> IO.iodata_to_binary()
  end
end

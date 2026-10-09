defmodule Mayfly.Events.SourcesTest do
  use ExUnit.Case, async: true

  alias Mayfly.Events
  alias Mayfly.Events.{DynamoDB, EventBridge, Kinesis, S3, SNS, SQS}

  # ---- AWS sample events ------------------------------------------------------

  @sqs %{
    "Records" => [
      %{
        "messageId" => "059f36b4-87a3-44ab-83d2-661975830a7d",
        "receiptHandle" => "AQEBwJnKyrHigUMZj6rYigCgxlaS3SLy0a...",
        "body" => "{\"order\":1}",
        "attributes" => %{"ApproximateReceiveCount" => "1", "SentTimestamp" => "1545082649183"},
        "messageAttributes" => %{
          "trace" => %{"stringValue" => "abc", "dataType" => "String"},
          "blob" => %{"binaryValue" => Base.encode64("raw"), "dataType" => "Binary"}
        },
        "md5OfBody" => "e4e68fb7bd0e697a0ae8f1bb342846b3",
        "eventSource" => "aws:sqs",
        "eventSourceARN" => "arn:aws:sqs:us-east-2:123456789012:my-queue",
        "awsRegion" => "us-east-2"
      },
      %{
        "messageId" => "2e1424d4-f796-459a-8184-9c92662be6da",
        "receiptHandle" => "AQEBzWwaftRI0KuVm4tP+/7q1rGgNqicHq...",
        "body" => "plain text",
        "attributes" => %{},
        "messageAttributes" => %{},
        "md5OfBody" => "e4e68fb7bd0e697a0ae8f1bb342846b3",
        "eventSource" => "aws:sqs",
        "eventSourceARN" => "arn:aws:sqs:us-east-2:123456789012:my-queue",
        "awsRegion" => "us-east-2"
      }
    ]
  }

  @sns %{
    "Records" => [
      %{
        "EventVersion" => "1.0",
        "EventSubscriptionArn" =>
          "arn:aws:sns:us-east-1:123456789012:sns-lambda:21be56ed-a058-49f5-8c98-aedd2564c486",
        "EventSource" => "aws:sns",
        "Sns" => %{
          "SignatureVersion" => "1",
          "Timestamp" => "2019-01-02T12:45:07.000Z",
          "MessageId" => "95df01b4-ee98-5cb9-9903-4c221d41eb5e",
          "Message" => "{\"hello\":\"sns\"}",
          "MessageAttributes" => %{
            "Test" => %{"Type" => "String", "Value" => "TestString"},
            "TestBinary" => %{"Type" => "Binary", "Value" => Base.encode64("bin")}
          },
          "Type" => "Notification",
          "TopicArn" => "arn:aws:sns:us-east-1:123456789012:sns-lambda",
          "Subject" => "TestInvoke"
        }
      }
    ]
  }

  @s3 %{
    "Records" => [
      %{
        "eventVersion" => "2.1",
        "eventSource" => "aws:s3",
        "awsRegion" => "us-east-2",
        "eventTime" => "2019-09-03T19:37:27.192Z",
        "eventName" => "ObjectCreated:Put",
        "s3" => %{
          "s3SchemaVersion" => "1.0",
          "bucket" => %{
            "name" => "DOC-EXAMPLE-BUCKET",
            "arn" => "arn:aws:s3:::DOC-EXAMPLE-BUCKET"
          },
          "object" => %{
            "key" => "uploads/report+2026%28final%29.pdf",
            "size" => 1_305_107,
            "eTag" => "b21b84d653bb07b05b1e6b33684dc11b",
            "versionId" => "v1",
            "sequencer" => "0C0F6F405D6ED209E1"
          }
        }
      }
    ]
  }

  @eventbridge %{
    "version" => "0",
    "id" => "fe8d3c65-xmpl-c5c3-2c87-81584709a377",
    "detail-type" => "OrderPlaced",
    "source" => "my.app",
    "account" => "123456789012",
    "time" => "2020-04-28T07:20:20Z",
    "region" => "us-east-2",
    "resources" => ["arn:aws:lambda:us-east-2:123456789012:function:x"],
    "detail" => %{"orderId" => 42, "total" => 9.99}
  }

  @kinesis %{
    "Records" => [
      %{
        "kinesis" => %{
          "kinesisSchemaVersion" => "1.0",
          "partitionKey" => "1",
          "sequenceNumber" => "49590338271490256608559692538361571095921575989136588898",
          "data" => Base.encode64(~s({"temp":21.5})),
          "approximateArrivalTimestamp" => 1_545_084_650.987
        },
        "eventSource" => "aws:kinesis",
        "eventVersion" => "1.0",
        "eventID" =>
          "shardId-000000000006:49590338271490256608559692538361571095921575989136588898",
        "eventName" => "aws:kinesis:record",
        "invokeIdentityArn" => "arn:aws:iam::123456789012:role/lambda-role",
        "awsRegion" => "us-east-2",
        "eventSourceARN" => "arn:aws:kinesis:us-east-2:123456789012:stream/lambda-stream"
      },
      %{
        "kinesis" => %{
          "partitionKey" => "2",
          "sequenceNumber" => "4959000002",
          "data" => Base.encode64("not json"),
          "approximateArrivalTimestamp" => 1_545_084_651.0
        },
        "eventSource" => "aws:kinesis",
        "eventID" => "shardId-000000000006:4959000002",
        "awsRegion" => "us-east-2",
        "eventSourceARN" => "arn:aws:kinesis:us-east-2:123456789012:stream/lambda-stream"
      }
    ]
  }

  @dynamodb %{
    "Records" => [
      %{
        "eventID" => "1",
        "eventVersion" => "1.0",
        "dynamodb" => %{
          "Keys" => %{"Id" => %{"N" => "101"}},
          "NewImage" => %{
            "Id" => %{"N" => "101"},
            "Price" => %{"N" => "12.50"},
            "Message" => %{"S" => "New item!"},
            "InStock" => %{"BOOL" => true},
            "Nothing" => %{"NULL" => true},
            "Tags" => %{"SS" => ["a", "b"]},
            "Scores" => %{"NS" => ["1", "2.5"]},
            "Blob" => %{"B" => Base.encode64(<<1, 2, 3>>)},
            "List" => %{
              "L" => [%{"S" => "x"}, %{"N" => "7"}, %{"M" => %{"deep" => %{"BOOL" => false}}}]
            },
            "Map" => %{"M" => %{"k" => %{"S" => "v"}}}
          },
          "StreamViewType" => "NEW_AND_OLD_IMAGES",
          "SequenceNumber" => "111",
          "SizeBytes" => 26,
          "ApproximateCreationDateTime" => 1_480_642_020
        },
        "awsRegion" => "us-west-2",
        "eventName" => "INSERT",
        "eventSourceARN" =>
          "arn:aws:dynamodb:us-west-2:123456789012:table/Orders/stream/2016-11-16T20:42:48.104",
        "eventSource" => "aws:dynamodb"
      },
      %{
        "eventID" => "3",
        "dynamodb" => %{
          "Keys" => %{"Id" => %{"N" => "101"}},
          "OldImage" => %{"Id" => %{"N" => "101"}},
          "SequenceNumber" => "333",
          "StreamViewType" => "NEW_AND_OLD_IMAGES"
        },
        "awsRegion" => "us-west-2",
        "eventName" => "REMOVE",
        "eventSourceARN" =>
          "arn:aws:dynamodb:us-west-2:123456789012:table/Orders/stream/2016-11-16T20:42:48.104",
        "eventSource" => "aws:dynamodb"
      }
    ]
  }

  # ---- SQS --------------------------------------------------------------------------

  test "SQS decode" do
    %SQS{records: [a, b], raw: raw} = SQS.decode(@sqs)
    assert raw == @sqs
    assert a.message_id == "059f36b4-87a3-44ab-83d2-661975830a7d"
    assert a.receipt_handle =~ "AQEBwJnKy"
    assert a.body == %{"order" => 1}
    assert a.attributes["ApproximateReceiveCount"] == "1"
    assert a.message_attributes == %{"trace" => "abc", "blob" => "raw"}
    assert a.md5 == "e4e68fb7bd0e697a0ae8f1bb342846b3"
    assert a.event_source_arn == "arn:aws:sqs:us-east-2:123456789012:my-queue"
    assert a.region == "us-east-2"
    assert b.body == "plain text"
    assert b.message_attributes == %{}
  end

  test "SQS process_batch collects errors, raises, exits and throws" do
    sqs = SQS.decode(@sqs)

    result =
      SQS.process_batch(sqs, fn
        %{body: %{"order" => 1}} -> {:ok, :done}
        %{body: "plain text"} -> raise "boom"
      end)

    assert result == %{
             batchItemFailures: [%{itemIdentifier: "2e1424d4-f796-459a-8184-9c92662be6da"}]
           }

    assert SQS.process_batch(sqs, fn _ -> {:error, :nope} end).batchItemFailures |> length() == 2
    assert SQS.process_batch(sqs, fn _ -> exit(:bye) end).batchItemFailures |> length() == 2
    assert SQS.process_batch(sqs, fn _ -> throw(:x) end).batchItemFailures |> length() == 2
    assert SQS.process_batch(sqs, fn _ -> :ok end) == %{batchItemFailures: []}
    assert SQS.batch_failures(["a"]) == %{batchItemFailures: [%{itemIdentifier: "a"}]}
  end

  # ---- SNS --------------------------------------------------------------------------

  test "SNS decode and SNS-in-SQS envelope" do
    %SNS{records: [r]} = SNS.decode(@sns)
    assert r.message_id == "95df01b4-ee98-5cb9-9903-4c221d41eb5e"
    assert r.topic_arn == "arn:aws:sns:us-east-1:123456789012:sns-lambda"
    assert r.subject == "TestInvoke"
    assert r.message == %{"hello" => "sns"}
    assert r.message_attributes == %{"Test" => "TestString", "TestBinary" => "bin"}
    assert r.timestamp == ~U[2019-01-02 12:45:07.000Z]
    assert r.subscription_arn =~ "21be56ed"

    envelope = @sns["Records"] |> hd() |> Map.fetch!("Sns")
    assert SNS.envelope?(envelope)
    refute SNS.envelope?(%{"order" => 1})
    assert %SNS.Record{message: %{"hello" => "sns"}} = SNS.from_envelope(envelope)
  end

  # ---- S3 ---------------------------------------------------------------------------

  test "S3 decode URL-decodes the key" do
    %S3{records: [r]} = S3.decode(@s3)
    assert r.event_name == "ObjectCreated:Put"
    assert r.bucket == "DOC-EXAMPLE-BUCKET"
    assert r.bucket_arn == "arn:aws:s3:::DOC-EXAMPLE-BUCKET"
    assert r.key == "uploads/report 2026(final).pdf"
    assert r.size == 1_305_107
    assert r.etag == "b21b84d653bb07b05b1e6b33684dc11b"
    assert r.version_id == "v1"
    assert r.region == "us-east-2"
    assert r.time == ~U[2019-09-03 19:37:27.192Z]
  end

  # ---- EventBridge --------------------------------------------------------------------

  test "EventBridge decode" do
    e = EventBridge.decode(@eventbridge)
    assert e.id == "fe8d3c65-xmpl-c5c3-2c87-81584709a377"
    assert e.source == "my.app"
    assert e.detail_type == "OrderPlaced"
    assert e.detail == %{"orderId" => 42, "total" => 9.99}
    assert e.time == ~U[2020-04-28 07:20:20Z]
    assert e.region == "us-east-2"
    assert e.account == "123456789012"
    assert e.resources == ["arn:aws:lambda:us-east-2:123456789012:function:x"]
    assert e.version == "0"
  end

  # ---- Kinesis ----------------------------------------------------------------------

  test "Kinesis decode and batch failures by sequence number" do
    %Kinesis{records: [a, b]} = Kinesis.decode(@kinesis)
    assert a.partition_key == "1"
    assert a.sequence_number == "49590338271490256608559692538361571095921575989136588898"
    assert a.data == %{"temp" => 21.5}
    assert a.approximate_arrival == ~U[2018-12-17 22:10:50.987Z]
    assert a.event_id =~ "shardId-000000000006"
    assert a.event_source_arn =~ "stream/lambda-stream"
    assert b.data == "not json"

    assert Kinesis.process_batch(Kinesis.decode(@kinesis), fn r ->
             if r.partition_key == "2", do: {:error, :x}, else: :ok
           end) ==
             %{batchItemFailures: [%{itemIdentifier: "4959000002"}]}
  end

  # ---- DynamoDB ---------------------------------------------------------------------

  test "DynamoDB decode converts attribute values" do
    %DynamoDB{records: [ins, rem]} = DynamoDB.decode(@dynamodb)

    assert ins.event_name == :insert
    assert ins.keys == %{"Id" => 101}
    assert ins.table == "Orders"
    assert ins.sequence_number == "111"
    assert ins.size_bytes == 26
    assert ins.stream_view_type == "NEW_AND_OLD_IMAGES"
    assert ins.approximate_creation == ~U[2016-12-02 01:27:00.000Z]
    assert ins.old_image == nil

    assert ins.new_image == %{
             "Id" => 101,
             "Price" => 12.5,
             "Message" => "New item!",
             "InStock" => true,
             "Nothing" => nil,
             "Tags" => ["a", "b"],
             "Scores" => [1, 2.5],
             "Blob" => <<1, 2, 3>>,
             "List" => ["x", 7, %{"deep" => false}],
             "Map" => %{"k" => "v"}
           }

    assert rem.event_name == :remove
    assert rem.new_image == nil
    assert rem.old_image == %{"Id" => 101}
    assert DynamoDB.batch_failures(["333"]) == %{batchItemFailures: [%{itemIdentifier: "333"}]}
  end

  test "DynamoDB from_av handles numbers, nested structures and unknown types" do
    assert DynamoDB.from_av(%{"N" => "-3"}) == -3
    assert DynamoDB.from_av(%{"N" => "1e3"}) == 1000.0
    assert DynamoDB.from_av(%{"N" => "abc"}) == "abc"
    assert DynamoDB.from_av(%{"L" => []}) == []
    assert DynamoDB.from_av(%{"M" => %{}}) == %{}
    assert DynamoDB.from_av(%{"WEIRD" => 1}) == %{"WEIRD" => 1}
    assert DynamoDB.from_attribute_values(nil) == nil
  end

  # ---- dispatcher -------------------------------------------------------------------

  test "Events.decode dispatches on shape" do
    assert {:ok, %Mayfly.Events.HTTP.Request{version: :v2}} =
             Events.decode(%{
               "version" => "2.0",
               "requestContext" => %{"http" => %{"method" => "GET"}},
               "rawPath" => "/"
             })

    assert {:ok, %Mayfly.Events.HTTP.Request{version: :v1}} =
             Events.decode(%{"httpMethod" => "GET", "path" => "/"})

    assert {:ok, %Mayfly.Events.HTTP.Request{version: :alb}} =
             Events.decode(%{
               "requestContext" => %{"elb" => %{}},
               "httpMethod" => "GET",
               "path" => "/"
             })

    assert {:ok, %SQS{}} = Events.decode(@sqs)
    assert {:ok, %SNS{}} = Events.decode(@sns)
    assert {:ok, %S3{}} = Events.decode(@s3)
    assert {:ok, %EventBridge{}} = Events.decode(@eventbridge)
    assert {:ok, %Kinesis{}} = Events.decode(@kinesis)
    assert {:ok, %DynamoDB{}} = Events.decode(@dynamodb)
    assert :unknown = Events.decode(%{"name" => "plain invoke"})
    assert :unknown = Events.decode(%{"Records" => [%{"eventSource" => "aws:unknown"}]})
    assert :unknown = Events.decode(%{"Records" => []})
  end
end

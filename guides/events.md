# Event sources

Lambda hands your handler the raw JSON each service sends. `Mayfly.Events`
turns the common envelopes into structs: bodies are JSON-decoded when they
parse, base64 is undone, S3 keys are URL-decoded, DynamoDB attribute values
become plain terms, and partial-batch responses are one function call.

| Source | Decoder | Notable fields |
|---|---|---|
| API Gateway HTTP API (v2), Function URL | `Mayfly.Events.HTTP` | `method`, `path`, `query`, `headers` (lowercased), `cookies`, `body` (decoded) |
| API Gateway REST API (v1), ALB | `Mayfly.Events.HTTP` | same struct, `version: :v1 \| :alb`, multi-value headers joined |
| SQS | `Mayfly.Events.SQS` | `records[].body` (decoded), `message_attributes`, `process_batch/2` |
| SNS | `Mayfly.Events.SNS` | `records[].message` (decoded), `from_envelope/1` for SNS→SQS |
| S3 | `Mayfly.Events.S3` | `records[].bucket`, `key` (URL-decoded), `size`, `event_name` |
| EventBridge | `Mayfly.Events.EventBridge` | `source`, `detail_type`, `detail` |
| Kinesis Data Streams | `Mayfly.Events.Kinesis` | `records[].data` (base64 + JSON decoded), `process_batch/2` |
| DynamoDB Streams | `Mayfly.Events.DynamoDB` | `records[].event_name` (`:insert` …), `keys`, `new_image`, `old_image` as plain maps |

Every struct keeps the original map in `raw`. Use the specific decoder when
you know the source, or let `Mayfly.Events.decode/1` dispatch:

```elixir
def handle(event, _ctx, _state) do
  case Mayfly.Events.decode(event) do
    {:ok, %Mayfly.Events.HTTP.Request{} = req} -> serve(req)
    {:ok, %Mayfly.Events.SQS{} = sqs} -> {:ok, Mayfly.Events.SQS.process_batch(sqs, &process/1)}
    {:ok, %Mayfly.Events.S3{records: records}} -> {:ok, Enum.map(records, &ingest/1)}
    :unknown -> {:ok, %{echo: event}}
  end
end
```

## HTTP: API Gateway and Function URLs

```elixir
alias Mayfly.Events.HTTP

def handle(event, _ctx, _state) do
  req = HTTP.decode(event)

  case {req.method, req.path} do
    {"GET", "/items"} ->
      HTTP.json(200, Items.list(req.query), req, headers: %{"cache-control" => "max-age=60"})

    {"POST", "/items"} ->
      # req.body is already a map for JSON requests
      HTTP.json(201, Items.create(req.body), req, cookies: ["session=#{sid}"])

    {"GET", "/logo.png"} ->
      HTTP.binary(200, File.read!("priv/logo.png"), "image/png", req)

    _ ->
      HTTP.text(404, "not found", req)
  end
end
```

Pass the request (or its `version`) to the response helpers so they produce
the right shape: v2/Function URL responses carry `cookies`; v1 and ALB get
`multiValueHeaders` when a header value is a list; ALB also gets
`statusDescription`. `HTTP.respond/4` is the generic form.

Test locally: `mix lambda.invoke MyApp.Handler '{"name":"x"}' --event apigw-v2 --method POST --path /items`
(`--http` is an alias).

## SQS with partial batch responses

```elixir
def handle(event, _ctx, _state) do
  sqs = Mayfly.Events.SQS.decode(event)

  {:ok,
   Mayfly.Events.SQS.process_batch(sqs, fn record ->
     Orders.process(record.body)      # {:ok, _} | {:error, _} | raise
   end)}
end
```

`process_batch/2` returns `%{batchItemFailures: [%{itemIdentifier: id}]}`
for every record whose function returned `{:error, _}`, raised, exited or
threw. Create the event source mapping with
`--function-response-types ReportBatchItemFailures`; Lambda then retries only
those messages. `Mayfly.Events.Kinesis` and `Mayfly.Events.DynamoDB` offer the
same with `sequence_number` as the identifier.

SNS → SQS → Lambda: the SQS body is an SNS envelope. `Mayfly.Events.SNS.envelope?/1`
detects it and `from_envelope/1` decodes it.

## S3

```elixir
%Mayfly.Events.S3{records: [%{bucket: bucket, key: key, event_name: "ObjectCreated:Put"}]} =
  Mayfly.Events.S3.decode(event)
# key is URL-decoded: "uploads/report 2026 (final).json", ready for GetObject
```

## EventBridge

```elixir
case Mayfly.Events.EventBridge.decode(event) do
  %{source: "my.app", detail_type: "OrderPlaced", detail: %{"orderId" => id}} -> ...
  %{source: "aws.events"} -> :scheduled_tick
end
```

## DynamoDB Streams

```elixir
stream = Mayfly.Events.DynamoDB.decode(event)

for %{event_name: :insert, new_image: item} <- stream.records do
  # item: %{"id" => "order-2", "price" => 12.5, "qty" => 3, "in_stock" => true,
  #         "lines" => ["x", 7, %{"deep" => false}], "tags" => ["a", "b"], "note" => nil}
end
```

`Mayfly.Events.DynamoDB.from_attribute_values/1` converts any DynamoDB JSON
(`%{"id" => %{"S" => "a"}}`) and is public for reuse.

## Local fixtures

`mix lambda.invoke HANDLER JSON --event SOURCE` wraps your JSON in a realistic
envelope: it becomes the HTTP body, SQS body, SNS message, EventBridge
`detail`, Kinesis `data` or DynamoDB `NewImage` (plain JSON is converted to
attribute values). For S3 pass `{"key": "path/to object.txt"}`. Sources:
`apigw-v2 apigw-v1 alb sqs sns s3 eventbridge kinesis dynamodb`.

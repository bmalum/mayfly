# Idempotency

Lambda retries. Asynchronous invocations retry twice on error, SQS redelivers
after the visibility timeout, EventBridge retries for up to 24 hours, and a
network blip can deliver the same event twice. "Place the order" must still
happen once.

`Mayfly.Idempotency` from the companion package
[`mayfly_aws`](https://github.com/bmalum/mayfly_aws) gives a handler
exactly-once semantics backed by a DynamoDB table. It lives outside the core
package so the runtime stays free of `:ssl`; it starts `:inets`/`:ssl` lazily
on first use (~60–80 ms once per execution environment).

```elixir
# mix.exs
deps: [{:mayfly, "~> 1.0.0-rc"}, {:mayfly_aws, "~> 0.1"}]
```

```elixir
defmodule MyApp.Handler do
  use Mayfly.Handler

  @impl true
  def handle(%{"orderId" => id} = event, ctx, _state) do
    case Mayfly.Idempotency.run(event, fn -> place_order(event) end,
           key_fun: &("order-" <> &1["orderId"]), context: ctx, ttl: 3600) do
      {:ok, order} -> {:ok, %{status: "placed", order: order}}
      {:ok, order, :replayed} -> {:ok, %{status: "replayed", order: order}}
      {:error, :in_progress} -> {:error, %{errorType: "InProgress", errorMessage: "order #{id} is being processed"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## How it works

1. **Claim**: `PutItem` with `attribute_not_exists(id) OR expires_at < :now OR (status = INPROGRESS AND in_progress_until < :now)`
   writes `status: INPROGRESS`. The in-progress claim is valid for the
   invocation's remaining time (from `context:`), so a crashed environment
   cannot block the key forever.
2. **Execute** `fun`. `{:ok, result}` → `UpdateItem` to `COMPLETED` with the
   JSON-encoded result and `expires_at = now + ttl`.
3. **Replay**: a later call whose claim fails reads the record; `COMPLETED`
   returns `{:ok, result, :replayed}` without running `fun`; `INPROGRESS`
   returns `{:error, :in_progress}`.
4. **Release**: `{:error, _}`, raise, exit or throw delete the record and
   propagate, so the retry runs `fun` again.

Verified on Lambda: identical replayed payloads (same `placedAt`, same random
id), record removed after a raise, parallel invocations yielding one
`in_progress`.

## Table and permissions

```bash
aws dynamodb create-table --table-name idempotency \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST
aws dynamodb update-time-to-live --table-name idempotency \
  --time-to-live-specification Enabled=true,AttributeName=expires_at
```

IAM on the table: `dynamodb:PutItem`, `GetItem`, `UpdateItem`, `DeleteItem`.
Set `MAYFLY_IDEMPOTENCY_TABLE` on the function or pass `table:`.

## Choosing the key

The default key is the SHA-256 of the JSON-encoded event. That is correct for
exact retries but treats any changed field (timestamps, request ids) as a new
request. Prefer a business key: `key_fun: & &1["orderId"]`, or
`key: "tenant:#{t}:order:#{id}"`. For SQS, use the message id or a field of
the body, not the whole record (receipt handles change on redelivery).

## Costs and limits

One `PutItem` plus one `UpdateItem` per first execution, one `GetItem` per
replay; with on-demand billing that is fractions of a cent per thousand
requests. Results must be JSON-encodable and fit a DynamoDB item (400 KB);
store large results elsewhere and return a reference.

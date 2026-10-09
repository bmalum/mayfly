defmodule Mayfly.Events.SQS do
  @moduledoc """
  Amazon SQS events.

      def handle(event, _ctx, _state) do
        sqs = Mayfly.Events.SQS.decode(event)

        {:ok,
         Mayfly.Events.SQS.process_batch(sqs, fn record ->
           MyApp.Orders.process(record.body)   # {:ok, _} | {:error, _} | raise
         end)}
      end

  `process_batch/2` returns the partial-batch response
  (`%{batchItemFailures: [...]}`) so that only failed messages are retried.
  The event source mapping must be created with
  `FunctionResponseTypes=ReportBatchItemFailures` for Lambda to honour it.

  `body` is JSON-decoded when it parses, otherwise the raw string.
  `message_attributes` is flattened to `%{"name" => value}` (string or binary
  values; number values are returned as strings as SQS sends them).
  """

  alias Mayfly.Events.Util

  defmodule Record do
    @moduledoc "One SQS message."

    @type t :: %__MODULE__{
            message_id: String.t(),
            receipt_handle: String.t() | nil,
            body: term(),
            attributes: map(),
            message_attributes: %{optional(String.t()) => term()},
            md5: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil,
            raw: map()
          }

    defstruct [
      :message_id,
      :receipt_handle,
      :body,
      :md5,
      :event_source_arn,
      :region,
      attributes: %{},
      message_attributes: %{},
      raw: %{}
    ]
  end

  @type t :: %__MODULE__{records: [Record.t()], raw: map()}
  defstruct records: [], raw: %{}

  @doc "Decodes an SQS event."
  @spec decode(map()) :: t()
  def decode(%{"Records" => records} = e) do
    %__MODULE__{records: Enum.map(records, &record/1), raw: e}
  end

  @doc false
  def record(r) do
    %Record{
      message_id: r["messageId"],
      receipt_handle: r["receiptHandle"],
      body: Util.maybe_json(r["body"]),
      attributes: r["attributes"] || %{},
      message_attributes: message_attributes(r["messageAttributes"]),
      md5: r["md5OfBody"],
      event_source_arn: r["eventSourceARN"],
      region: r["awsRegion"],
      raw: r
    }
  end

  @doc "Partial batch response for the given message ids."
  @spec batch_failures([String.t()]) :: %{batchItemFailures: [%{itemIdentifier: String.t()}]}
  def batch_failures(message_ids), do: Util.batch_failures(message_ids)

  @doc """
  Runs `fun` for each record and returns the partial batch response listing
  the records for which `fun` returned `{:error, _}`, raised, exited or threw.
  """
  @spec process_batch(t(), (Record.t() -> term())) :: %{
          batchItemFailures: [%{itemIdentifier: String.t()}]
        }
  def process_batch(%__MODULE__{records: records}, fun) when is_function(fun, 1) do
    Util.process_batch(records, fun, & &1.message_id)
  end

  defp message_attributes(nil), do: %{}

  defp message_attributes(attrs) do
    Map.new(attrs, fn {name, attr} ->
      value =
        case attr do
          %{"dataType" => "Binary", "binaryValue" => b} -> Util.maybe_base64(b, true)
          %{"stringValue" => s} -> s
          %{"binaryValue" => b} -> Util.maybe_base64(b, true)
          other -> other
        end

      {name, value}
    end)
  end
end

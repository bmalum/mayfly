defmodule Mayfly.Events.Kinesis do
  @moduledoc """
  Amazon Kinesis Data Streams events.

      kinesis = Mayfly.Events.Kinesis.decode(event)

      {:ok,
       Mayfly.Events.Kinesis.process_batch(kinesis, fn record ->
         MyApp.Ingest.handle(record.data)
       end)}

  `data` is base64-decoded and JSON-decoded when it parses, otherwise the raw
  bytes. Partial batch responses use the record's `sequence_number`; the event
  source mapping needs `FunctionResponseTypes=ReportBatchItemFailures`.
  """

  alias Mayfly.Events.Util

  defmodule Record do
    @moduledoc "One Kinesis record."

    @type t :: %__MODULE__{
            partition_key: String.t() | nil,
            sequence_number: String.t(),
            data: term(),
            approximate_arrival: DateTime.t() | nil,
            event_id: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil,
            raw: map()
          }

    defstruct [
      :partition_key,
      :sequence_number,
      :data,
      :approximate_arrival,
      :event_id,
      :event_source_arn,
      :region,
      raw: %{}
    ]
  end

  @type t :: %__MODULE__{records: [Record.t()], raw: map()}
  defstruct records: [], raw: %{}

  @doc "Decodes a Kinesis event."
  @spec decode(map()) :: t()
  def decode(%{"Records" => records} = e) do
    %__MODULE__{records: Enum.map(records, &record/1), raw: e}
  end

  @doc "Partial batch response for the given sequence numbers."
  @spec batch_failures([String.t()]) :: %{batchItemFailures: [%{itemIdentifier: String.t()}]}
  def batch_failures(sequence_numbers), do: Util.batch_failures(sequence_numbers)

  @doc "Runs `fun` per record, collecting failures by sequence number."
  @spec process_batch(t(), (Record.t() -> term())) :: %{
          batchItemFailures: [%{itemIdentifier: String.t()}]
        }
  def process_batch(%__MODULE__{records: records}, fun) when is_function(fun, 1) do
    Util.process_batch(records, fun, & &1.sequence_number)
  end

  defp record(r) do
    k = r["kinesis"] || %{}

    %Record{
      partition_key: k["partitionKey"],
      sequence_number: k["sequenceNumber"],
      data: k["data"] |> Util.maybe_base64(true) |> Util.maybe_json(),
      approximate_arrival: arrival(k["approximateArrivalTimestamp"]),
      event_id: r["eventID"],
      event_source_arn: r["eventSourceARN"],
      region: r["awsRegion"],
      raw: r
    }
  end

  defp arrival(nil), do: nil

  defp arrival(seconds) when is_number(seconds) do
    seconds |> Kernel.*(1000) |> trunc() |> DateTime.from_unix!(:millisecond)
  end
end

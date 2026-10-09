defmodule Mayfly.Events.DynamoDB do
  @moduledoc """
  Amazon DynamoDB Streams events.

      stream = Mayfly.Events.DynamoDB.decode(event)

      for %{event_name: :insert, new_image: item} <- stream.records do
        # item is a plain map: %{"id" => "a1", "price" => 12.5, "tags" => ["x"], ...}
      end

  DynamoDB's typed attribute values are converted to Elixir terms:

  | Type | Elixir |
  |---|---|
  | `S` | binary |
  | `N` | integer or float |
  | `BOOL` | boolean |
  | `NULL` | `nil` |
  | `B` | binary (base64-decoded) |
  | `L` | list |
  | `M` | map |
  | `SS` / `NS` / `BS` | list of binaries / numbers / binaries |

  `from_attribute_values/1` is public so it can be reused for other
  DynamoDB JSON (e.g. `GetItem` responses).
  """

  alias Mayfly.Events.Util

  defmodule Record do
    @moduledoc "One stream record."

    @type t :: %__MODULE__{
            event_name: :insert | :modify | :remove,
            event_id: String.t() | nil,
            keys: map(),
            new_image: map() | nil,
            old_image: map() | nil,
            sequence_number: String.t() | nil,
            size_bytes: non_neg_integer() | nil,
            stream_view_type: String.t() | nil,
            table: String.t() | nil,
            event_source_arn: String.t() | nil,
            region: String.t() | nil,
            approximate_creation: DateTime.t() | nil,
            raw: map()
          }

    defstruct [
      :event_name,
      :event_id,
      :new_image,
      :old_image,
      :sequence_number,
      :size_bytes,
      :stream_view_type,
      :table,
      :event_source_arn,
      :region,
      :approximate_creation,
      keys: %{},
      raw: %{}
    ]
  end

  @type t :: %__MODULE__{records: [Record.t()], raw: map()}
  defstruct records: [], raw: %{}

  @doc "Decodes a DynamoDB Streams event."
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

  @doc "Converts a map of DynamoDB attribute values (`%{\"id\" => %{\"S\" => \"a\"}}`) into plain terms."
  @spec from_attribute_values(map() | nil) :: map() | nil
  def from_attribute_values(nil), do: nil

  def from_attribute_values(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, from_av(v)} end)

  @doc "Converts one attribute value."
  @spec from_av(map()) :: term()
  def from_av(%{"S" => s}), do: s
  def from_av(%{"N" => n}), do: Util.number(n)
  def from_av(%{"BOOL" => b}), do: b
  def from_av(%{"NULL" => true}), do: nil
  def from_av(%{"B" => b}), do: Util.maybe_base64(b, true)
  def from_av(%{"L" => list}), do: Enum.map(list, &from_av/1)
  def from_av(%{"M" => map}), do: from_attribute_values(map)
  def from_av(%{"SS" => list}), do: list
  def from_av(%{"NS" => list}), do: Enum.map(list, &Util.number/1)
  def from_av(%{"BS" => list}), do: Enum.map(list, &Util.maybe_base64(&1, true))
  def from_av(other), do: other

  defp record(r) do
    d = r["dynamodb"] || %{}
    arn = r["eventSourceARN"]

    %Record{
      event_name: event_name(r["eventName"]),
      event_id: r["eventID"],
      keys: from_attribute_values(d["Keys"]) || %{},
      new_image: from_attribute_values(d["NewImage"]),
      old_image: from_attribute_values(d["OldImage"]),
      sequence_number: d["SequenceNumber"],
      size_bytes: d["SizeBytes"],
      stream_view_type: d["StreamViewType"],
      table: table_from_arn(arn),
      event_source_arn: arn,
      region: r["awsRegion"],
      approximate_creation: creation(d["ApproximateCreationDateTime"]),
      raw: r
    }
  end

  defp event_name("INSERT"), do: :insert
  defp event_name("MODIFY"), do: :modify
  defp event_name("REMOVE"), do: :remove
  defp event_name(other), do: other

  defp table_from_arn(nil), do: nil

  defp table_from_arn(arn) do
    case Regex.run(~r{:table/([^/]+)}, arn) do
      [_, table] -> table
      _ -> nil
    end
  end

  defp creation(nil), do: nil

  defp creation(seconds) when is_number(seconds),
    do: seconds |> Kernel.*(1000) |> trunc() |> DateTime.from_unix!(:millisecond)
end

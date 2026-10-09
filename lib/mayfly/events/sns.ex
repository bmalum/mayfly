defmodule Mayfly.Events.SNS do
  @moduledoc """
  Amazon SNS notifications delivered directly to Lambda.

      %Mayfly.Events.SNS{records: [%Mayfly.Events.SNS.Record{message: %{"order" => 1}}]} =
        Mayfly.Events.SNS.decode(event)

  `message` is JSON-decoded when it parses. `message_attributes` is flattened
  to `%{"name" => value}`.

  SNS → SQS → Lambda: the SQS record `body` is an SNS envelope
  (`"Type" => "Notification"`). `from_envelope/1` turns such a body into a
  `Record`:

      sqs = Mayfly.Events.SQS.decode(event)
      for r <- sqs.records, do: Mayfly.Events.SNS.from_envelope(r.body)
  """

  alias Mayfly.Events.Util

  defmodule Record do
    @moduledoc "One SNS notification."

    @type t :: %__MODULE__{
            message_id: String.t() | nil,
            topic_arn: String.t() | nil,
            subject: String.t() | nil,
            message: term(),
            message_attributes: %{optional(String.t()) => term()},
            timestamp: DateTime.t() | String.t() | nil,
            subscription_arn: String.t() | nil,
            raw: map()
          }

    defstruct [
      :message_id,
      :topic_arn,
      :subject,
      :message,
      :timestamp,
      :subscription_arn,
      message_attributes: %{},
      raw: %{}
    ]
  end

  @type t :: %__MODULE__{records: [Record.t()], raw: map()}
  defstruct records: [], raw: %{}

  @doc "Decodes an SNS event (`Records` with `EventSource: aws:sns`)."
  @spec decode(map()) :: t()
  def decode(%{"Records" => records} = e) do
    %__MODULE__{
      records:
        Enum.map(records, fn r ->
          r["Sns"]
          |> from_envelope()
          |> Map.put(:subscription_arn, r["EventSubscriptionArn"])
          |> Map.put(:raw, r)
        end),
      raw: e
    }
  end

  @doc "Decodes an SNS envelope (the `Sns` object, or an SQS body carrying one)."
  @spec from_envelope(map()) :: Record.t()
  def from_envelope(%{} = sns) do
    %Record{
      message_id: sns["MessageId"],
      topic_arn: sns["TopicArn"],
      subject: sns["Subject"],
      message: Util.maybe_json(sns["Message"]),
      message_attributes: attributes(sns["MessageAttributes"]),
      timestamp: Util.datetime(sns["Timestamp"]),
      raw: sns
    }
  end

  @doc "True when an SQS body is an SNS notification envelope."
  @spec envelope?(term()) :: boolean()
  def envelope?(%{"Type" => "Notification", "TopicArn" => _}), do: true
  def envelope?(_), do: false

  defp attributes(nil), do: %{}

  defp attributes(attrs) do
    Map.new(attrs, fn {name, %{"Type" => type, "Value" => value}} ->
      {name, if(type == "Binary", do: Util.maybe_base64(value, true), else: value)}
    end)
  end
end

defmodule Mayfly.Events.EventBridge do
  @moduledoc """
  Amazon EventBridge events (custom events, scheduled rules, AWS service events).

      case Mayfly.Events.EventBridge.decode(event) do
        %{source: "my.app", detail_type: "OrderPlaced", detail: detail} -> ...
        %{source: "aws.events"} -> # scheduled rule tick
      end

  `detail` is the event payload map. Scheduled rules send an empty detail.
  """

  alias Mayfly.Events.Util

  @type t :: %__MODULE__{
          id: String.t() | nil,
          source: String.t() | nil,
          detail_type: String.t() | nil,
          detail: term(),
          time: DateTime.t() | String.t() | nil,
          region: String.t() | nil,
          account: String.t() | nil,
          resources: [String.t()],
          version: String.t() | nil,
          raw: map()
        }

  defstruct [
    :id,
    :source,
    :detail_type,
    :detail,
    :time,
    :region,
    :account,
    :version,
    resources: [],
    raw: %{}
  ]

  @doc "Decodes an EventBridge event."
  @spec decode(map()) :: t()
  def decode(%{} = e) do
    %__MODULE__{
      id: e["id"],
      source: e["source"],
      detail_type: e["detail-type"],
      detail: Util.maybe_json(e["detail"]),
      time: Util.datetime(e["time"]),
      region: e["region"],
      account: e["account"],
      resources: e["resources"] || [],
      version: e["version"],
      raw: e
    }
  end
end

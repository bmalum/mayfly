defmodule Mayfly.Events.S3 do
  @moduledoc """
  Amazon S3 event notifications.

      %Mayfly.Events.S3{records: [%{bucket: "my-bucket", key: "uploads/report 2026.pdf"}]} =
        Mayfly.Events.S3.decode(event)

  `key` is URL-decoded (`+` becomes a space, `%xx` sequences are decoded), which
  is the form you need for `GetObject`. `event_name` is kept as S3 sends it,
  e.g. `"ObjectCreated:Put"`.
  """

  alias Mayfly.Events.Util

  defmodule Record do
    @moduledoc "One S3 notification record."

    @type t :: %__MODULE__{
            event_name: String.t(),
            bucket: String.t(),
            bucket_arn: String.t() | nil,
            key: String.t(),
            size: non_neg_integer() | nil,
            etag: String.t() | nil,
            version_id: String.t() | nil,
            region: String.t() | nil,
            time: DateTime.t() | String.t() | nil,
            raw: map()
          }

    defstruct [
      :event_name,
      :bucket,
      :bucket_arn,
      :key,
      :size,
      :etag,
      :version_id,
      :region,
      :time,
      raw: %{}
    ]
  end

  @type t :: %__MODULE__{records: [Record.t()], raw: map()}
  defstruct records: [], raw: %{}

  @doc "Decodes an S3 event."
  @spec decode(map()) :: t()
  def decode(%{"Records" => records} = e) do
    %__MODULE__{records: Enum.map(records, &record/1), raw: e}
  end

  defp record(r) do
    s3 = r["s3"] || %{}
    obj = s3["object"] || %{}
    bucket = s3["bucket"] || %{}

    %Record{
      event_name: r["eventName"],
      bucket: bucket["name"],
      bucket_arn: bucket["arn"],
      key: Util.url_decode(obj["key"]),
      size: obj["size"],
      etag: obj["eTag"],
      version_id: obj["versionId"],
      region: r["awsRegion"],
      time: Util.datetime(r["eventTime"]),
      raw: r
    }
  end
end

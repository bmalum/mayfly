defmodule Mayfly.LogFormatter do
  @moduledoc """
  Logger formatter that emits one JSON object per line in the shape Lambda's
  [advanced logging controls](https://docs.aws.amazon.com/lambda/latest/dg/monitoring-cloudwatchlogs-advanced.html)
  expect, so CloudWatch parses level, request id and tenant id:

      {"timestamp":"2026-09-27T07:00:00.123Z","level":"INFO","requestId":"…","tenantId":"…","message":"…"}

  `Mayfly.Boot` installs it when `AWS_LAMBDA_LOG_FORMAT=JSON`. To use it
  yourself:

      config :logger, :default_formatter, {Mayfly.LogFormatter, []}

  All Logger metadata except internal keys is included; values that are not
  JSON-encodable are `inspect`ed.
  """

  @behaviour :logger_formatter

  @skip_meta [:pid, :gl, :time, :mfa, :file, :line, :domain, :report_cb, :erl_level, :ansi_color]

  @impl true
  def check_config(_config), do: :ok

  @impl true
  def format(%{level: level, msg: msg, meta: meta}, _config) do
    base = %{
      "timestamp" => timestamp(meta),
      "level" => level |> Atom.to_string() |> String.upcase(),
      "message" => message(msg, meta)
    }

    base
    |> put_meta(meta, :request_id, "requestId")
    |> put_meta(meta, :tenant_id, "tenantId")
    |> put_meta(meta, :trace_id, "traceId")
    |> Map.merge(extra_meta(meta))
    |> JSON.encode_to_iodata!()
    |> then(&[&1, ?\n])
  end

  defp timestamp(%{time: us}) when is_integer(us) do
    us
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp timestamp(_),
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp message({:report, report}, %{report_cb: cb}) when is_function(cb, 1) do
    {format, args} = cb.(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string()
  end

  defp message({:report, report}, _meta), do: inspect(report)

  defp message({format, args}, _meta),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp put_meta(map, meta, key, name) do
    case Map.get(meta, key) do
      nil -> map
      value -> Map.put(map, name, to_json_value(value))
    end
  end

  defp extra_meta(meta) do
    meta
    |> Map.drop(@skip_meta ++ [:request_id, :tenant_id, :trace_id])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), to_json_value(v)} end)
  end

  defp to_json_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp to_json_value(v) when is_atom(v), do: Atom.to_string(v)
  defp to_json_value(v), do: inspect(v)
end

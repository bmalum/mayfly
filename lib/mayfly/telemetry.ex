defmodule Mayfly.Telemetry do
  @moduledoc """
  Telemetry events emitted by the runtime. `:telemetry` is an optional
  dependency; when it is not present the calls are no-ops.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:mayfly, :init, :stop]` | `duration` (native) | `handler`, `result` (`:ok` / `:error`) |
  | `[:mayfly, :invocation, :start]` | `system_time` | `context` |
  | `[:mayfly, :invocation, :stop]` | `duration` | `context`, `result` (`:ok` / `:error`), `error_type` |
  | `[:mayfly, :poll, :error]` | `backoff_ms` | `reason` |

  Attach with `:telemetry.attach/4` from your handler's `init/1`, or use a
  reporter such as `telemetry_metrics_cloudwatch`.
  """

  @doc false
  def span(event, metadata, fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    execute(event ++ [:start], %{system_time: System.system_time()}, metadata)
    {result, extra} = fun.()
    duration = System.monotonic_time() - start
    execute(event ++ [:stop], %{duration: duration}, Map.merge(metadata, extra))
    result
  end

  @doc false
  def execute(event, measurements, metadata) do
    # apply/3 keeps consumers that skip the optional :telemetry dep warning-free.
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  end
end

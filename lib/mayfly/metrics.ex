defmodule Mayfly.Metrics do
  @moduledoc """
  CloudWatch metrics without API calls, using the
  [Embedded Metric Format](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html):
  one JSON line on stdout that CloudWatch Logs turns into metrics.

      Mayfly.Metrics.emit("MyApp", %{"OrdersPlaced" => 1, "CartValue" => {129.5, "None"}},
        dimensions: %{"Tenant" => tenant},
        properties: %{"orderId" => id})

      Mayfly.Metrics.count("MyApp", "Retries", 2, dimensions: %{"Queue" => "orders"})
      Mayfly.Metrics.timing("MyApp", "DbLatency", 42)      # Milliseconds

  ## Invocation metrics

  Attach once (in `init/1`) and every invocation emits `Duration`
  (Milliseconds), `Errors` (0/1) and `ColdStart` (1 on the first invocation of
  an execution environment, 0 afterwards) with the dimension `FunctionName`:

      def init(_opts) do
        Mayfly.Metrics.attach_invocation_metrics("MyApp")
        {:ok, nil}
      end

  Requires the optional `:telemetry` dependency.

  ## Why not Logger?

  CloudWatch parses EMF from the raw log line, which must be a single,
  standalone JSON object. `Mayfly.LogFormatter` wraps messages in its own
  object, so metrics are written straight to stdout with `IO.puts/2`.
  Lambda captures stdout into the function's log stream.
  """

  @units ~w(Seconds Microseconds Milliseconds Bytes Kilobytes Megabytes Gigabytes Terabytes
            Bits Kilobits Megabits Gigabits Terabits Percent Count Bytes/Second Kilobytes/Second
            Megabytes/Second Gigabytes/Second Terabytes/Second Bits/Second Kilobits/Second
            Megabits/Second Gigabits/Second Terabits/Second Count/Second None)

  @max_dimensions 30
  @max_metrics 100

  @typedoc "Metric value: a number, or `{number, unit}`."
  @type value :: number() | {number(), String.t()}

  @doc """
  Emits one EMF record. `metrics` maps names to values or `{value, unit}`.

  Options:
    * `:dimensions` – map of up to #{@max_dimensions} string pairs; one dimension set
    * `:properties` – extra non-metric fields (searchable in Logs Insights)
    * `:unit` – default unit for plain numbers (default `"Count"`)
    * `:high_resolution` – `true` for 1-second storage resolution
    * `:timestamp` – Unix ms (default now)
    * `:device` – IO device (default `:stdio`; tests pass a StringIO)
  """
  @spec emit(String.t(), %{optional(String.t()) => value()}, keyword()) :: :ok
  def emit(namespace, metrics, opts \\ []) when is_binary(namespace) and is_map(metrics) do
    record = build(namespace, metrics, opts)
    IO.puts(Keyword.get(opts, :device, :stdio), JSON.encode!(record))
  end

  @doc "Emits a `Count` metric."
  @spec count(String.t(), String.t(), number(), keyword()) :: :ok
  def count(namespace, name, value \\ 1, opts \\ [])

  # `count(ns, name, dimensions: ...)` – the keyword list is the options, not the value.
  def count(namespace, name, opts, []) when is_list(opts), do: count(namespace, name, 1, opts)

  def count(namespace, name, value, opts),
    do: emit(namespace, %{name => {value, "Count"}}, opts)

  @doc "Emits a `Milliseconds` metric."
  @spec timing(String.t(), String.t(), number(), keyword()) :: :ok
  def timing(namespace, name, ms, opts \\ []),
    do: emit(namespace, %{name => {ms, "Milliseconds"}}, opts)

  @doc """
  Builds the EMF record without writing it. Raises `ArgumentError` on invalid
  units or too many dimensions/metrics.
  """
  @spec build(String.t(), %{optional(String.t()) => value()}, keyword()) :: map()
  def build(namespace, metrics, opts \\ []) do
    dimensions =
      opts
      |> Keyword.get(:dimensions, %{})
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    properties =
      opts |> Keyword.get(:properties, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    default_unit = Keyword.get(opts, :unit, "Count")
    resolution = if Keyword.get(opts, :high_resolution, false), do: 1, else: 60

    if map_size(dimensions) > @max_dimensions,
      do:
        raise(
          ArgumentError,
          "EMF allows at most #{@max_dimensions} dimensions, got #{map_size(dimensions)}"
        )

    if map_size(metrics) == 0 or map_size(metrics) > @max_metrics,
      do: raise(ArgumentError, "EMF needs 1..#{@max_metrics} metrics, got #{map_size(metrics)}")

    {definitions, values} =
      Enum.reduce(metrics, {[], %{}}, fn {name, value}, {defs, vals} ->
        {number, unit} = normalise(value, default_unit)
        name = to_string(name)
        def_ = %{"Name" => name, "Unit" => unit, "StorageResolution" => resolution}
        {[def_ | defs], Map.put(vals, name, number)}
      end)

    aws = %{
      "Timestamp" =>
        Keyword.get_lazy(opts, :timestamp, fn -> System.system_time(:millisecond) end),
      "CloudWatchMetrics" => [
        %{
          "Namespace" => namespace,
          "Dimensions" => [dimensions |> Map.keys() |> Enum.sort()],
          "Metrics" => Enum.reverse(definitions)
        }
      ]
    }

    properties
    |> Map.merge(dimensions)
    |> Map.merge(values)
    |> Map.put("_aws", aws)
  end

  @doc """
  Attaches a `:telemetry` handler to `[:mayfly, :invocation, :stop]` that emits
  `Duration`, `Errors` and `ColdStart` under `namespace` with dimension
  `FunctionName`. Safe to call once per environment; returns `{:error, :already_exists}`
  if attached twice. Returns `{:error, :telemetry_not_available}` without the dep.
  """
  @spec attach_invocation_metrics(String.t(), keyword()) :: :ok | {:error, term()}
  def attach_invocation_metrics(namespace, opts \\ []) do
    if Code.ensure_loaded?(:telemetry) do
      handler_id = {__MODULE__, namespace}

      apply(:telemetry, :attach, [
        handler_id,
        [:mayfly, :invocation, :stop],
        &__MODULE__.handle_invocation_stop/4,
        %{
          namespace: namespace,
          device: Keyword.get(opts, :device, :stdio),
          cold: :atomics.new(1, [])
        }
      ])
    else
      {:error, :telemetry_not_available}
    end
  end

  @doc false
  def handle_invocation_stop(
        _event,
        %{duration: duration},
        %{context: ctx, result: result},
        config
      ) do
    # First invocation in this environment flips the flag from 0 to 1.
    cold = if :atomics.compare_exchange(config.cold, 1, 0, 1) == :ok, do: 1, else: 0
    ms = System.convert_time_unit(duration, :native, :microsecond) / 1000

    emit(
      config.namespace,
      %{
        "Duration" => {ms, "Milliseconds"},
        "Errors" => {if(result == :error, do: 1, else: 0), "Count"},
        "ColdStart" => {cold, "Count"}
      },
      dimensions: %{"FunctionName" => function_name(ctx)},
      properties: %{"requestId" => ctx.request_id},
      device: config.device
    )
  end

  @doc """
  Attaches a `:telemetry` handler to `[:mayfly, :platform, :report]` (emitted by
  `Mayfly.Extension` when the extension is enabled) that publishes Lambda's
  own numbers as EMF metrics under `namespace`, dimension `FunctionName`:
  `Duration`, `BilledDuration`, `MaxMemoryUsed`, `MemorySize`, and
  `InitDuration` when present (cold starts). Unlike
  `attach_invocation_metrics/2`, `Duration` here is what Lambda measured and
  `BilledDuration` is what you pay for. The report for an invocation arrives
  after that invocation has finished, attributed by `requestId`.
  """
  @spec attach_platform_metrics(String.t(), keyword()) :: :ok | {:error, term()}
  def attach_platform_metrics(namespace, opts \\ []) do
    if Code.ensure_loaded?(:telemetry) do
      apply(:telemetry, :attach, [
        {__MODULE__, :platform, namespace},
        [:mayfly, :platform, :report],
        &__MODULE__.handle_platform_report/4,
        %{namespace: namespace, device: Keyword.get(opts, :device, :stdio)}
      ])
    else
      {:error, :telemetry_not_available}
    end
  end

  @doc false
  def handle_platform_report(_event, measurements, metadata, config) do
    metrics =
      %{
        "Duration" => {measurements[:duration_ms], "Milliseconds"},
        "BilledDuration" => {measurements[:billed_duration_ms], "Milliseconds"},
        "MaxMemoryUsed" => {measurements[:max_memory_used_mb], "Megabytes"},
        "MemorySize" => {measurements[:memory_size_mb], "Megabytes"},
        "InitDuration" => {measurements[:init_duration_ms], "Milliseconds"}
      }
      |> Enum.reject(fn {_, {v, _}} -> is_nil(v) end)
      |> Map.new()

    if metrics != %{} do
      emit(
        config.namespace,
        metrics,
        dimensions: %{"FunctionName" => function_name(nil)},
        properties: %{"requestId" => metadata[:request_id], "status" => metadata[:status]},
        device: config.device
      )
    end

    :ok
  end

  defp function_name(%{env: %{function_name: name}}) when is_binary(name), do: name
  defp function_name(_), do: System.get_env("AWS_LAMBDA_FUNCTION_NAME") || "local"

  defp normalise({number, unit}, _default) when is_number(number) and is_binary(unit) do
    unit in @units ||
      raise ArgumentError, "unknown EMF unit #{inspect(unit)}; see Mayfly.Metrics docs"

    {number, unit}
  end

  defp normalise(number, default) when is_number(number),
    do: normalise({number, default}, default)

  defp normalise(other, _),
    do:
      raise(
        ArgumentError,
        "metric value must be a number or {number, unit}, got #{inspect(other)}"
      )
end

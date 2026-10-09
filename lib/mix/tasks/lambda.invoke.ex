defmodule Mix.Tasks.Lambda.Invoke do
  @shortdoc "Invokes a handler locally through an emulated Runtime API"

  @moduledoc """
  Runs your handler exactly as Mayfly would inside Lambda – handler
  resolution, `init/1`, JSON decoding, context, error formatting – against
  `Mayfly.LocalRuntime`, and prints the response or error.

      mix lambda.invoke MyApp.Handler '{"name":"world"}'
      mix lambda.invoke MyApp.Handler event.json
      echo '{"a":1}' | mix lambda.invoke MyApp.Handler -

  The handler may also be a legacy `Module.function`. Exit status is 0 for a
  successful invocation and 1 for an error (including init errors).

  ## Options

      --timeout MS     Deadline reported in the context (default 30000)
      --raw            Print the raw response body instead of pretty JSON
      --event SOURCE   Wrap the given JSON in a realistic envelope of that
                       source, so handlers using `Mayfly.Events` can be tested
                       locally. SOURCE is one of
                       apigw-v2 (also Function URL), apigw-v1, alb, sqs, sns,
                       s3, eventbridge, kinesis, dynamodb.
                       The JSON becomes the HTTP body / SQS body / SNS message /
                       EventBridge detail / Kinesis data / DynamoDB NewImage.
                       For s3 pass {"key":"path/to object.txt"}.
      --http           Alias for --event apigw-v2
      --method M       HTTP method for HTTP envelopes (default POST)
      --path P         Request path for HTTP envelopes (default /)
      --detail-type T  EventBridge detail-type (default LocalEvent)
      --source S       EventBridge source (default mix.lambda.invoke)
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          timeout: :integer,
          raw: :boolean,
          event: :string,
          http: :boolean,
          method: :string,
          path: :string,
          detail_type: :string,
          source: :string
        ]
      )

    {handler, event} =
      case positional do
        [handler, event] -> {handler, read_event(event)}
        [handler] -> {handler, "{}"}
        _ -> Mix.raise("usage: mix lambda.invoke HANDLER [EVENT_JSON | FILE | -]")
      end

    event = wrap_event(event, opts)

    Mix.Task.run("app.start")

    {:ok, rt} = Mayfly.LocalRuntime.start_link()
    address = Mayfly.LocalRuntime.address(rt)

    case Mayfly.start_link(handler: handler, runtime_api: address, concurrency: 1) do
      {:ok, _} ->
        rt
        |> Mayfly.LocalRuntime.invoke(event, timeout: Keyword.get(opts, :timeout, 30_000))
        |> print(opts[:raw])

      {:error, {:init_error, payload}} ->
        Mix.shell().error(pretty(payload))
        exit({:shutdown, 1})
    end
  end

  defp wrap_event(body, opts) do
    source = opts[:event] || if(opts[:http], do: "apigw-v2")

    case source do
      nil ->
        body

      source ->
        fixture_opts =
          [
            method: opts[:method],
            path: opts[:path],
            detail_type: opts[:detail_type],
            source: opts[:source]
          ]
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        case Mix.Tasks.Lambda.Invoke.Fixtures.wrap(source, body, fixture_opts) do
          {:ok, wrapped} -> wrapped
          {:error, msg} -> Mix.raise(msg)
        end
    end
  end

  defp read_event("-"), do: IO.read(:stdio, :eof)

  defp read_event(arg) do
    if File.regular?(arg), do: File.read!(arg), else: arg
  end

  defp print({:ok, %{body: body, headers: headers, trailers: trailers}}, raw?) do
    if trailers != %{} do
      Mix.shell().error("Stream ended with error trailers: #{inspect(trailers)}")
    end

    content_type =
      List.keyfind(headers, "content-type", 0)
      |> then(fn
        {_, v} -> v
        nil -> ""
      end)

    if raw? != true and String.starts_with?(content_type, "application/json") do
      case JSON.decode(body) do
        {:ok, term} -> Mix.shell().info(pretty(term))
        _ -> Mix.shell().info(body)
      end
    else
      Mix.shell().info(body)
    end
  end

  defp print({:error, payload}, _raw?) do
    Mix.shell().error(pretty(payload))
    exit({:shutdown, 1})
  end

  defp pretty(term), do: inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity)
end

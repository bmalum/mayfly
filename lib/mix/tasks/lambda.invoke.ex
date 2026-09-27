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
      --http           Wrap the event the way a Function URL / API Gateway v2
                       does (`{"version":"2.0","rawPath":...,"body":...}`), so
                       handlers written for HTTP events can be tested locally
      --method M       HTTP method for --http (default POST)
      --path P         Request path for --http (default /)
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [timeout: :integer, raw: :boolean, http: :boolean, method: :string, path: :string]
      )

    {handler, event} =
      case positional do
        [handler, event] -> {handler, read_event(event)}
        [handler] -> {handler, "{}"}
        _ -> Mix.raise("usage: mix lambda.invoke HANDLER [EVENT_JSON | FILE | -]")
      end

    event =
      if opts[:http],
        do: http_event(event, opts[:method] || "POST", opts[:path] || "/"),
        else: event

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

  @doc false
  def http_event(body, method, path) do
    method = String.upcase(method)
    now = System.system_time(:millisecond)

    JSON.encode!(%{
      version: "2.0",
      routeKey: "$default",
      rawPath: path,
      rawQueryString: "",
      headers: %{"content-type" => "application/json", "host" => "localhost"},
      requestContext: %{
        http: %{
          method: method,
          path: path,
          protocol: "HTTP/1.1",
          sourceIp: "127.0.0.1",
          userAgent: "mix lambda.invoke"
        },
        requestId: "local-#{now}",
        timeEpoch: now
      },
      body: body,
      isBase64Encoded: false
    })
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

defmodule Mayfly.RuntimeAPI do
  @moduledoc """
  Client for the [Lambda Runtime API](https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html)
  (version 2018-06-01), built on `Mayfly.HTTP`.

  A behaviour as well as the default implementation, so `Mayfly.Poller` can be
  tested against a fake. All functions return `:ok`/`{:ok, _}` for 2xx and
  `{:error, {:http, status, body}}` or `{:error, transport_reason}` otherwise.

  ## Headers handled

    * `Lambda-Runtime-Invocation-Id` is echoed on `/response` and `/error`.
    * `Lambda-Runtime-Function-Error-Type` is set from
      `Mayfly.ErrorPayload.header_type/1`.
    * `Lambda-Runtime-Function-Xray-Error-Cause` carries an X-Ray cause document
      (skipped when larger than 1 MiB).
    * Streaming responses use `Lambda-Runtime-Function-Response-Mode: streaming`,
      chunked transfer encoding and error trailers.
  """

  alias Mayfly.{Context, ErrorPayload, HTTP, Response}

  @type endpoint :: {String.t(), :inet.port_number()}
  @type invocation :: %{headers: [{String.t(), String.t()}], body: binary()}
  @type error :: {:http, 100..599, binary()} | term()

  @callback next_invocation(endpoint()) :: {:ok, invocation()} | {:error, error()}
  @callback invocation_response(endpoint(), Context.t(), Response.t()) :: :ok | {:error, error()}
  @callback invocation_error(endpoint(), Context.t(), ErrorPayload.t()) :: :ok | {:error, error()}
  @callback init_error(endpoint(), ErrorPayload.t()) :: :ok | {:error, error()}

  @behaviour __MODULE__

  @api "/2018-06-01"
  @xray_cause_max 1024 * 1024

  @doc """
  Parses `AWS_LAMBDA_RUNTIME_API` (`host:port`) into an endpoint tuple.
  Returns `nil` when unset.
  """
  @spec endpoint(String.t() | nil) :: endpoint() | nil
  def endpoint(value \\ System.get_env("AWS_LAMBDA_RUNTIME_API"))
  def endpoint(nil), do: nil

  def endpoint(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 80}
    end
  end

  @impl true
  def next_invocation(endpoint) do
    case HTTP.get(endpoint, @api <> "/runtime/invocation/next") do
      {:ok, %{status: 200, headers: headers, body: body}} ->
        {:ok, %{headers: headers, body: body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def invocation_response(endpoint, %Context{} = ctx, %Response{mode: :buffered} = response) do
    path = @api <> "/runtime/invocation/#{ctx.request_id}/response"

    case Response.encode_buffered(response) do
      {:ok, content_type, body} ->
        headers = [{"content-type", content_type} | invocation_headers(ctx)]
        accept(HTTP.post(endpoint, path, headers, body))

      {:error, exception} ->
        payload =
          ErrorPayload.runtime(
            "InvalidResponse",
            "Handler result could not be encoded: " <> Exception.message(exception)
          )

        invocation_error(endpoint, ctx, payload)
    end
  end

  def invocation_response(endpoint, %Context{} = ctx, %Response{mode: :streaming} = response) do
    path = @api <> "/runtime/invocation/#{ctx.request_id}/response"
    {content_type, chunks} = Response.stream_chunks(response)

    headers = [
      {"content-type", content_type},
      {"lambda-runtime-function-response-mode", "streaming"}
      | invocation_headers(ctx)
    ]

    accept(
      HTTP.post_chunked(endpoint, path, headers, chunks,
        trailer_names: [
          "Lambda-Runtime-Function-Error-Type",
          "Lambda-Runtime-Function-Error-Body"
        ],
        trailer_fun: &stream_trailers/1
      )
    )
  end

  @impl true
  def invocation_error(endpoint, %Context{} = ctx, payload) do
    path = @api <> "/runtime/invocation/#{ctx.request_id}/error"
    post_error(endpoint, path, error_headers(payload) ++ invocation_headers(ctx), payload)
  end

  @impl true
  def init_error(endpoint, payload) do
    post_error(endpoint, @api <> "/runtime/init/error", error_headers(payload), payload)
  end

  # -- helpers ----------------------------------------------------------------

  defp post_error(endpoint, path, headers, payload) do
    body = JSON.encode_to_iodata!(payload)
    accept(HTTP.post(endpoint, path, [{"content-type", "application/json"} | headers], body))
  end

  defp invocation_headers(%Context{invocation_id: nil}), do: []
  defp invocation_headers(%Context{invocation_id: id}), do: [{"lambda-runtime-invocation-id", id}]

  defp error_headers(payload) do
    cause = payload |> ErrorPayload.xray_cause() |> JSON.encode!()
    base = [{"lambda-runtime-function-error-type", ErrorPayload.header_type(payload.errorType)}]

    if byte_size(cause) < @xray_cause_max,
      do: [{"lambda-runtime-function-xray-error-cause", cause} | base],
      else: base
  end

  defp stream_trailers(:ok), do: []

  defp stream_trailers({:error, reason, stacktrace}) do
    payload =
      case reason do
        %{__exception__: true} = e -> ErrorPayload.from_term(e, stacktrace)
        {kind, r} -> ErrorPayload.from_caught(kind, r, stacktrace)
      end

    [
      {"Lambda-Runtime-Function-Error-Type", ErrorPayload.header_type(payload.errorType)},
      {"Lambda-Runtime-Function-Error-Body", Base.encode64(JSON.encode!(payload))}
    ]
  end

  defp accept({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp accept({:ok, %{status: status, body: body}}), do: {:error, {:http, status, body}}
  defp accept({:error, _} = error), do: error
end

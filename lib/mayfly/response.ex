defmodule Mayfly.Response do
  @moduledoc """
  What a handler may return inside `{:ok, _}`.

  ## Plain values

  Any JSON-encodable term (`map`, `list`, `binary`, number, `nil`, boolean) is
  encoded with `JSON` and sent with `Content-Type: application/json`. This is
  what most handlers return.

  ## `%Mayfly.Response{}`

  Use the struct when you need control over the content type or want to
  stream:

      # raw bytes, custom content type
      %Mayfly.Response{body: png, content_type: "image/png"}

      # streamed: any Enumerable of iodata (Stream, list, ...)
      %Mayfly.Response{body: Stream.map(tokens, &chunk/1), content_type: "text/event-stream"}
      |> Mayfly.Response.stream()

      # streamed through a Function URL with status/headers:
      %Mayfly.Response{body: stream}
      |> Mayfly.Response.stream()
      |> Mayfly.Response.http(status: 200, headers: %{"content-type" => "text/plain"}, cookies: [])

  Streaming requires the function to be invoked with `RESPONSE_STREAM` invoke
  mode (Function URLs) or `InvokeWithResponseStream`. Chunks are written
  synchronously; if Lambda stops reading (bandwidth cap, disconnected client)
  the producer blocks. `send_timeout` (ms, default 30 000) bounds a single
  stalled write, after which the stream is aborted. Errors raised while the
  stream is being consumed are reported to Lambda via HTTP trailers and
  forwarded to the client as error metadata; the response is otherwise treated
  as successful, so validate early and fail before the first chunk if you can.
  """

  @type t :: %__MODULE__{
          body: term() | Enumerable.t(),
          content_type: String.t(),
          mode: :buffered | :streaming,
          http: nil | %{status: pos_integer(), headers: map(), cookies: [String.t()]},
          send_timeout: pos_integer()
        }

  defstruct body: nil,
            content_type: "application/json",
            mode: :buffered,
            http: nil,
            send_timeout: 30_000

  @prelude_content_type "application/vnd.awslambda.http-integration-response"
  @prelude_delimiter <<0, 0, 0, 0, 0, 0, 0, 0>>

  @doc "Marks the response as streamed; `body` must be an `Enumerable` of iodata."
  @spec stream(t(), keyword()) :: t()
  def stream(%__MODULE__{} = r, opts \\ []) do
    %{r | mode: :streaming, send_timeout: Keyword.get(opts, :send_timeout, r.send_timeout)}
  end

  @doc """
  Adds the Function URL HTTP integration prelude (status, headers, cookies) to a
  streamed response. Lambda strips it before forwarding the body to the client.
  """
  @spec http(t(), keyword()) :: t()
  def http(%__MODULE__{} = r, opts) do
    http = %{
      status: Keyword.get(opts, :status, 200),
      headers: opts |> Keyword.get(:headers, %{}) |> Map.new(),
      cookies: Keyword.get(opts, :cookies, [])
    }

    %{r | http: http}
  end

  @doc false
  # Normalises whatever the handler returned into a struct.
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = r), do: r
  def normalize(value), do: %__MODULE__{body: value}

  @doc false
  # Encodes a buffered response: {:ok, content_type, iodata} | {:error, exception}
  @spec encode_buffered(t()) :: {:ok, String.t(), iodata()} | {:error, Exception.t()}
  def encode_buffered(%__MODULE__{content_type: "application/json", body: body}) do
    {:ok, "application/json", JSON.encode_to_iodata!(body)}
  rescue
    e -> {:error, e}
  end

  def encode_buffered(%__MODULE__{content_type: ct, body: body})
      when is_binary(body) or is_list(body) do
    {:ok, ct, body}
  end

  def encode_buffered(%__MODULE__{content_type: ct, body: body}) do
    {:error,
     %ArgumentError{
       message:
         "response with content type #{ct} must have an iodata body, got: #{inspect(body, limit: 20)}"
     }}
  end

  @doc false
  # Returns {content_type, chunks} for a streamed response, prepending the
  # Function URL prelude when `http` is set.
  @spec stream_chunks(t()) :: {String.t(), Enumerable.t()}
  def stream_chunks(%__MODULE__{http: nil, content_type: ct, body: body}), do: {ct, body}

  def stream_chunks(%__MODULE__{http: http, content_type: ct, body: body}) do
    headers = Map.put_new(http.headers, "content-type", ct)

    prelude =
      JSON.encode_to_iodata!(%{statusCode: http.status, headers: headers, cookies: http.cookies})

    {@prelude_content_type, Stream.concat([prelude, @prelude_delimiter], body)}
  end
end

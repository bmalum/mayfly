defmodule Mayfly.HTTP do
  @moduledoc """
  Minimal HTTP/1.1 client over `:gen_tcp` for the link-local Lambda Runtime API.

  Why not `:httpc`? It needs `:inets` and `:ssl` (slower boot), returns
  charlists, cannot send chunked request bodies with trailers (required for
  response streaming) and applies proxy settings the Runtime API must never see.
  The Runtime API is plain HTTP/1.1 on a trusted local socket, so a small,
  explicit client is both safer and faster.

  All functions return `{:ok, %{status: s, headers: [{name, value}], body: b}}`
  (header names lowercased) or `{:error, reason}`. Status codes are not
  interpreted here; `Mayfly.RuntimeAPI` does that.
  """

  @type header :: {String.t(), String.t()}
  @type response :: %{status: 100..599, headers: [header()], body: binary()}

  @connect_timeout 5_000
  @recv_timeout 30_000
  @send_timeout 30_000

  @doc """
  `GET path`. `:timeout` defaults to `:infinity` because `/next` blocks until
  an invocation arrives (Lambda freezes the sandbox in between).
  """
  @spec get({String.t(), :inet.port_number()}, String.t(), [header()], keyword()) ::
          {:ok, response()} | {:error, term()}
  def get({host, port}, path, headers \\ [], opts \\ []) do
    request({host, port}, "GET", path, headers, "", Keyword.put_new(opts, :timeout, :infinity))
  end

  @doc "`POST path` with a complete body (`Content-Length`)."
  @spec post({String.t(), :inet.port_number()}, String.t(), [header()], iodata(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def post({host, port}, path, headers, body, opts \\ []) do
    headers = [{"content-length", body |> IO.iodata_length() |> Integer.to_string()} | headers]
    request({host, port}, "POST", path, headers, body, opts)
  end

  @doc "`PUT path` with a complete body (`Content-Length`)."
  @spec put({String.t(), :inet.port_number()}, String.t(), [header()], iodata(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def put({host, port}, path, headers, body, opts \\ []) do
    headers = [{"content-length", body |> IO.iodata_length() |> Integer.to_string()} | headers]
    request({host, port}, "PUT", path, headers, body, opts)
  end

  @doc """
  `POST path` with `Transfer-Encoding: chunked`. `chunks` is an enumerable of
  iodata; it is consumed lazily and each element is written as one chunk.

  `trailer_fun` is called after the enumerable finishes (or when it raises)
  with `:ok | {:error, exception, stacktrace}` and must return a list of
  trailer headers; the names must be announced up front via `:trailer_names`.

  Backpressure: each chunk is written synchronously, so a producer that
  outpaces the consumer (Lambda caps streaming at 2 MB/s after the first 6 MB)
  simply blocks in `Enum.reduce_while/3`. `:send_timeout` (ms, default 30 000)
  bounds how long a single chunk write may stall before the stream is aborted
  with `{:error, :timeout}`; the error is reported through the trailers.
  """
  @spec post_chunked(
          {String.t(), :inet.port_number()},
          String.t(),
          [header()],
          Enumerable.t(),
          keyword()
        ) :: {:ok, response()} | {:error, term()}
  def post_chunked({host, port}, path, headers, chunks, opts \\ []) do
    trailer_names = Keyword.get(opts, :trailer_names, [])
    trailer_fun = Keyword.get(opts, :trailer_fun, fn _ -> [] end)
    timeout = Keyword.get(opts, :timeout, @recv_timeout)
    send_timeout = Keyword.get(opts, :send_timeout, @send_timeout)

    headers =
      [{"transfer-encoding", "chunked"} | headers] ++
        if(trailer_names == [], do: [], else: [{"trailer", Enum.join(trailer_names, ", ")}])

    with {:ok, socket} <-
           connect(host, port, send_timeout: send_timeout, send_timeout_close: true),
         :ok <- :gen_tcp.send(socket, head("POST", path, host, headers)),
         :ok <- send_chunks(socket, chunks, trailer_fun) do
      receive_response(socket, timeout)
    end
  end

  # -- request -----------------------------------------------------------------

  defp request({host, port}, method, path, headers, body, opts) do
    timeout = Keyword.get(opts, :timeout, @recv_timeout)

    with {:ok, socket} <- connect(host, port),
         :ok <- :gen_tcp.send(socket, [head(method, path, host, headers), body]) do
      receive_response(socket, timeout)
    end
  end

  defp connect(host, port, extra \\ []) do
    :gen_tcp.connect(
      String.to_charlist(host),
      port,
      [:binary, active: false, nodelay: true] ++ extra,
      @connect_timeout
    )
  end

  defp head(method, path, host, headers) do
    header_lines = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

    [
      method,
      " ",
      path,
      " HTTP/1.1\r\nhost: ",
      host,
      "\r\nuser-agent: mayfly/",
      Application.spec(:mayfly, :vsn) || "dev",
      "\r\nconnection: close\r\n",
      header_lines,
      "\r\n"
    ]
  end

  defp send_chunks(socket, chunks, trailer_fun) do
    result =
      try do
        Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
          case send_chunk(socket, chunk) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      rescue
        e -> {:error, e, __STACKTRACE__}
      catch
        kind, reason -> {:error, {kind, reason}, __STACKTRACE__}
      end

    case result do
      :ok -> send_last_chunk(socket, trailer_fun.(:ok))
      {:error, _, _} = failure -> send_last_chunk(socket, trailer_fun.(failure))
      # socket-level failure (e.g. send timeout): the connection is gone.
      {:error, _} = tcp_error -> tcp_error
    end
  end

  defp send_chunk(socket, chunk) do
    case IO.iodata_length(chunk) do
      # A zero-length chunk would terminate the body; skip it.
      0 -> :ok
      len -> :gen_tcp.send(socket, [Integer.to_string(len, 16), "\r\n", chunk, "\r\n"])
    end
  end

  defp send_last_chunk(socket, trailers) do
    lines = for {k, v} <- trailers, do: [k, ": ", v, "\r\n"]
    :gen_tcp.send(socket, ["0\r\n", lines, "\r\n"])
  end

  # -- response ----------------------------------------------------------------

  defp receive_response(socket, timeout) do
    result =
      with {:ok, status, rest} <- read_status(socket, "", timeout),
           {:ok, headers, rest} <- read_headers(socket, rest, [], timeout),
           {:ok, body} <- read_body(socket, headers, rest, timeout) do
        {:ok, %{status: status, headers: headers, body: body}}
      end

    :gen_tcp.close(socket)
    result
  end

  defp read_status(socket, buffer, timeout) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case line do
          <<"HTTP/1.", _, " ", code::binary-size(3), _::binary>> ->
            {:ok, String.to_integer(code), rest}

          _ ->
            {:error, {:bad_status_line, line}}
        end

      [_] ->
        with {:ok, more} <- recv(socket, timeout),
             do: read_status(socket, buffer <> more, timeout)
    end
  end

  defp read_headers(socket, buffer, acc, timeout) do
    case :binary.split(buffer, "\r\n") do
      ["", rest] ->
        {:ok, Enum.reverse(acc), rest}

      [line, rest] ->
        case :binary.split(line, ":") do
          [name, value] ->
            header = {name |> String.trim() |> String.downcase(), String.trim(value)}
            read_headers(socket, rest, [header | acc], timeout)

          _ ->
            {:error, {:bad_header, line}}
        end

      [_] ->
        with {:ok, more} <- recv(socket, timeout),
             do: read_headers(socket, buffer <> more, acc, timeout)
    end
  end

  defp read_body(socket, headers, buffer, timeout) do
    cond do
      chunked?(headers) ->
        read_chunked(socket, buffer, [], timeout)

      length = content_length(headers) ->
        read_exact(socket, buffer, length, timeout)

      true ->
        read_until_close(socket, buffer, timeout)
    end
  end

  defp read_exact(_socket, buffer, length, _timeout) when byte_size(buffer) >= length do
    {:ok, binary_part(buffer, 0, length)}
  end

  defp read_exact(socket, buffer, length, timeout) do
    with {:ok, more} <- recv(socket, timeout),
         do: read_exact(socket, buffer <> more, length, timeout)
  end

  defp read_until_close(socket, buffer, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, more} -> read_until_close(socket, buffer <> more, timeout)
      {:error, :closed} -> {:ok, buffer}
      {:error, _} = error -> error
    end
  end

  defp read_chunked(socket, buffer, acc, timeout) do
    case :binary.split(buffer, "\r\n") do
      [size_line, rest] ->
        size = size_line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

        if size == 0 do
          # Ignore trailers on the response side.
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          with {:ok, chunk, rest} <- take_chunk(socket, rest, size, timeout),
               do: read_chunked(socket, rest, [chunk | acc], timeout)
        end

      [_] ->
        with {:ok, more} <- recv(socket, timeout),
             do: read_chunked(socket, buffer <> more, acc, timeout)
    end
  end

  defp take_chunk(_socket, buffer, size, _timeout) when byte_size(buffer) >= size + 2 do
    <<chunk::binary-size(^size), "\r\n", rest::binary>> = buffer
    {:ok, chunk, rest}
  end

  defp take_chunk(socket, buffer, size, timeout) do
    with {:ok, more} <- recv(socket, timeout),
         do: take_chunk(socket, buffer <> more, size, timeout)
  end

  defp recv(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, _} = ok -> ok
      {:error, :closed} -> {:error, :closed_before_complete}
      {:error, _} = error -> error
    end
  end

  defp chunked?(headers) do
    Enum.any?(headers, fn {k, v} ->
      k == "transfer-encoding" and String.contains?(v, "chunked")
    end)
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, v} -> String.to_integer(v)
      nil -> nil
    end
  end
end

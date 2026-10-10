defmodule Mayfly.Events.HTTP do
  @moduledoc """
  HTTP events from API Gateway (REST v1 and HTTP v2), Lambda Function URLs
  (v2 shape) and Application Load Balancer, plus helpers that build the
  proxy response each of them expects.

      def handle(event, _ctx, _state) do
        req = Mayfly.Events.HTTP.decode(event)

        case {req.method, req.path} do
          {"GET", "/items/" <> id} -> Mayfly.Events.HTTP.json(200, %{id: id}, req)
          {"POST", "/items"} -> Mayfly.Events.HTTP.json(201, %{created: req.body}, req)
          _ -> Mayfly.Events.HTTP.text(404, "not found", req)
        end
      end

  `body` is JSON-decoded when the request `content-type` is JSON (or the body
  parses as JSON), base64-decoded first when `isBase64Encoded` is set;
  otherwise it is the raw binary. `headers` are lowercased; multi-value
  headers (v1/ALB) are joined with `", "`.

  The response helpers take the request (or its `version`) so they can emit
  the right shape: v2/Function URL responses carry `cookies` as a list, v1 and
  ALB carry `multiValueHeaders` when a header has several values.
  """

  alias Mayfly.Events.Util

  defmodule Request do
    @moduledoc "A decoded HTTP request. See `Mayfly.Events.HTTP`."

    @type version :: :v1 | :v2 | :alb

    @type t :: %__MODULE__{
            version: version(),
            method: String.t(),
            path: String.t(),
            raw_path: String.t(),
            query: %{optional(String.t()) => String.t() | [String.t()]},
            headers: %{optional(String.t()) => String.t()},
            cookies: [String.t()],
            body: term(),
            is_base64: boolean(),
            source_ip: String.t() | nil,
            user_agent: String.t() | nil,
            request_id: String.t() | nil,
            stage: String.t() | nil,
            path_parameters: %{optional(String.t()) => String.t()},
            raw: map()
          }

    defstruct version: :v2,
              method: "GET",
              path: "/",
              raw_path: "/",
              query: %{},
              headers: %{},
              cookies: [],
              body: nil,
              is_base64: false,
              source_ip: nil,
              user_agent: nil,
              request_id: nil,
              stage: nil,
              path_parameters: %{},
              raw: %{}
  end

  @doc "Decodes a v1, v2 (incl. Function URL) or ALB event into a `Request`."
  @spec decode(map()) :: Request.t()
  def decode(%{"version" => "2.0", "requestContext" => %{"http" => http} = rc} = e) do
    headers = Util.headers(e["headers"])

    %Request{
      version: :v2,
      method: http["method"] || "GET",
      path: e["rawPath"] || http["path"] || "/",
      raw_path: e["rawPath"] || http["path"] || "/",
      query: e["queryStringParameters"] || %{},
      headers: headers,
      cookies: e["cookies"] || [],
      body: body(e["body"], e["isBase64Encoded"], headers),
      is_base64: e["isBase64Encoded"] == true,
      source_ip: http["sourceIp"],
      user_agent: http["userAgent"] || headers["user-agent"],
      request_id: rc["requestId"],
      stage: rc["stage"],
      path_parameters: e["pathParameters"] || %{},
      raw: e
    }
  end

  def decode(%{"requestContext" => %{"elb" => _}} = e) do
    headers = Util.headers(e["multiValueHeaders"] || e["headers"])

    %Request{
      version: :alb,
      method: e["httpMethod"] || "GET",
      path: e["path"] || "/",
      raw_path: e["path"] || "/",
      query: e["multiValueQueryStringParameters"] || e["queryStringParameters"] || %{},
      headers: headers,
      cookies: cookies_from_header(headers),
      body: body(e["body"], e["isBase64Encoded"], headers),
      is_base64: e["isBase64Encoded"] == true,
      # ALB appends the connecting peer to the client-supplied header: the last
      # entry is the one ALB saw, everything before it is attacker-controlled.
      source_ip: last_forwarded(headers["x-forwarded-for"]),
      user_agent: headers["user-agent"],
      request_id: nil,
      stage: nil,
      path_parameters: %{},
      raw: e
    }
  end

  def decode(%{"httpMethod" => method} = e) do
    rc = e["requestContext"] || %{}
    headers = Util.headers(e["multiValueHeaders"] || e["headers"])

    %Request{
      version: :v1,
      method: method,
      path: e["path"] || "/",
      raw_path: e["path"] || "/",
      query: e["multiValueQueryStringParameters"] || e["queryStringParameters"] || %{},
      headers: headers,
      cookies: cookies_from_header(headers),
      body: body(e["body"], e["isBase64Encoded"], headers),
      is_base64: e["isBase64Encoded"] == true,
      source_ip: get_in(rc, ["identity", "sourceIp"]),
      user_agent: get_in(rc, ["identity", "userAgent"]) || headers["user-agent"],
      request_id: rc["requestId"],
      stage: rc["stage"],
      path_parameters: e["pathParameters"] || %{},
      raw: e
    }
  end

  # -- responses -----------------------------------------------------------------

  @typedoc "A `Request` or just its `version`, used to pick the response shape."
  @type target :: Request.t() | Request.version()

  @doc """
  Builds a proxy response. `body` may be a binary (sent as is) or any other
  term (JSON-encoded, content-type `application/json` unless set).

  Options: `headers:` (map; list values become `multiValueHeaders` on v1/ALB),
  `cookies:` (v2 only), `base64: true` to send a binary body base64-encoded
  with `isBase64Encoded`.
  """
  @spec respond(100..599, term(), target(), keyword()) :: {:ok, map()}
  def respond(status, body, target \\ :v2, opts \\ [])

  # `respond(200, body, headers: ...)` – a keyword list in the target position is the options.
  def respond(status, body, opts, []) when is_list(opts), do: respond(status, body, :v2, opts)

  def respond(status, body, target, opts) do
    version = version(target)
    headers = opts |> Keyword.get(:headers, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    base64? = Keyword.get(opts, :base64, false)

    {body_bin, headers} =
      cond do
        is_binary(body) -> {body, headers}
        true -> {JSON.encode!(body), Map.put_new(headers, "content-type", "application/json")}
      end

    body_out = if base64?, do: Base.encode64(body_bin), else: body_bin
    {single, multi} = split_headers(headers)
    # v2 has no multiValueHeaders: join repeated values as one header (RFC 9110).
    single =
      if version == :v2,
        do: Map.merge(single, Map.new(multi, fn {k, vs} -> {k, Enum.join(vs, ", ")} end)),
        else: single

    response =
      %{statusCode: status, headers: single, body: body_out, isBase64Encoded: base64?}
      |> then(fn r ->
        if version == :v2, do: Map.put(r, :cookies, Keyword.get(opts, :cookies, [])), else: r
      end)
      |> then(fn r ->
        if version != :v2 and multi != %{}, do: Map.put(r, :multiValueHeaders, multi), else: r
      end)
      |> then(fn r ->
        if version == :alb,
          do: Map.put(r, :statusDescription, "#{status} #{reason(status)}"),
          else: r
      end)

    {:ok, response}
  end

  @doc "JSON response."
  @spec json(100..599, term(), target(), keyword()) :: {:ok, map()}
  def json(status, term, target \\ :v2, opts \\ [])
  def json(status, term, opts, []) when is_list(opts), do: json(status, term, :v2, opts)

  def json(status, term, target, opts) do
    headers = opts |> Keyword.get(:headers, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    headers = Map.put_new(headers, "content-type", "application/json; charset=utf-8")
    respond(status, JSON.encode!(term), target, Keyword.put(opts, :headers, headers))
  end

  @doc "Plain text response."
  @spec text(100..599, String.t(), target(), keyword()) :: {:ok, map()}
  def text(status, text, target \\ :v2, opts \\ [])
  def text(status, text, opts, []) when is_list(opts), do: text(status, text, :v2, opts)

  def text(status, text, target, opts) do
    headers = opts |> Keyword.get(:headers, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    headers = Map.put_new(headers, "content-type", "text/plain; charset=utf-8")
    respond(status, text, target, Keyword.put(opts, :headers, headers))
  end

  @doc "Binary response (image, PDF, …), base64-encoded as Lambda requires."
  @spec binary(100..599, binary(), String.t(), target(), keyword()) :: {:ok, map()}
  def binary(status, bytes, content_type, target \\ :v2, opts \\ []) do
    headers = opts |> Keyword.get(:headers, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    headers = Map.put(headers, "content-type", content_type)

    respond(
      status,
      bytes,
      target,
      opts |> Keyword.put(:headers, headers) |> Keyword.put(:base64, true)
    )
  end

  @doc "Redirect (302 by default)."
  @spec redirect(String.t(), target(), keyword()) :: {:ok, map()}
  def redirect(location, target \\ :v2, opts \\ [])
  def redirect(location, opts, []) when is_list(opts), do: redirect(location, :v2, opts)

  def redirect(location, target, opts) do
    status = Keyword.get(opts, :status, 302)
    headers = opts |> Keyword.get(:headers, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    respond(
      status,
      "",
      target,
      opts
      |> Keyword.delete(:status)
      |> Keyword.put(:headers, Map.put(headers, "location", location))
    )
  end

  # -- private ------------------------------------------------------------------

  defp version(%Request{version: v}), do: v
  defp version(v) when v in [:v1, :v2, :alb], do: v

  defp body(nil, _, _), do: nil
  defp body("", _, _), do: nil

  defp body(raw, base64?, headers) do
    decoded = Util.maybe_base64(raw, base64?)
    ct = headers["content-type"] || ""

    if String.contains?(ct, "json") or ct == "" do
      Util.maybe_json(decoded)
    else
      decoded
    end
  end

  defp last_forwarded(nil), do: nil
  defp last_forwarded(xff), do: xff |> String.split(",") |> List.last() |> String.trim()

  defp cookies_from_header(%{"cookie" => cookie}) when is_binary(cookie),
    do: cookie |> String.split(";") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp cookies_from_header(_), do: []

  defp split_headers(headers) do
    Enum.reduce(headers, {%{}, %{}}, fn
      {k, v}, {single, multi} when is_list(v) ->
        {single, Map.put(multi, k, Enum.map(v, &to_string/1))}

      {k, v}, {single, multi} ->
        {Map.put(single, k, to_string(v)), multi}
    end)
  end

  defp reason(200), do: "OK"
  defp reason(201), do: "Created"
  defp reason(204), do: "No Content"
  defp reason(301), do: "Moved Permanently"
  defp reason(302), do: "Found"
  defp reason(400), do: "Bad Request"
  defp reason(401), do: "Unauthorized"
  defp reason(403), do: "Forbidden"
  defp reason(404), do: "Not Found"
  defp reason(500), do: "Internal Server Error"
  defp reason(_), do: ""
end

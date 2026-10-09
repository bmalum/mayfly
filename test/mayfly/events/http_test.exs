defmodule Mayfly.Events.HTTPTest do
  use ExUnit.Case, async: true

  alias Mayfly.Events.HTTP
  alias Mayfly.Events.HTTP.Request

  # AWS sample: API Gateway HTTP API payload 2.0 / Function URL
  @v2 %{
    "version" => "2.0",
    "routeKey" => "$default",
    "rawPath" => "/items/42",
    "rawQueryString" => "a=1&b=2&b=3",
    "cookies" => ["session=abc", "theme=dark"],
    "headers" => %{
      "Content-Type" => "application/json",
      "X-Custom" => "yes",
      "user-agent" => "curl/8"
    },
    "queryStringParameters" => %{"a" => "1", "b" => "2,3"},
    "requestContext" => %{
      "accountId" => "123456789012",
      "requestId" => "id-1",
      "stage" => "$default",
      "http" => %{
        "method" => "POST",
        "path" => "/items/42",
        "protocol" => "HTTP/1.1",
        "sourceIp" => "192.0.2.1",
        "userAgent" => "curl/8"
      }
    },
    "pathParameters" => %{"id" => "42"},
    "body" => "eyJuYW1lIjoid29ybGQifQ==",
    "isBase64Encoded" => true
  }

  # AWS sample: API Gateway REST API proxy (v1)
  @v1 %{
    "resource" => "/{proxy+}",
    "path" => "/path/to/resource",
    "httpMethod" => "POST",
    "isBase64Encoded" => false,
    "queryStringParameters" => %{"foo" => "bar"},
    "multiValueQueryStringParameters" => %{"foo" => ["bar"]},
    "pathParameters" => %{"proxy" => "/path/to/resource"},
    "headers" => %{
      "Accept" => "text/html",
      "Cookie" => "a=1; b=2",
      "User-Agent" => "Custom User Agent String"
    },
    "multiValueHeaders" => %{
      "Accept" => ["text/html", "application/json"],
      "Cookie" => ["a=1; b=2"],
      "User-Agent" => ["Custom User Agent String"]
    },
    "requestContext" => %{
      "requestId" => "c6af9ac6",
      "stage" => "prod",
      "identity" => %{"sourceIp" => "127.0.0.1", "userAgent" => "Custom User Agent String"}
    },
    "body" => "{\"test\":\"body\"}"
  }

  # AWS sample: ALB target
  @alb %{
    "requestContext" => %{"elb" => %{"targetGroupArn" => "arn:aws:elasticloadbalancing:..."}},
    "httpMethod" => "GET",
    "path" => "/lambda",
    "queryStringParameters" => %{"query" => "1234ABCD"},
    "headers" => %{
      "accept" => "text/html",
      "x-forwarded-for" => "72.12.164.125",
      "user-agent" => "Mozilla/5.0"
    },
    "body" => "",
    "isBase64Encoded" => false
  }

  describe "decode/1" do
    test "v2 / Function URL with base64 JSON body" do
      req = HTTP.decode(@v2)

      assert %Request{version: :v2, method: "POST", path: "/items/42", raw_path: "/items/42"} =
               req

      assert req.body == %{"name" => "world"}
      assert req.is_base64

      assert req.headers == %{
               "content-type" => "application/json",
               "x-custom" => "yes",
               "user-agent" => "curl/8"
             }

      assert req.cookies == ["session=abc", "theme=dark"]
      assert req.query == %{"a" => "1", "b" => "2,3"}
      assert req.path_parameters == %{"id" => "42"}
      assert req.source_ip == "192.0.2.1"
      assert req.user_agent == "curl/8"
      assert req.request_id == "id-1"
      assert req.stage == "$default"
      assert req.raw == @v2
    end

    test "v1 REST proxy with multi-value headers and cookie header" do
      req = HTTP.decode(@v1)

      assert %Request{version: :v1, method: "POST", path: "/path/to/resource"} = req
      assert req.body == %{"test" => "body"}
      assert req.headers["accept"] == "text/html, application/json"
      assert req.cookies == ["a=1", "b=2"]
      assert req.query == %{"foo" => ["bar"]}
      assert req.source_ip == "127.0.0.1"
      assert req.user_agent == "Custom User Agent String"
      assert req.stage == "prod"
      assert req.path_parameters == %{"proxy" => "/path/to/resource"}
    end

    test "ALB" do
      req = HTTP.decode(@alb)
      assert %Request{version: :alb, method: "GET", path: "/lambda", body: nil} = req
      assert req.source_ip == "72.12.164.125"
      assert req.query == %{"query" => "1234ABCD"}
    end

    test "non-JSON content type keeps the body as a binary" do
      e =
        put_in(@v2, ["headers", "Content-Type"], "text/plain")
        |> Map.put("body", "hello")
        |> Map.put("isBase64Encoded", false)

      assert %Request{body: "hello"} = HTTP.decode(e)
    end

    test "invalid JSON with a JSON content type stays a binary" do
      e = @v2 |> Map.put("body", "{nope") |> Map.put("isBase64Encoded", false)
      assert %Request{body: "{nope"} = HTTP.decode(e)
    end

    test "empty body is nil" do
      assert %Request{body: nil} = HTTP.decode(Map.put(@alb, "body", ""))
      assert %Request{body: nil} = HTTP.decode(Map.delete(@v2, "body"))
    end
  end

  describe "responses" do
    test "json/4 for v2 includes cookies and content-type" do
      {:ok, r} =
        HTTP.json(201, %{ok: true}, HTTP.decode(@v2), cookies: ["a=b"], headers: %{"x-id" => 7})

      assert r == %{
               statusCode: 201,
               headers: %{"content-type" => "application/json; charset=utf-8", "x-id" => "7"},
               cookies: ["a=b"],
               body: ~s({"ok":true}),
               isBase64Encoded: false
             }
    end

    test "respond/4 on v1 splits list headers into multiValueHeaders and never emits cookies" do
      {:ok, r} =
        HTTP.respond(200, "ok", :v1, headers: %{"set-cookie" => ["a=1", "b=2"], "x-one" => "1"})

      assert r.headers == %{"x-one" => "1"}
      assert r.multiValueHeaders == %{"set-cookie" => ["a=1", "b=2"]}
      refute Map.has_key?(r, :cookies)
      assert r.body == "ok"
    end

    test "ALB responses carry statusDescription" do
      {:ok, r} = HTTP.text(404, "nope", :alb)
      assert r.statusDescription == "404 Not Found"
      assert r.headers["content-type"] =~ "text/plain"
    end

    test "non-binary body is JSON encoded with a default content type" do
      {:ok, r} = HTTP.respond(200, %{a: [1, 2]}, :v2)
      assert r.body == ~s({"a":[1,2]})
      assert r.headers["content-type"] == "application/json"
    end

    test "binary/5 base64-encodes and round-trips" do
      bytes = <<137, 80, 78, 71, 0, 255>>
      {:ok, r} = HTTP.binary(200, bytes, "image/png")
      assert r.isBase64Encoded
      assert Base.decode64!(r.body) == bytes
      assert r.headers["content-type"] == "image/png"
    end

    test "redirect/3" do
      {:ok, r} = HTTP.redirect("https://example.com/", :v2, status: 301)
      assert %{statusCode: 301, headers: %{"location" => "https://example.com/"}, body: ""} = r
    end

    test "responses are JSON encodable" do
      {:ok, r} = HTTP.json(200, %{x: 1}, :v2, cookies: ["c=d"])
      assert is_binary(JSON.encode!(r))
    end
  end
end

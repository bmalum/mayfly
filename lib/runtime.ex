defmodule AWSLambda.Runtime do
  def service_endpoint do
    System.get_env("AWS_LAMBDA_RUNTIME_API") <> "/2018-06-01"
  end

  def next_invocation do
    :httpc.request(~c"http://#{service_endpoint()}/runtime/invocation/next")
  end

  def invocation_response(aws_req_id, response) do
    :httpc.request(
      :post,
      {~c"http://#{service_endpoint()}/runtime/invocation/#{aws_req_id}/response", [],
       ~c"application/json", Jason.encode!(response)},
      [],
      []
    )
  end

  def init_error(error) do
    :httpc.request(
      :post,
      {~c"http://#{service_endpoint()}/runtime/init/error", [], ~c"application/json",
       Jason.encode!(error)},
      [],
      []
    )
  end

  def invocation_error(aws_req_id, error) do
    :httpc.request(
      :post,
      {~c"http://#{service_endpoint()}/runtime/invocation/#{aws_req_id}/error", [],
       ~c"application/json", Jason.encode!(error)},
      [],
      []
    )
  end
end

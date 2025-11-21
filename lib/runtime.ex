defmodule Mayfly.Runtime do
  @moduledoc """
  Handles communication with the AWS Lambda Runtime API.
  Provides functions for fetching invocations and sending responses.
  """

  require Logger

  @doc """
  Returns the base service endpoint for the Lambda Runtime API.
  """
  @spec service_endpoint() :: String.t()
  def service_endpoint do
    System.get_env("AWS_LAMBDA_RUNTIME_API") <> "/2018-06-01"
  end

  @doc """
  Fetches the next invocation from the Lambda Runtime API.
  Returns {:ok, {protocol, headers, body}} on success or {:error, reason} on failure.
  """
  @spec next_invocation() :: {:ok, {atom(), list(), binary()}} | {:error, any()}
  def next_invocation do
    Logger.debug("Fetching next invocation")

    try do
      :httpc.request(~c"http://#{service_endpoint()}/runtime/invocation/next")
    rescue
      e ->
        Logger.error("Failed to fetch next invocation: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Sends a successful response for a Lambda invocation.
  """
  @spec invocation_response(binary(), any()) :: {:ok, any()} | {:error, any()}
  def invocation_response(aws_req_id, response) do
    Logger.debug("Sending successful response for request #{aws_req_id}")

    try do
      :httpc.request(
        :post,
        {~c"http://#{service_endpoint()}/runtime/invocation/#{aws_req_id}/response",
         [], ~c"application/json", Jason.encode!(response)},
        [{:timeout, 5000}],
        []
      )
    rescue
      e ->
        Logger.error("Failed to send invocation response: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Sends an initialization error to the Lambda Runtime API.
  """
  @spec init_error(map()) :: {:ok, any()} | {:error, any()}
  def init_error(error) do
    Logger.error("Reporting initialization error: #{inspect(error)}")

    try do
      :httpc.request(
        :post,
        {~c"http://#{service_endpoint()}/runtime/init/error",
         [], ~c"application/json", Jason.encode!(error)},
        [{:timeout, 5000}],
        []
      )
    rescue
      e ->
        Logger.error("Failed to send init error: #{inspect(e)}")
        {:error, e}
    end
  end

  @doc """
  Sends an invocation error to the Lambda Runtime API.
  """
  @spec invocation_error(binary(), map()) :: {:ok, any()} | {:error, any()}
  def invocation_error(aws_req_id, error) do
    Logger.error("Reporting invocation error for request #{aws_req_id}: #{inspect(error)}")

    try do
      :httpc.request(
        :post,
        {~c"http://#{service_endpoint()}/runtime/invocation/#{aws_req_id}/error",
         [], ~c"application/json", Jason.encode!(error)},
        [{:timeout, 5000}],
        []
      )
    rescue
      e ->
        Logger.error("Failed to send invocation error: #{inspect(e)}")
        {:error, e}
    end
  end
end

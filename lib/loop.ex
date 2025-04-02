defmodule AWSLambda.Loop do
  @moduledoc """
  GenServer that handles the AWS Lambda event loop.
  Continuously polls for new invocations and processes them.
  """

  use GenServer
  alias AWSLambda.{Runtime, Handler, Error}
  require Logger

  @doc """
  Starts the Lambda event loop GenServer.
  """
  def start_link(state) do
    Logger.info("Starting AWS Lambda event loop")
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @doc """
  Initializes the GenServer and triggers the first loop iteration.
  """
  def init(state) do
    Logger.debug("Initializing Lambda event loop")
    send(self(), :loop)
    {:ok, state}
  end

  @doc """
  Handles the main event loop for processing Lambda invocations.
  """
  def handle_info(:loop, state) do
    # Schedule the next iteration immediately
    send(self(), :loop)

    # Get the next invocation
    case Runtime.next_invocation() do
      {:ok, {_protocol, headers, body}} ->
        process_invocation(headers, body)
      {:error, reason} ->
        Logger.error("Failed to get next invocation: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Private function to process an invocation
  defp process_invocation(headers, body) do
    req_id = AWSLambda.Helpers.get_request_id(headers)
    handler = Handler.resolve()

    Logger.debug("Processing invocation #{req_id} with handler #{inspect(handler)}")

    payload =
      try do
        Jason.decode!(body)
      rescue
        e ->
          Logger.error("Failed to decode request body: #{inspect(e)}")
          Runtime.invocation_error(req_id, Error.format_error(e, __STACKTRACE__))
          %{}
      end

    case Handler.execute(payload, handler) do
      {:ok, result} -> Runtime.invocation_response(req_id, result)
      {:error, error} -> Runtime.invocation_error(req_id, error)
    end
  end
end

defmodule AWSLambda.Helpers do
  @moduledoc """
  Helper functions for AWS Lambda runtime.
  """

  @doc """
  Extracts the request ID from Lambda invocation headers.
  """
  @spec get_request_id(list()) :: binary()
  def get_request_id(headers) do
    headers |> Enum.into(%{}) |> Map.get(~c"lambda-runtime-aws-request-id")
  end
end

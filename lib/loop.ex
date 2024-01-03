defmodule AWSLambda.Loop do
  use GenServer
  alias AWSLambda.Runtime
  import AWSLambda.Runtime

  def start_link(state) do
    IO.puts("GenServer Started")
    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  def init(map) do
    send(self(), :loop)
    {:ok, map}
  end

  def handle_info(:loop, state) do
    send(self(), :loop)

    {:ok, {protocol, headers, body}} =
      Runtime.next_invocation()

    req_id = AWSLambda.Helpers.get_request_id(headers)

    Runtime.invocation_response(req_id, "Response")
    {:noreply, state}
  end
end

defmodule AWSLambda.Helpers do
  def get_request_id(headers) do
    headers |> Enum.into(%{}) |> Map.get(~c"lambda-runtime-aws-request-id")
  end
end

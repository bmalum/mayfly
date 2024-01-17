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
    {module, function} = get_handler()

    try do
      case Kernel.apply(module, function, [Jason.decode!(body)]) do
        {:error, error} -> Runtime.invocation_error(req_id, convert_error(error))
        {:ok, result} -> Runtime.invocation_response(req_id, result)
      end
    rescue 
      e in UndefinedFunctionError -> Runtime.invocation_error(req_id, convert_error(e, __STACKTRACE__)) 
      e in RuntimeError -> Runtime.invocation_error(req_id, convert_error(e, __STACKTRACE__))
      e -> Runtime.invocation_error(req_id, convert_error(e, __STACKTRACE__))
    end

    {:noreply, state}
  end

  def convert_error(error, stackTrace \\ nil) do
    %{
      errorMessage: Map.get(error, :message, "no message provided"),
      errorType: Map.get(error, :__struct__),
      stackTrace: Exception.format_stacktrace(stackTrace) 
    }
  end

  def dummy(payload) do
    {:ok, "Please provide a _HANDLE Enviroment Variable containing the Function you would like to call prefixed with Elixir."}
  end

  def dummy_error(payload) do
    {:error, "Error"}
  end


  def dummy_raise_error(payload) do
    raise(RuntimeError, "some error happened")
  end

  def dummy_success(payload) do
    {:ok, "Success"}
  end


  def get_handler() do
    handler = System.get_env("_HANDLER") || "Elixir.AWSLambda.dummy"
      handler_split_list = handler |> String.split(".", trim: true)
      function = handler_split_list  |> List.last() |> String.to_atom()
      module = List.delete_at(handler_split_list, length(handler_split_list)-1) |> Enum.join(".") |> String.to_atom()
      {module, function}
  end

end

defmodule AWSLambda.Helpers do
  def get_request_id(headers) do
    headers |> Enum.into(%{}) |> Map.get(~c"lambda-runtime-aws-request-id")
  end
end

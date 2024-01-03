defmodule AWSLambda do
  use Application

  @moduledoc """
  Documentation for `AWSLambda`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> AWSLambda.hello()
      :world

  """

  def start(_type, _args) do
    AWSLambda.Supervisor.start_link()
  end
end

defmodule AWSLambda.Supervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    children = [
      %{id: AWSLambda.Loop, start: {AWSLambda.Loop, :start_link, [[]]}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

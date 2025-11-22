defmodule Mayfly do
  @moduledoc """
  Mayfly - AWS Lambda Custom Runtime for Elixir.

  This module serves as the main application entry point for the Elixir Lambda runtime.
  It starts the supervision tree and initializes the Lambda event loop.
  """
  use Application

  @doc """
  Starts the Mayfly application.

  This function is called automatically by the Elixir runtime when the application starts.
  It initializes the supervision tree and starts the Lambda event loop.
  """
  @spec start(any(), any()) :: {:ok, pid()} | {:error, any()}
  def start(_type, _args) do
    Mayfly.Supervisor.start_link()
  end

  @doc """
  Default handler function that can be used for testing.

  ## Examples

      iex> Mayfly.hello()
      :world

  """
  def hello, do: :world
end

defmodule Mayfly.Supervisor do
  @moduledoc """
  Supervisor for the Mayfly application.

  This module defines the supervision tree for the Lambda runtime,
  managing the lifecycle of the Lambda event loop.
  """
  use Supervisor

  @doc """
  Starts the supervisor.
  """
  @spec start_link() :: {:ok, pid()} | {:error, any()}
  def start_link do
    Supervisor.start_link(__MODULE__, :ok)
  end

  @doc """
  Initializes the supervisor with the Lambda event loop as its child.
  """
  @spec init(:ok) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(:ok) do
    children = [
      %{id: Mayfly.Loop, start: {Mayfly.Loop, :start_link, [[]]}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

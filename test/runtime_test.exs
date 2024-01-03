defmodule AWSLambdaTest.Runtime do
  defmodule :httpc do
    def request(_url) do
      :payload
    end
  end

  use ExUnit.Case
  doctest AWSLambda.Runtime

  test "does http request" do
    assert AWSLambda.Runtime.next_invocation() == :payload
  end
end

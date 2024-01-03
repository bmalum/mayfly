defmodule AWSLambdaTest do
  use ExUnit.Case
  doctest AWSLambda

  test "greets the world" do
    assert AWSLambda.hello() == :world
  end
end

defmodule MayflyTest do
  use ExUnit.Case
  doctest Mayfly

  test "greets the world" do
    assert Mayfly.hello() == :world
  end
end

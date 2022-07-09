defmodule Defdo.DDNSTest do
  use ExUnit.Case
  doctest Defdo.DDNS

  test "greets the world" do
    assert Defdo.DDNS.hello() == :world
  end
end

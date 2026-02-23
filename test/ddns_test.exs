defmodule Defdo.DDNSTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.DDNS

  test "get config dns records to be monitored" do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"example.com" => ["home"]})
    assert DDNS.records_to_monitor("example.com") == ["example.com", "home.example.com"]
  end

  test "get the cloudflare application key" do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"example.com" => ["home"]})
    assert DDNS.get_cloudflare_key(:domain_mappings) == %{"example.com" => ["home"]}
  end
end

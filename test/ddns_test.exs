defmodule Defdo.DDNSTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.DDNS

  test "get config dns records to be monitored" do
    Application.put_env(:defdo_ddns, Cloudflare, domain: "defdo.de", subdomains: "h,h.defdo.de h")
    assert DDNS.monitoring_records() == ["defdo.de", "h.defdo.de"]
  end

  test "get the cloudflare application key" do
    Application.put_env(:defdo_ddns, Cloudflare, domain: "defdo.de", subdomains: "h,h.defdo.de h")
    assert DDNS.get_cloudflare_key(:domain) == "defdo.de"
  end
end

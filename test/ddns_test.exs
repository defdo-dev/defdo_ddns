defmodule Defdo.DDNSTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.DDNS

  test "get config dns records to be monitored" do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"defdo.de" => ["h"]})
    assert DDNS.records_to_monitor("defdo.de") == ["defdo.de", "h.defdo.de"]
  end

  test "get the cloudflare application key" do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"defdo.de" => ["h"]})
    assert DDNS.get_cloudflare_key(:domain_mappings) == %{"defdo.de" => ["h"]}
  end
end

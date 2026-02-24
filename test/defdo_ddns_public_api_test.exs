defmodule Defdo.DDNSPublicAPITest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.DDNS

  defmodule FakeDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: _name), do: []
    def create_dns_record("zone_123", record), do: {true, Map.put(record, "id", "record_1")}

    def input_for_update_cname_records(_records, _desired_record), do: []
    def apply_update(_zone_id, _input), do: {true, %{"id" => "record_1"}}
  end

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_api_config = Application.get_env(:defdo_ddns, Defdo.DDNS.API)
    previous_monitor_enabled = Application.get_env(:defdo_ddns, :monitor_enabled)

    on_exit(fn ->
      restore_env(:defdo_ddns, Cloudflare, previous_cloudflare)
      restore_env(:defdo_ddns, Defdo.DDNS.API, previous_api_config)
      restore_env(:defdo_ddns, :monitor_enabled, previous_monitor_enabled)
    end)

    :ok
  end

  test "monitor_enabled?/0 reflects config flag" do
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    refute DDNS.monitor_enabled?()

    Application.put_env(:defdo_ddns, :monitor_enabled, true)
    assert DDNS.monitor_enabled?()
  end

  test "configured_domains/0 aggregates A and AAAA domain mappings" do
    domain_a = random_domain()
    domain_aaaa = random_domain()

    Application.put_env(:defdo_ddns, Cloudflare,
      domain_mappings: %{domain_a => ["www"]},
      aaaa_domain_mappings: %{domain_aaaa => ["api"]}
    )

    assert DDNS.configured_domains() |> Enum.sort() == Enum.sort([domain_a, domain_aaaa])
  end

  test "checkup/0 falls back to one-shot mode when monitor is not running" do
    if Process.whereis(Defdo.Cloudflare.Monitor) do
      DDNS.stop_monitor()
    end

    Application.put_env(:defdo_ddns, Cloudflare,
      domain_mappings: %{},
      aaaa_domain_mappings: %{}
    )

    assert DDNS.checkup() == []
  end

  test "upsert_free_domain/1 delegates to internal DNS API module" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:ok, %{action: "created", record: record}} =
             DDNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain
             })

    assert record["name"] == fqdn
    assert record["content"] == base_domain
    assert record["ttl"] == 1
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp random_domain do
    "zone-#{System.unique_integer([:positive])}.example.test"
  end
end

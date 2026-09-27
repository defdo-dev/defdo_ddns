defmodule Defdo.DDNS.APIHostnameTest do
  @moduledoc """
  The upsert API rejects names that are not valid hostnames before touching
  Cloudflare or desired state. Found on the production NAS: `--help.defdo.ninja`
  had been declared into desired state by a CLI invoked with `--help`.
  """
  use ExUnit.Case, async: false

  alias Defdo.DDNS.API.DNS

  defmodule FakeDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_1"
    def list_dns_records("zone_1", name: _name), do: []

    def create_dns_record("zone_1", record) do
      send(self(), {:created, record["name"]})
      {true, Map.put(record, "id", "r1")}
    end

    def input_for_update_cname_records(_records, _desired), do: []
    def apply_update(_zone, _input), do: {true, %{}}
  end

  setup do
    previous_api = Application.get_env(:defdo_ddns, Defdo.DDNS.API)
    previous_store = Application.get_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)

    Application.put_env(:defdo_ddns, Defdo.DDNS.API, ddns_module: FakeDDNS)
    Application.delete_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)

    on_exit(fn ->
      restore(Defdo.DDNS.API, previous_api)
      restore(Defdo.DDNS.DesiredStateStore, previous_store)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp upsert(fqdn, base \\ "defdo.ninja"),
    do: DNS.upsert_free_domain(%{"fqdn" => fqdn, "base_domain" => base})

  test "the production case is rejected and nothing is created" do
    assert {:error, {:validation, %{"fqdn" => "is not a valid hostname"}}} =
             upsert("--help.defdo.ninja")

    refute_received {:created, _}
  end

  for bad <- [
        "-app.defdo.ninja",
        "app-.defdo.ninja",
        "a..defdo.ninja",
        "app name.defdo.ninja",
        "app!.defdo.ninja",
        "sub.*.defdo.ninja"
      ] do
    test "rejects #{inspect(bad)}" do
      assert {:error, {:validation, %{"fqdn" => _}}} = upsert(unquote(bad))
    end
  end

  test "rejects a label longer than 63 characters" do
    assert {:error, {:validation, _}} = upsert(String.duplicate("a", 64) <> ".defdo.ninja")
  end

  test "rejects an invalid base_domain" do
    assert {:error, {:validation, %{"base_domain" => _}}} =
             upsert("app.defdo.ninja", "-bad.ninja")
  end

  for good <- [
        "app.defdo.ninja",
        "acme-idp.defdo.ninja",
        "_acme-challenge.defdo.ninja",
        "*.dev.defdo.ninja",
        "a1.b2.defdo.ninja",
        "defdo.ninja"
      ] do
    test "accepts #{inspect(good)}" do
      assert {:ok, %{action: "created"}} = upsert(unquote(good))
    end
  end
end

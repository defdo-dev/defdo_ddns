defmodule Defdo.DDNS.APIDeclaresTest do
  @moduledoc """
  A record the provisioning API creates must be declared as managed in the same
  call.

  Before this, `POST /v1/dns/upsert` wrote to Cloudflare and stopped there. The
  monitor never knew the record existed, so the next inventory reported it as
  unmanaged and an operator had to *adopt* a record the platform itself had just
  created. The API was manufacturing exactly the drift adoption exists to clean
  up, and it did so once per provisioned tenant.

  Adoption is for records someone else made. Ours are managed from birth.
  """
  use ExUnit.Case, async: false

  alias Defdo.DDNS.API.DNS
  alias Defdo.DDNS.DesiredStateStore

  defmodule FakeDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: _name), do: []

    def create_dns_record("zone_123", record),
      do: {true, Map.merge(record, %{"id" => "record_1"})}

    def input_for_update_cname_records(_records, _desired), do: []
    def apply_update(_zone_id, _input), do: {true, %{"id" => "record_1"}}
  end

  defmodule FakeExactDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: name) do
      base_domain = String.replace_prefix(name, "acme-idp.", "")

      [
        %{
          "id" => "record_1",
          "type" => "CNAME",
          "name" => name,
          "content" => base_domain,
          "proxied" => true,
          "ttl" => 1
        }
      ]
    end

    def create_dns_record(_zone_id, _record), do: {false, nil}
    def input_for_update_cname_records(_records, _desired), do: []
    def apply_update(_zone_id, _input), do: raise("exact record must not be updated")
  end

  setup do
    previous_api = Application.get_env(:defdo_ddns, Defdo.DDNS.API)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)

    dir = Path.join(System.tmp_dir!(), "ddns-declare-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "desired_state.json")

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeDDNS,
      default_target: "@",
      default_proxied: true
    )

    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    on_exit(fn ->
      File.rm_rf(dir)
      restore(Defdo.DDNS.API, previous_api)
      restore(DesiredStateStore, previous_store)
    end)

    {:ok, state_path: file}
  end

  test "a provisioned record is declared in desired state" do
    base_domain = "defdo-test-#{System.unique_integer([:positive])}.dev"
    fqdn = "acme-idp.#{base_domain}"

    assert {:ok, %{action: "created", declared: true}} =
             DNS.upsert_free_domain(%{"fqdn" => fqdn, "base_domain" => base_domain})

    assert {:ok, doc} = DesiredStateStore.load()
    declared = get_in(doc, ["cloudflare", "cname_records"])

    assert Enum.any?(declared, fn entry ->
             entry["name"] == fqdn and entry["domain"] == base_domain and
               entry["target"] == base_domain
           end)
  end

  test "declaring the same record twice does not duplicate it" do
    base_domain = "defdo-test-#{System.unique_integer([:positive])}.dev"
    fqdn = "acme-idp.#{base_domain}"
    params = %{"fqdn" => fqdn, "base_domain" => base_domain}

    assert {:ok, %{declared: true}} = DNS.upsert_free_domain(params)
    assert {:ok, %{declared: true}} = DNS.upsert_free_domain(params)

    {:ok, doc} = DesiredStateStore.load()

    matching =
      doc
      |> get_in(["cloudflare", "cname_records"])
      |> Enum.count(&(&1["name"] == fqdn))

    assert matching == 1
  end

  test "an exact existing record is declared without mutation when updates are disabled" do
    base_domain = "defdo-test-#{System.unique_integer([:positive])}.dev"
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeExactDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:ok, %{action: "noop", declared: true}} =
             DNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain,
               "update_existing" => false
             })

    assert {:ok, doc} = DesiredStateStore.load()

    assert Enum.any?(get_in(doc, ["cloudflare", "cname_records"]), fn entry ->
             entry["name"] == fqdn and entry["target"] == base_domain
           end)
  end

  test "the declared entry carries the identity inventory matches on" do
    base_domain = "defdo-test-#{System.unique_integer([:positive])}.dev"
    fqdn = "ACME-IDP.#{base_domain}"

    assert {:ok, %{declared: true}} =
             DNS.upsert_free_domain(%{"fqdn" => fqdn, "base_domain" => base_domain})

    # Inventory keys a record on {type, name}, lowercased. If a declaration
    # stored the name as given, a record provisioned with mixed case would fail
    # to match itself on the next reconcile and reappear as drift — which is the
    # exact failure this whole change exists to prevent.
    #
    # This asserts the identity is storable and normalised. Running Inventory
    # end to end needs a Cloudflare double it has no seam for today; that gap is
    # real and is not covered here.
    {:ok, doc} = DesiredStateStore.load()
    entry = doc |> get_in(["cloudflare", "cname_records"]) |> List.first()

    assert entry["name"] == String.downcase(fqdn)
    assert entry["domain"] == base_domain
  end

  test "provisioning still succeeds when no desired-state file is configured" do
    Application.delete_env(:defdo_ddns, DesiredStateStore)
    base_domain = "defdo-test-#{System.unique_integer([:positive])}.dev"

    # A deployment without the file is a supported configuration: the record is
    # created and simply not recorded. Reporting failure here would call a
    # successful DNS write a failure.
    assert {:ok, %{action: "created", declared: false}} =
             DNS.upsert_free_domain(%{
               "fqdn" => "acme-idp.#{base_domain}",
               "base_domain" => base_domain
             })
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)
end

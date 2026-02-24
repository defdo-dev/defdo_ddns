defmodule Defdo.DDNS.APITest do
  @moduledoc false
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias Defdo.DDNS.API.DNS
  alias Defdo.DDNS.API.Router

  defmodule FakeCreateDDNS do
    def get_zone_id("defdo.in"), do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: _name), do: []

    def create_dns_record("zone_123", record) do
      {true, Map.merge(record, %{"id" => "record_1"})}
    end

    def input_for_update_cname_records(_records, _desired_record), do: []
    def apply_update(_zone_id, _input), do: {true, %{"id" => "record_1"}}
  end

  defmodule FakeConflictDDNS do
    def get_zone_id("defdo.in"), do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: name) do
      [%{"id" => "a_1", "name" => name, "type" => "A", "content" => "203.0.113.10"}]
    end

    def create_dns_record(_zone_id, _record), do: {false, nil}
    def input_for_update_cname_records(_records, _desired_record), do: []
    def apply_update(_zone_id, _input), do: {false, nil}
  end

  setup do
    previous_api_config = Application.get_env(:defdo_ddns, Defdo.DDNS.API)

    on_exit(fn ->
      if is_nil(previous_api_config) do
        Application.delete_env(:defdo_ddns, Defdo.DDNS.API)
      else
        Application.put_env(:defdo_ddns, Defdo.DDNS.API, previous_api_config)
      end
    end)

    :ok
  end

  test "DNS.upsert_free_domain/1 creates CNAME record when missing" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:ok, %{action: "created", record: record}} =
             DNS.upsert_free_domain(%{
               "fqdn" => "acme-idp.defdo.in",
               "base_domain" => "defdo.in"
             })

    assert record["name"] == "acme-idp.defdo.in"
    assert record["content"] == "defdo.in"
    assert record["type"] == "CNAME"
    assert record["ttl"] == 1
  end

  test "DNS.upsert_free_domain/1 returns conflict when non-CNAME record exists" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeConflictDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:error, {:conflict, %{types: ["A"]}}} =
             DNS.upsert_free_domain(%{
               "fqdn" => "acme-idp.defdo.in",
               "base_domain" => "defdo.in"
             })
  end

  test "DNS.upsert_free_domain/1 validates fqdn zone" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API, ddns_module: FakeCreateDDNS)

    assert {:error, {:validation, %{"fqdn" => "must belong to base_domain"}}} =
             DNS.upsert_free_domain(%{
               "fqdn" => "acme-idp.other.in",
               "base_domain" => "defdo.in"
             })
  end

  test "router denies unauthorized calls when token configured" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "secret",
      ddns_module: FakeCreateDDNS
    )

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "router upsert returns success payload" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "secret",
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    payload = %{"fqdn" => "acme-idp.defdo.in", "base_domain" => "defdo.in"}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> Router.call([])

    assert conn.status == 200

    assert %{"status" => "ok", "result" => %{"action" => "created"}} =
             Jason.decode!(conn.resp_body)
  end

  test "router health endpoint works" do
    conn =
      conn(:get, "/health")
      |> Router.call([])

    assert conn.status == 200
    assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
  end
end

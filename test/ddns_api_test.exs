defmodule Defdo.DDNS.APITest do
  @moduledoc false
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias Defdo.DDNS.API.DNS
  alias Defdo.DDNS.API.Router

  defmodule FakeCreateDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_123"
    def get_zone_id(_), do: nil

    def list_dns_records("zone_123", name: _name), do: []

    def create_dns_record("zone_123", record) do
      {true, Map.merge(record, %{"id" => "record_1"})}
    end

    def input_for_update_cname_records(_records, _desired_record), do: []
    def apply_update(_zone_id, _input), do: {true, %{"id" => "record_1"}}
  end

  defmodule FakeConflictDDNS do
    def get_zone_id(zone) when is_binary(zone) and zone != "", do: "zone_123"
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
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:ok, %{action: "created", record: record}} =
             DNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain
             })

    assert record["name"] == fqdn
    assert record["content"] == base_domain
    assert record["type"] == "CNAME"
    assert record["ttl"] == 1
  end

  test "DNS.upsert_free_domain/1 returns conflict when non-CNAME record exists" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeConflictDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:error, {:conflict, %{types: ["A"]}}} =
             DNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain
             })
  end

  test "DNS.upsert_free_domain/1 preserves explicit proxied=false" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    assert {:ok, %{action: "created", record: record}} =
             DNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain,
               "proxied" => false
             })

    assert record["proxied"] == false
    assert record["ttl"] == 300
  end

  test "DNS.upsert_free_domain/1 validates fqdn zone" do
    base_domain = random_domain()
    other_domain = random_domain()
    fqdn = "acme-idp.#{other_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API, ddns_module: FakeCreateDDNS)

    assert {:error, {:validation, %{"fqdn" => "must belong to base_domain"}}} =
             DNS.upsert_free_domain(%{
               "fqdn" => fqdn,
               "base_domain" => base_domain
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
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "secret",
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> Router.call([])

    assert conn.status == 200

    assert %{"status" => "ok", "result" => %{"action" => "created"}} =
             Jason.decode!(conn.resp_body)
  end

  test "router accepts x-api-token header" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "secret",
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-token", "secret")
      |> Router.call([])

    assert conn.status == 200

    assert %{"status" => "ok", "result" => %{"action" => "created"}} =
             Jason.decode!(conn.resp_body)
  end

  test "router authorizes client mode with x-client-id and token" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      clients: [
        %{
          "id" => "tenant-a",
          "token" => "tenant-secret",
          "allowed_base_domains" => [base_domain]
        }
      ],
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-client-id", "tenant-a")
      |> put_req_header("x-api-token", "tenant-secret")
      |> Router.call([])

    assert conn.status == 200

    assert %{"status" => "ok", "result" => %{"action" => "created"}} =
             Jason.decode!(conn.resp_body)
  end

  test "router allows global token fallback when clients are configured and x-client-id is missing" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "global-secret",
      clients: [
        %{
          "id" => "tenant-a",
          "token" => "tenant-secret",
          "allowed_base_domains" => [base_domain]
        }
      ],
      ddns_module: FakeCreateDDNS,
      default_target: "@",
      default_proxied: true
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer global-secret")
      |> Router.call([])

    assert conn.status == 200

    assert %{"status" => "ok", "result" => %{"action" => "created"}} =
             Jason.decode!(conn.resp_body)
  end

  test "router does not use global fallback when x-client-id is present and invalid" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "global-secret",
      clients: [
        %{
          "id" => "tenant-a",
          "token" => "tenant-secret",
          "allowed_base_domains" => [base_domain]
        }
      ],
      ddns_module: FakeCreateDDNS
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-client-id", "tenant-b")
      |> put_req_header("authorization", "Bearer global-secret")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "router rejects client mode request without x-client-id" do
    base_domain = random_domain()
    fqdn = "acme-idp.#{base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      clients: [
        %{
          "id" => "tenant-a",
          "token" => "tenant-secret",
          "allowed_base_domains" => [base_domain]
        }
      ],
      ddns_module: FakeCreateDDNS
    )

    payload = %{"fqdn" => fqdn, "base_domain" => base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-api-token", "tenant-secret")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "router rejects base_domain outside allowed client scope" do
    allowed_base_domain = random_domain()
    denied_base_domain = random_domain()
    fqdn = "acme-idp.#{denied_base_domain}"

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      clients: [
        %{
          "id" => "tenant-a",
          "token" => "tenant-secret",
          "allowed_base_domains" => [allowed_base_domain]
        }
      ],
      ddns_module: FakeCreateDDNS
    )

    payload = %{"fqdn" => fqdn, "base_domain" => denied_base_domain}

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-client-id", "tenant-a")
      |> put_req_header("x-api-token", "tenant-secret")
      |> Router.call([])

    assert conn.status == 422

    assert %{"error" => "validation_failed", "details" => %{"base_domain" => _}} =
             Jason.decode!(conn.resp_body)
  end

  test "router denies upsert when token is not configured" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API, ddns_module: FakeCreateDDNS)

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "router denies upsert when token is blank" do
    Application.put_env(:defdo_ddns, Defdo.DDNS.API, token: "   ", ddns_module: FakeCreateDDNS)

    conn =
      conn(:post, "/v1/dns/upsert", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "router health endpoint works" do
    conn =
      conn(:get, "/health")
      |> Router.call([])

    assert conn.status == 200
    assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
  end

  defp random_domain do
    "zone-#{System.unique_integer([:positive])}.example.test"
  end

  describe "adoption endpoints" do
    setup do
      previous_adoption = Application.get_env(:defdo_ddns, Defdo.DDNS.Adoption)
      previous_desired = Application.get_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)

      seed = System.unique_integer([:positive])
      adoption = Path.join(System.tmp_dir!(), "api-adoption-#{seed}.json")
      desired = Path.join(System.tmp_dir!(), "api-desired-#{seed}.json")

      Application.put_env(:defdo_ddns, Defdo.DDNS.API, token: "secret")
      Application.put_env(:defdo_ddns, Defdo.DDNS.Adoption, path: adoption)
      Application.put_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore, path: desired)

      # A pending entry to decide on, written straight to the file — the API is
      # the subject here, not discovery.
      entry = %{
        "cname:foss.defdo.ninja" => %{
          "id" => "cname:foss.defdo.ninja",
          "record" => %{
            "type" => "CNAME",
            "name" => "foss.defdo.ninja",
            "content" => "defdo.ninja",
            "proxied" => true,
            "ttl" => 1
          },
          "state" => "pending",
          "first_seen" => "2026-07-24T00:00:00Z",
          "decided_at" => nil,
          "decided_by" => nil,
          "note" => nil
        }
      }

      File.write!(adoption, Jason.encode!(%{"entries" => entry}))

      File.write!(
        desired,
        Jason.encode!(%{"version" => 1, "cloudflare" => %{"cname_records" => []}})
      )

      on_exit(fn ->
        File.rm(adoption)
        File.rm(desired)
        restore(Defdo.DDNS.Adoption, previous_adoption)
        restore(Defdo.DDNS.DesiredStateStore, previous_desired)
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
    defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

    defp call(method, path, body \\ nil) do
      conn = conn(method, path, body && Jason.encode!(body))
      conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

      conn
      |> put_req_header("authorization", "Bearer secret")
      |> Router.call([])
    end

    test "GET /v1/adoption lists pending by default" do
      conn = call(:get, "/v1/adoption")
      assert conn.status == 200

      assert %{"state" => "pending", "entries" => [%{"id" => "cname:foss.defdo.ninja"}]} =
               Jason.decode!(conn.resp_body)
    end

    test "GET /v1/adoption is unauthorized without a token" do
      conn = conn(:get, "/v1/adoption") |> Router.call([])
      assert conn.status == 401
    end

    test "POST accept records and promotes" do
      conn = call(:post, "/v1/adoption/cname:foss.defdo.ninja/accept", %{"by" => "api"})
      assert conn.status == 200

      assert %{"entry" => %{"state" => "accepted", "decided_by" => "api"}} =
               Jason.decode!(conn.resp_body)

      assert {:ok, doc} = Defdo.DDNS.DesiredStateStore.load()
      assert Enum.any?(doc["cloudflare"]["cname_records"], &(&1["name"] == "foss.defdo.ninja"))
    end

    test "POST reject records the decision" do
      conn = call(:post, "/v1/adoption/cname:foss.defdo.ninja/reject", %{"note" => "not ours"})
      assert conn.status == 200

      assert %{"entry" => %{"state" => "rejected", "note" => "not ours"}} =
               Jason.decode!(conn.resp_body)
    end

    test "POST refresh requires a domain" do
      conn = call(:post, "/v1/adoption/refresh", %{})
      assert conn.status == 422
    end

    test "POST refresh without auth is unauthorized" do
      conn =
        conn(:post, "/v1/adoption/refresh", Jason.encode!(%{"domain" => "defdo.ninja"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call([])

      assert conn.status == 401
    end

    test "POST accept on an unknown id is 404" do
      conn = call(:post, "/v1/adoption/cname:nope.defdo.ninja/accept")
      assert conn.status == 404
    end
  end
end

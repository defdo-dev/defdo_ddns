defmodule Defdo.Cloudflare.DDNSTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.DDNS

  describe "configuration parsing" do
    test "get_subdomains_for_domain/1 returns correct subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{
        "example.com" => ["www", "api"],
        "test.com" => []
      })

      assert DDNS.get_subdomains_for_domain("example.com") == ["www.example.com", "api.example.com"]
      assert DDNS.get_subdomains_for_domain("test.com") == []
      
      # Capture log output to suppress expected warning for nonexistent domain
      ExUnit.CaptureLog.capture_log(fn ->
        assert DDNS.get_subdomains_for_domain("nonexistent.com") == []
      end)
    end

    test "get_cloudflare_config_domains/0 returns all configured domains" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{
        "example.com" => ["www"],
        "test.org" => ["api", "cdn"]
      })

      domains = DDNS.get_cloudflare_config_domains()
      assert "example.com" in domains
      assert "test.org" in domains
      assert length(domains) == 2
    end

    test "get_cloudflare_key/1 retrieves configuration values" do
      Application.put_env(:defdo_ddns, Cloudflare, 
        api_token: "test_token",
        domain_mappings: %{"example.com" => ["www"]},
        auto_create_missing_records: true
      )

      assert DDNS.get_cloudflare_key(:api_token) == "test_token"
      assert DDNS.get_cloudflare_key(:domain_mappings) == %{"example.com" => ["www"]}
      assert DDNS.get_cloudflare_key(:auto_create_missing_records) == true
      assert DDNS.get_cloudflare_key(:nonexistent_key) == ""
    end
  end

  describe "records_to_monitor/1" do
    test "includes domain and all subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{
        "example.com" => ["www", "api", "cdn"]
      })

      records = DDNS.records_to_monitor("example.com")
      assert "example.com" in records
      assert "www.example.com" in records
      assert "api.example.com" in records
      assert "cdn.example.com" in records
      assert length(records) == 4
    end

    test "handles domain with no subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{
        "example.com" => []
      })

      records = DDNS.records_to_monitor("example.com")
      assert records == ["example.com"]
    end

    test "handles unconfigured domain" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{})
      
      # Capture log output to suppress expected warning
      ExUnit.CaptureLog.capture_log(fn ->
        records = DDNS.records_to_monitor("unconfigured.com")
        assert records == ["unconfigured.com"]
      end)
    end
  end

  describe "input_for_update_dns_records/2" do
    test "filters records that need IP updates and transforms for update" do
      dns_records = [
        %{"name" => "example.com", "id" => "1", "content" => "1.1.1.1", "type" => "A", "ttl" => 300, "proxied" => false},
        %{"name" => "www.example.com", "id" => "2", "content" => "2.2.2.2", "type" => "A", "ttl" => 300, "proxied" => false},
        %{"name" => "api.example.com", "id" => "3", "content" => "3.3.3.3", "type" => "A", "ttl" => 300, "proxied" => false}
      ]
      
      local_ip = "3.3.3.3"
      result = DDNS.input_for_update_dns_records(dns_records, local_ip)
      
      # Should filter out records that already have the correct IP
      assert length(result) == 2
      
      # Check that the result contains tuples with record ID and JSON body
      assert Enum.any?(result, fn {id, _body} -> id == "1" end)
      assert Enum.any?(result, fn {id, _body} -> id == "2" end)
      refute Enum.any?(result, fn {id, _body} -> id == "3" end)
    end

    test "handles empty DNS records list" do
      result = DDNS.input_for_update_dns_records([], "1.2.3.4")
      assert result == []
    end

    test "returns empty list when all records have correct IP" do
      dns_records = [
        %{"name" => "example.com", "id" => "1", "content" => "1.2.3.4", "type" => "A", "ttl" => 300, "proxied" => false}
      ]
      
      result = DDNS.input_for_update_dns_records(dns_records, "1.2.3.4")
      assert result == []
    end
  end

  describe "get_cloudflare_config_subdomains/1" do
    test "parses comma-separated string into list" do
      assert DDNS.get_cloudflare_config_subdomains("www,api,cdn") == ["www", "api", "cdn"]
      assert DDNS.get_cloudflare_config_subdomains("single") == ["single"]
      assert DDNS.get_cloudflare_config_subdomains("") == []
      assert DDNS.get_cloudflare_config_subdomains(nil) == []
    end

    test "handles whitespace in configuration" do
      assert DDNS.get_cloudflare_config_subdomains(" www api cdn ") == ["www", "api", "cdn"]
      assert DDNS.get_cloudflare_config_subdomains("www api") == ["www", "api"]
    end
  end
end
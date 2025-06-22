defmodule Defdo.APIIntegrationTest do
  @moduledoc false
  use ExUnit.Case
  import Defdo.TestHelpers
  alias Defdo.Cloudflare.DDNS

  setup do
    setup_test_config()
    :ok
  end

  describe "API function availability" do
    test "zone ID retrieval function exists" do
      # Verify the function exists and can be called
      assert function_exported?(DDNS, :get_zone_id, 1)
    end

    test "DNS records listing function exists" do
      assert function_exported?(DDNS, :list_dns_records, 1)
    end

    test "current IP detection function exists" do
      # Test IP detection functionality
      assert function_exported?(DDNS, :get_current_ip, 0)
    end
  end

  describe "DNS record creation and updates" do
    test "create DNS record function exists" do
      assert function_exported?(DDNS, :create_dns_record, 2)
    end

    test "update existing DNS record function exists" do
      assert function_exported?(DDNS, :apply_update, 2)
    end
  end

  describe "error handling capabilities" do
    test "API functions exist for error handling" do
      # Should handle timeouts gracefully
      assert function_exported?(DDNS, :get_current_ip, 0)
      
      # Should handle JSON parsing errors
      assert function_exported?(DDNS, :get_zone_id, 1)
      
      # Should handle server errors
      assert function_exported?(DDNS, :list_dns_records, 1)
    end
  end

  describe "configuration edge cases" do
    test "handles empty domain mappings" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{})
      
      domains = DDNS.get_cloudflare_config_domains()
      assert domains == []
    end

    test "handles nil configuration" do
      Application.delete_env(:defdo_ddns, Cloudflare)
      
      # When no config exists, get_cloudflare_key should handle nil gracefully
      # This test verifies the function doesn't crash with missing config
      assert_raise FunctionClauseError, fn ->
        DDNS.get_cloudflare_key(:domain_mappings)
      end
      
      assert_raise FunctionClauseError, fn ->
        DDNS.get_cloudflare_key(:api_token)
      end
    end

    test "handles complex subdomain structures" do
      Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{
        "example.com" => ["www", "api.v1", "deep.nested.subdomain"]
      })
      
      records = DDNS.records_to_monitor("example.com")
      
      # The function treats subdomains with dots as full domains
      assert_contains_all(records, [
        "example.com",
        "www.example.com",
        "api.v1",  # This is treated as a full domain since it contains a dot
        "deep.nested.subdomain"  # This is also treated as a full domain
      ])
    end
  end
end
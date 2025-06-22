defmodule Defdo.TestHelpers do
  @moduledoc """
  Test helpers and utilities for DDNS testing.
  """
  import ExUnit.Assertions

  @doc """
  Sets up a clean test environment with default configuration.
  """
  def setup_test_config do
    Application.put_env(:defdo_ddns, Cloudflare, 
      api_token: "test_token_123",
      domain_mappings: %{
        "example.com" => ["www", "api"],
        "test.org" => []
      },
      auto_create_missing_records: false
    )
  end

  @doc """
  Creates sample DNS records for testing.
  """
  def sample_dns_records do
    [
      %{
        "id" => "record_1",
        "name" => "example.com",
        "type" => "A",
        "content" => "192.168.1.1",
        "ttl" => 300
      },
      %{
        "id" => "record_2",
        "name" => "www.example.com",
        "type" => "A",
        "content" => "192.168.1.1",
        "ttl" => 300
      },
      %{
        "id" => "record_3",
        "name" => "api.example.com",
        "type" => "A",
        "content" => "192.168.1.2",
        "ttl" => 300
      },
      %{
        "id" => "record_4",
        "name" => "other.com",
        "type" => "A",
        "content" => "192.168.1.3",
        "ttl" => 300
      }
    ]
  end

  @doc """
  Creates a sample Cloudflare API response for zone listing.
  """
  def sample_zone_response do
    %{
      "success" => true,
      "result" => [
        %{
          "id" => "zone_123",
          "name" => "example.com",
          "status" => "active"
        }
      ]
    }
  end

  @doc """
  Creates a sample Cloudflare API response for DNS records.
  """
  def sample_dns_records_response do
    %{
      "success" => true,
      "result" => sample_dns_records()
    }
  end

  @doc """
  Creates a sample error response from Cloudflare API.
  """
  def sample_error_response do
    %{
      "success" => false,
      "errors" => [
        %{
          "code" => 1001,
          "message" => "Invalid API token"
        }
      ]
    }
  end

  @doc """
  Cleans up test environment.
  """
  def cleanup_test_config do
    Application.delete_env(:defdo_ddns, Cloudflare)
  end

  @doc """
  Asserts that a list contains all expected items.
  """
  def assert_contains_all(list, expected_items) do
    Enum.each(expected_items, fn item ->
      assert item in list, "Expected #{inspect(item)} to be in #{inspect(list)}"
    end)
  end

  @doc """
  Asserts that a list does not contain any of the given items.
  """
  def refute_contains_any(list, unwanted_items) do
    Enum.each(unwanted_items, fn item ->
      refute item in list, "Expected #{inspect(item)} to NOT be in #{inspect(list)}"
    end)
  end
end
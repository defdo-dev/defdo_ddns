defmodule Defdo.ConfigHelperTest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.ConfigHelper

  describe "resolve_domain_mappings/2" do
    test "uses legacy format when json mapping is empty" do
      assert ConfigHelper.resolve_domain_mappings("example.com:www,api", "") == %{
               "example.com" => ["www", "api"]
             }
    end

    test "prefers json object mapping when provided" do
      legacy = "example.com:legacy"

      json =
        ~s({"example.com":["www","api"],"defdo.in":[]})

      assert ConfigHelper.resolve_domain_mappings(legacy, json) == %{
               "example.com" => ["www", "api"],
               "defdo.in" => []
             }
    end

    test "supports json array mapping entries" do
      json =
        ~s([{"domain":"example.com","subdomains":["www","api"]},{"domain":"example.com","hosts":["cdn"]},{"domain":"defdo.in","records":"join,portal"}])

      assert ConfigHelper.resolve_domain_mappings("", json) == %{
               "example.com" => ["www", "api", "cdn"],
               "defdo.in" => ["join", "portal"]
             }
    end

    test "falls back to legacy when json mapping is invalid" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ConfigHelper.resolve_domain_mappings("example.com:www", "{") == %{
                   "example.com" => ["www"]
                 }
        end)

      assert warning =~ "CLOUDFLARE_A_RECORDS_JSON is invalid"
      assert warning =~ "Falling back to CLOUDFLARE_DOMAIN_MAPPINGS"
    end
  end

  describe "parse_domain_mappings_json/1" do
    test "returns error for invalid json shape" do
      assert {:error, "expected object or array"} =
               ConfigHelper.parse_domain_mappings_json(~s("string"))
    end

    test "returns error for array entries that are not objects" do
      assert {:error, "array entries must be objects"} =
               ConfigHelper.parse_domain_mappings_json(~s(["example.com"]))
    end
  end

  describe "resolve_json_domain_mappings/2" do
    test "returns default mapping when json is empty" do
      assert ConfigHelper.resolve_json_domain_mappings("", %{"example.com" => []}) == %{
               "example.com" => []
             }
    end

    test "returns parsed mapping when json is valid" do
      assert ConfigHelper.resolve_json_domain_mappings(~s({"ipv6-only.net":["app"]}), %{}) == %{
               "ipv6-only.net" => ["app"]
             }
    end

    test "falls back to default mapping when json is invalid" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert ConfigHelper.resolve_json_domain_mappings("{", %{"fallback.net" => ["app"]}) ==
                   %{
                     "fallback.net" => ["app"]
                   }
        end)

      assert warning =~ "JSON mapping source is invalid"
      assert warning =~ "Falling back to default mapping value"
    end
  end
end

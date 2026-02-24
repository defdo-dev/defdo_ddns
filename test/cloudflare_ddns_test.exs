defmodule Defdo.Cloudflare.DDNSTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.DDNS

  describe "configuration parsing" do
    test "get_subdomains_for_domain/1 returns correct subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "example.com" => ["www", "api"],
          "test.com" => []
        }
      )

      assert DDNS.get_subdomains_for_domain("example.com") == [
               "www.example.com",
               "api.example.com"
             ]

      assert DDNS.get_subdomains_for_domain("test.com") == []

      # Capture log output to suppress expected warning for nonexistent domain
      ExUnit.CaptureLog.capture_log(fn ->
        assert DDNS.get_subdomains_for_domain("nonexistent.com") == []
      end)
    end

    test "get_cloudflare_config_domains/0 returns all configured domains" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "example.com" => ["www"],
          "test.org" => ["api", "cdn"]
        }
      )

      domains = DDNS.get_cloudflare_config_domains()
      assert "example.com" in domains
      assert "test.org" in domains
      assert length(domains) == 2
    end

    test "get_cloudflare_key/1 retrieves configuration values" do
      Application.put_env(:defdo_ddns, Cloudflare,
        api_token: "test_token",
        domain_mappings: %{"example.com" => ["www"]},
        auto_create_missing_records: true,
        proxy_a_records: true
      )

      assert DDNS.get_cloudflare_key(:api_token) == "test_token"
      assert DDNS.get_cloudflare_key(:domain_mappings) == %{"example.com" => ["www"]}
      assert DDNS.get_cloudflare_key(:auto_create_missing_records) == true
      assert DDNS.get_cloudflare_key(:proxy_a_records) == true
      assert DDNS.get_cloudflare_key(:nonexistent_key) == ""
    end
  end

  describe "records_to_monitor/1" do
    test "includes domain and all subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "example.com" => ["www", "api", "cdn"]
        }
      )

      records = DDNS.records_to_monitor("example.com")
      assert "example.com" in records
      assert "www.example.com" in records
      assert "api.example.com" in records
      assert "cdn.example.com" in records
      assert length(records) == 4
    end

    test "handles domain with no subdomains" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "example.com" => []
        }
      )

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

    test "expands relative wildcard subdomains to fully-qualified wildcard domains" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "zone-one.example" => ["*.edge", "edge", "gateway"],
          "zone-two.example" => ["*.app", "app"]
        }
      )

      zone_one_records = DDNS.records_to_monitor("zone-one.example")
      assert "*.edge.zone-one.example" in zone_one_records
      assert "edge.zone-one.example" in zone_one_records
      assert "gateway.zone-one.example" in zone_one_records

      zone_two_records = DDNS.records_to_monitor("zone-two.example")
      assert "*.app.zone-two.example" in zone_two_records
      assert "app.zone-two.example" in zone_two_records
    end

    test "treats @ as root domain and never builds invalid @.domain hostnames" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{
          "paridin.net" => ["@", "h"]
        }
      )

      records = DDNS.records_to_monitor("paridin.net")

      assert records == ["paridin.net", "h.paridin.net"]
      refute "@.paridin.net" in records
    end
  end

  describe "input_for_update_dns_records/2" do
    test "filters records that need IP updates and transforms for update" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)

      dns_records = [
        %{
          "name" => "example.com",
          "id" => "1",
          "content" => "1.1.1.1",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        },
        %{
          "name" => "www.example.com",
          "id" => "2",
          "content" => "2.2.2.2",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        },
        %{
          "name" => "api.example.com",
          "id" => "3",
          "content" => "3.3.3.3",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
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
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)
      result = DDNS.input_for_update_dns_records([], "1.2.3.4")
      assert result == []
    end

    test "returns empty list when all records have correct IP" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)

      dns_records = [
        %{
          "name" => "example.com",
          "id" => "1",
          "content" => "1.2.3.4",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      result = DDNS.input_for_update_dns_records(dns_records, "1.2.3.4")
      assert result == []
    end

    test "forces proxied mode when proxy_a_records is enabled" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      dns_records = [
        %{
          "name" => "example.com",
          "id" => "1",
          "content" => "9.9.9.9",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      [{"1", body}] = DDNS.input_for_update_dns_records(dns_records, "1.1.1.1")
      assert %{"proxied" => true, "ttl" => 1} = Jason.decode!(body)
    end

    test "updates record when IP is already correct but proxy is disabled" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      dns_records = [
        %{
          "name" => "example.com",
          "id" => "1",
          "content" => "1.1.1.1",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      [{"1", body}] = DDNS.input_for_update_dns_records(dns_records, "1.1.1.1")
      assert %{"content" => "1.1.1.1", "proxied" => true, "ttl" => 1} = Jason.decode!(body)
    end

    test "skips update when IP and proxy state are already correct" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      dns_records = [
        %{
          "name" => "example.com",
          "id" => "1",
          "content" => "1.1.1.1",
          "type" => "A",
          "ttl" => 1,
          "proxied" => true
        }
      ]

      assert DDNS.input_for_update_dns_records(dns_records, "1.1.1.1") == []
    end

    test "skips duplicate updates when one record is already in desired state" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      dns_records = [
        %{
          "name" => "*.edge.zone-one.example",
          "id" => "good",
          "content" => "203.0.113.11",
          "type" => "A",
          "ttl" => 1,
          "proxied" => true
        },
        %{
          "name" => "*.edge.zone-one.example",
          "id" => "stale",
          "content" => "203.0.113.10",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert DDNS.input_for_update_dns_records(dns_records, "203.0.113.11") == []
        end)

      assert log =~ "Duplicate DNS records detected for A *.edge.zone-one.example"
      assert log =~ "stale"
    end

    test "updates A and AAAA records with different desired addresses" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)

      dns_records = [
        %{
          "name" => "edge.example.com",
          "id" => "a1",
          "content" => "203.0.113.10",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        },
        %{
          "name" => "edge.example.com",
          "id" => "aaaa1",
          "content" => "2001:db8::10",
          "type" => "AAAA",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      updates =
        DDNS.input_for_update_dns_records(dns_records, %{
          "A" => "203.0.113.11",
          "AAAA" => "2001:db8::11"
        })

      assert length(updates) == 2

      assert Enum.any?(updates, fn {id, body} ->
               id == "a1" and Jason.decode!(body)["content"] == "203.0.113.11"
             end)

      assert Enum.any?(updates, fn {id, body} ->
               id == "aaaa1" and Jason.decode!(body)["content"] == "2001:db8::11"
             end)
    end

    test "skips AAAA update when no desired IPv6 is provided" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)

      dns_records = [
        %{
          "name" => "edge.example.com",
          "id" => "a1",
          "content" => "203.0.113.10",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        },
        %{
          "name" => "edge.example.com",
          "id" => "aaaa1",
          "content" => "2001:db8::10",
          "type" => "AAAA",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      updates = DDNS.input_for_update_dns_records(dns_records, %{"A" => "203.0.113.11"})

      assert length(updates) == 1
      assert [{"a1", _body}] = updates
    end

    test "updates only one record when multiple duplicates need changes" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      dns_records = [
        %{
          "name" => "*.edge.zone-one.example",
          "id" => "first",
          "content" => "203.0.113.10",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        },
        %{
          "name" => "*.edge.zone-one.example",
          "id" => "second",
          "content" => "203.0.113.12",
          "type" => "A",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = DDNS.input_for_update_dns_records(dns_records, "203.0.113.11")
          assert length(result) == 1

          [{"first", body}] = result

          assert %{"content" => "203.0.113.11", "proxied" => true, "ttl" => 1} =
                   Jason.decode!(body)
        end)

      assert log =~ "Duplicate DNS records detected for A *.edge.zone-one.example"
      assert log =~ "second"
    end
  end

  describe "domain mapping helpers" do
    test "returns combined configured domains from A and AAAA mappings" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{"example.com" => ["www"], "defdo.in" => []},
        aaaa_domain_mappings: %{"example.com" => ["www"], "ipv6-only.net" => ["app"]}
      )

      domains = DDNS.get_all_cloudflare_config_domains()
      assert "example.com" in domains
      assert "defdo.in" in domains
      assert "ipv6-only.net" in domains
      assert length(domains) == 3
    end

    test "checks domain configuration per mapping key" do
      Application.put_env(:defdo_ddns, Cloudflare,
        domain_mappings: %{"example.com" => ["www"]},
        aaaa_domain_mappings: %{"ipv6-only.net" => ["app"]}
      )

      assert DDNS.domain_configured?("example.com", :domain_mappings)
      refute DDNS.domain_configured?("example.com", :aaaa_domain_mappings)
      assert DDNS.domain_configured?("ipv6-only.net", :aaaa_domain_mappings)
      refute DDNS.domain_configured?("missing.net", :domain_mappings)
    end
  end

  describe "get_cname_records_for_domain/1" do
    test "normalizes relative records and applies defaults" do
      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: true,
        cname_records: [
          %{"name" => "*", "target" => "@"},
          %{"name" => "www", "target" => "@", "proxied" => false, "ttl" => "120"},
          %{"name" => "api.other.com", "target" => "origin.other.net"},
          %{"name" => "@", "target" => "@", "domain" => "example.com"}
        ]
      )

      records = DDNS.get_cname_records_for_domain("example.com")

      assert %{
               "type" => "CNAME",
               "name" => "*.example.com",
               "content" => "example.com",
               "proxied" => true,
               "ttl" => 1
             } in records

      assert %{
               "type" => "CNAME",
               "name" => "www.example.com",
               "content" => "example.com",
               "proxied" => false,
               "ttl" => 120
             } in records

      refute Enum.any?(records, &(&1["name"] == "api.other.com"))
      refute Enum.any?(records, &(&1["name"] == "example.com" and &1["content"] == "example.com"))
    end

    test "honors optional domain scope field" do
      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: false,
        cname_records: [
          %{"domain" => "example.com", "name" => "join", "target" => "@"},
          %{"domain" => "example.org", "name" => "join", "target" => "@"}
        ]
      )

      example_com = DDNS.get_cname_records_for_domain("example.com")
      example_org = DDNS.get_cname_records_for_domain("example.org")

      assert Enum.any?(example_com, &(&1["name"] == "join.example.com"))
      refute Enum.any?(example_com, &(&1["name"] == "join.example.org"))

      assert Enum.any?(example_org, &(&1["name"] == "join.example.org"))
      refute Enum.any?(example_org, &(&1["name"] == "join.example.com"))
    end
  end

  describe "input_for_update_cname_records/2" do
    test "updates cname when target or proxy state differs" do
      existing = [
        %{
          "name" => "join.example.com",
          "id" => "c1",
          "content" => "old.example.com",
          "type" => "CNAME",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      desired = %{
        "name" => "join.example.com",
        "content" => "example.com",
        "type" => "CNAME",
        "ttl" => 1,
        "proxied" => true
      }

      [{"c1", body}] = DDNS.input_for_update_cname_records(existing, desired)

      assert %{
               "type" => "CNAME",
               "name" => "join.example.com",
               "content" => "example.com",
               "proxied" => true,
               "ttl" => 1
             } = Jason.decode!(body)
    end

    test "skips duplicates when one cname is already in desired state" do
      records = [
        %{
          "name" => "join.example.com",
          "id" => "good",
          "content" => "example.com",
          "type" => "CNAME",
          "ttl" => 1,
          "proxied" => true
        },
        %{
          "name" => "join.example.com",
          "id" => "stale",
          "content" => "old.example.com",
          "type" => "CNAME",
          "ttl" => 300,
          "proxied" => false
        }
      ]

      desired = %{
        "name" => "join.example.com",
        "content" => "example.com",
        "type" => "CNAME",
        "ttl" => 1,
        "proxied" => true
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert DDNS.input_for_update_cname_records(records, desired) == []
        end)

      assert log =~ "Duplicate DNS records detected for CNAME join.example.com"
      assert log =~ "stale"
    end
  end

  describe "resolve_proxied_value/1" do
    test "keeps record proxied value by default" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: false)

      assert DDNS.resolve_proxied_value(%{"proxied" => true}) == true
      assert DDNS.resolve_proxied_value(%{"proxied" => false}) == false
      assert DDNS.resolve_proxied_value(%{}) == false
    end

    test "forces proxied true when config is enabled" do
      Application.put_env(:defdo_ddns, Cloudflare, proxy_a_records: true)

      assert DDNS.resolve_proxied_value(%{"proxied" => false}) == true
      assert DDNS.resolve_proxied_value(%{}) == true
    end

    test "forces dns only for excluded records when proxy mode is enabled" do
      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: true,
        proxy_exclude: ["*.idp-dev.example.com", "legacy.example.com"]
      )

      assert DDNS.resolve_proxied_value(%{
               "name" => "foo.idp-dev.example.com",
               "proxied" => false
             }) ==
               false

      assert DDNS.resolve_proxied_value(%{"name" => "legacy.example.com", "proxied" => true}) ==
               false

      assert DDNS.resolve_proxied_value(%{"name" => "www.example.com", "proxied" => false}) ==
               true
    end
  end

  describe "resolve_ttl/2" do
    test "uses auto ttl when proxied is enabled" do
      assert DDNS.resolve_ttl(%{"ttl" => 300}, true) == 1
      assert DDNS.resolve_ttl(%{}, true) == 1
    end

    test "keeps record ttl when proxied is disabled" do
      assert DDNS.resolve_ttl(%{"ttl" => 120}, false) == 120
      assert DDNS.resolve_ttl(%{}, false) == 300
    end

    test "normalizes auto ttl back to 300 when switching to dns only" do
      assert DDNS.resolve_ttl(%{"ttl" => 1}, false) == 300
    end
  end

  describe "proxy_excluded?/2 and get_proxy_exclude_patterns/0" do
    test "matches exact and wildcard exclusions" do
      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_exclude: ["*.idp-dev.example.com", "legacy.example.com"]
      )

      assert DDNS.get_proxy_exclude_patterns() == ["*.idp-dev.example.com", "legacy.example.com"]
      assert DDNS.proxy_excluded?("foo.idp-dev.example.com")
      assert DDNS.proxy_excluded?("legacy.example.com")
      refute DDNS.proxy_excluded?("idp-dev.example.com")
      refute DDNS.proxy_excluded?("www.example.com")
    end
  end

  describe "requires_advanced_certificate?/2" do
    test "detects deep hostnames under a zone" do
      refute DDNS.requires_advanced_certificate?("example.com", "example.com")
      refute DDNS.requires_advanced_certificate?("api.example.com", "example.com")
      refute DDNS.requires_advanced_certificate?("*.example.com", "example.com")
      assert DDNS.requires_advanced_certificate?("foo.bar.example.com", "example.com")
      assert DDNS.requires_advanced_certificate?("*.idp-dev.example.com", "example.com")
    end
  end

  describe "evaluate_domain_posture/3" do
    test "returns green when records are proxied and ssl mode is strict" do
      records = [
        %{"name" => "app.example.com", "type" => "A", "proxied" => true},
        %{"name" => "api.example.com", "type" => "A", "proxied" => true}
      ]

      posture = DDNS.evaluate_domain_posture(records, "strict", true)

      assert posture.overall == :green
      assert posture.edge_tls == :green
      assert posture.hairpin_risk == :low
      assert posture.proxy_mismatch_count == 0
      assert posture.proxied_count == 2
      assert posture.dns_only_count == 0
    end

    test "returns yellow when ssl mode is full even with proxied records" do
      records = [
        %{"name" => "app.example.com", "type" => "A", "proxied" => true}
      ]

      posture = DDNS.evaluate_domain_posture(records, "full", true)

      assert posture.overall == :yellow
      assert posture.edge_tls == :yellow
      assert posture.hairpin_risk == :low
    end

    test "returns red when ssl mode is flexible" do
      records = [
        %{"name" => "app.example.com", "type" => "A", "proxied" => true}
      ]

      posture = DDNS.evaluate_domain_posture(records, "flexible", true)

      assert posture.overall == :red
      assert posture.edge_tls == :red
    end

    test "flags high hairpin risk when records are dns only" do
      records = [
        %{"name" => "app.example.com", "type" => "A", "proxied" => false}
      ]

      posture = DDNS.evaluate_domain_posture(records, "strict", false)

      assert posture.overall == :yellow
      assert posture.hairpin_risk == :high
      assert posture.dns_only_count == 1
      assert posture.proxied_count == 0
    end

    test "flags proxy mismatches when expected proxied does not match record state" do
      records = [
        %{"name" => "app.example.com", "type" => "A", "proxied" => false},
        %{"name" => "api.example.com", "type" => "A", "proxied" => true}
      ]

      posture = DDNS.evaluate_domain_posture(records, "strict", true)

      assert posture.overall == :yellow
      assert posture.proxy_mismatch_count == 1
      assert posture.hairpin_risk == :high
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

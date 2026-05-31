defmodule Defdo.DDNS.RecordSnapshotTest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.DDNS.RecordSnapshot

  test "new/2 builds a valid portable snapshot for multiple record types" do
    records = [
      %{
        "provider" => "cloudflare",
        "domain" => "example.com",
        "type" => "CNAME",
        "name" => "join",
        "content" => "@",
        "ttl" => 1,
        "proxied" => true,
        "metadata" => %{"source" => "snapshot"}
      },
      %{
        "domain" => "example.com",
        "type" => "A",
        "name" => "api",
        "content" => "203.0.113.10",
        "ttl" => 300,
        "proxied" => false,
        "metadata" => %{}
      },
      %{
        "domain" => "example.com",
        "type" => "AAAA",
        "name" => "ipv6",
        "content" => "2001:db8::1",
        "ttl" => 300,
        "proxied" => false,
        "metadata" => %{}
      },
      %{
        "domain" => "example.com",
        "type" => "TXT",
        "name" => "txt",
        "content" => "hello world",
        "ttl" => 300,
        "proxied" => false,
        "metadata" => %{}
      }
    ]

    assert {:ok, snapshot} =
             RecordSnapshot.new(records, updated_at: "2026-05-30T00:00:00Z")

    assert snapshot["version"] == 1
    assert snapshot["updated_at"] == "2026-05-30T00:00:00Z"
    assert Enum.sort(Enum.map(snapshot["records"], & &1["type"])) == ["A", "AAAA", "CNAME", "TXT"]
  end

  test "encode/1 and decode/1 round-trip the portable snapshot" do
    {:ok, snapshot} =
      RecordSnapshot.new(
        [
          %{
            "domain" => "example.com",
            "type" => "CNAME",
            "name" => "join",
            "content" => "@",
            "ttl" => 1,
            "proxied" => true,
            "metadata" => %{}
          }
        ],
        updated_at: "2026-05-30T00:00:00Z"
      )

    assert {:ok, encoded} = RecordSnapshot.encode(snapshot)
    assert {:ok, decoded} = RecordSnapshot.decode(encoded)
    assert decoded == snapshot
  end

  test "from_legacy_cname_env/2 converts legacy env JSON into canonical snapshot records" do
    legacy_env =
      Jason.encode!([
        %{
          "name" => "join",
          "target" => "@",
          "proxied" => true,
          "ttl" => "120",
          "domain" => "example.com"
        }
      ])

    assert {:ok, snapshot} =
             RecordSnapshot.from_legacy_cname_env(legacy_env,
               updated_at: "2026-05-30T00:00:00Z"
             )

    assert snapshot["version"] == 1
    assert snapshot["updated_at"] == "2026-05-30T00:00:00Z"

    assert [
             %{
               "provider" => "cloudflare",
               "domain" => "example.com",
               "type" => "CNAME",
               "name" => "join",
               "content" => "@",
               "ttl" => 120,
               "proxied" => true,
               "metadata" => %{}
             }
           ] = snapshot["records"]
  end
end

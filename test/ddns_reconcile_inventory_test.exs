defmodule Defdo.DDNS.Reconcile.InventoryTest do
  @moduledoc """
  Slice 01 acceptance: classify a zone's live records against what DDNS declares.

  The load-bearing test is the edge-error one. Inventory reasons about *absence*,
  so an empty listing and a failed listing mean opposite things: read a transient
  Cloudflare 521 as "the zone is empty" and every declared record looks missing
  while every live record looks unmanaged — one flap would queue a zone's worth
  of bogus adoptions.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.DDNS.Reconcile.Inventory

  @zone_id "zone-abc"

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, Defdo.DDNS.RecordStore)

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Req.default_options([])
      restore(Cloudflare, previous_cloudflare)
      restore(Defdo.DDNS.RecordStore, previous_store)
      Defdo.DDNS.RecordStore.reload()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  # Declares: A for defdo.ninja + api.defdo.ninja, CNAME for docs.defdo.ninja.
  defp declare! do
    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      domain_mappings: %{"defdo.ninja" => ["api"]},
      cname_records: [
        %{"domain" => "defdo.ninja", "name" => "docs", "target" => "@", "proxied" => true}
      ]
    )

    Application.put_env(:defdo_ddns, Defdo.DDNS.RecordStore,
      module: Defdo.DDNS.RecordStores.FileEtsStore,
      options: [],
      allow_empty_records: true
    )

    assert :ok = Defdo.DDNS.RecordStore.reload()
  end

  defp cf_record(type, name, content \\ "defdo.ninja") do
    %{"type" => type, "name" => name, "content" => content, "proxied" => true, "ttl" => 1}
  end

  # Zone lookup answers first, then the record listing.
  defp stub_zone(records) do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "dns_records") do
        Req.Test.json(conn, %{"success" => true, "result" => records})
      else
        Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => @zone_id}]})
      end
    end)
  end

  describe "classification" do
    test "splits live records into managed, unmanaged and missing" do
      declare!()

      stub_zone([
        cf_record("A", "defdo.ninja", "1.2.3.4"),
        cf_record("A", "api.defdo.ninja", "1.2.3.4"),
        cf_record("CNAME", "docs.defdo.ninja"),
        # Live but never declared — the drift this slice exists to surface.
        cf_record("CNAME", "foss.defdo.ninja"),
        cf_record("CNAME", "travel.defdo.ninja")
      ])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")

      assert report["counts"] == %{"managed" => 3, "unmanaged" => 2, "missing" => 0}
      assert names(report["unmanaged"]) == ["foss.defdo.ninja", "travel.defdo.ninja"]
    end

    test "a declared record absent from the zone is missing" do
      declare!()
      stub_zone([cf_record("A", "defdo.ninja", "1.2.3.4")])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")

      assert report["counts"]["missing"] == 2
      assert "api.defdo.ninja" in names(report["missing"])
      assert "docs.defdo.ninja" in names(report["missing"])
    end

    test "drifted content stays managed rather than becoming missing" do
      declare!()

      stub_zone([
        cf_record("A", "defdo.ninja", "9.9.9.9"),
        cf_record("A", "api.defdo.ninja", "9.9.9.9"),
        cf_record("CNAME", "docs.defdo.ninja", "somewhere-else.example")
      ])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")

      assert report["counts"]["managed"] == 3
      assert report["counts"]["missing"] == 0
    end

    test "record types DDNS does not manage never appear" do
      declare!()

      stub_zone([
        cf_record("A", "defdo.ninja", "1.2.3.4"),
        cf_record("MX", "defdo.ninja", "mail.example"),
        cf_record("TXT", "defdo.ninja", "v=spf1 -all"),
        cf_record("NS", "sub.defdo.ninja", "ns1.example")
      ])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")

      all = report["managed"] ++ report["unmanaged"] ++ report["missing"]
      assert Enum.all?(all, &(&1["type"] in ~w(A AAAA CNAME)))
      assert report["counts"]["unmanaged"] == 0
    end

    test "classification is case-insensitive on the record name" do
      declare!()
      stub_zone([cf_record("CNAME", "DOCS.defdo.ninja")])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")

      assert report["counts"]["unmanaged"] == 0
      assert report["counts"]["managed"] == 1
    end

    test "ordering is deterministic across runs" do
      declare!()

      records = [
        cf_record("CNAME", "zeta.defdo.ninja"),
        cf_record("CNAME", "alpha.defdo.ninja"),
        cf_record("CNAME", "mid.defdo.ninja")
      ]

      stub_zone(records)
      assert {:ok, first} = Inventory.inventory("defdo.ninja")
      stub_zone(Enum.reverse(records))
      assert {:ok, second} = Inventory.inventory("defdo.ninja")

      assert names(first["unmanaged"]) == names(second["unmanaged"])
    end
  end

  describe "failure handling" do
    test "a Cloudflare edge error reports an error and invents nothing" do
      declare!()

      Req.Test.stub(__MODULE__, fn conn ->
        if String.contains?(conn.request_path, "dns_records") do
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.resp(521, "error code: 521\n")
        else
          Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => @zone_id}]})
        end
      end)

      log =
        capture_log(fn ->
          assert {:error, :listing_failed} = Inventory.inventory("defdo.ninja")
        end)

      assert log =~ "521"
    end

    test "an unresolvable zone reports an error" do
      declare!()

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"success" => true, "result" => []})
      end)

      log =
        capture_log(fn ->
          assert {:error, :zone_unresolved} = Inventory.inventory("defdo.ninja")
        end)

      assert log =~ "zone id"
    end

    test "a genuinely empty zone is not an error" do
      declare!()
      stub_zone([])

      assert {:ok, report} = Inventory.inventory("defdo.ninja")
      assert report["counts"]["unmanaged"] == 0
      assert report["counts"]["missing"] == 3
    end
  end

  describe "read-only guarantee" do
    test "no write request is issued" do
      declare!()
      parent = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(parent, {:method, conn.method})

        if String.contains?(conn.request_path, "dns_records") do
          Req.Test.json(conn, %{"success" => true, "result" => [cf_record("A", "defdo.ninja")]})
        else
          Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => @zone_id}]})
        end
      end)

      assert {:ok, _report} = Inventory.inventory("defdo.ninja")

      methods = collect_methods([])
      assert methods != []
      assert Enum.all?(methods, &(&1 == "GET")), "expected only GETs, got: #{inspect(methods)}"
    end
  end

  defp collect_methods(acc) do
    receive do
      {:method, m} -> collect_methods([m | acc])
    after
      0 -> acc
    end
  end

  defp names(records), do: records |> Enum.map(& &1["name"]) |> Enum.sort()
end

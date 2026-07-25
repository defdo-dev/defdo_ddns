defmodule Defdo.DDNS.AdoptionTest do
  @moduledoc """
  Slice 02 acceptance.

  Two invariants carry the design. A record must appear as pending exactly once
  no matter how often discovery runs, and a rejection must be permanent — if
  either breaks, every refresh re-asks a question already answered and the
  operator stops reading the list, which is the failure mode the whole set
  exists to avoid.
  """
  use ExUnit.Case, async: false

  alias Defdo.DDNS.Adoption
  alias Defdo.DDNS.DesiredStateStore

  @zone_id "zone-abc"

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, Defdo.DDNS.RecordStore)
    previous_adoption = Application.get_env(:defdo_ddns, Adoption)
    previous_desired = Application.get_env(:defdo_ddns, DesiredStateStore)

    seed = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ddns-adoption-#{seed}.json")
    desired = Path.join(System.tmp_dir!(), "ddns-desired-#{seed}.json")

    Req.default_options(plug: {Req.Test, __MODULE__})
    Application.put_env(:defdo_ddns, Adoption, path: tmp)

    # Accepting promotes into desired state, so the store has to exist for a
    # decision to mean anything.
    Application.put_env(:defdo_ddns, DesiredStateStore, path: desired)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      domain_mappings: %{"defdo.ninja" => []}
    )

    Application.put_env(:defdo_ddns, Defdo.DDNS.RecordStore,
      module: Defdo.DDNS.RecordStores.FileEtsStore,
      options: [],
      allow_empty_records: true
    )

    assert :ok = Defdo.DDNS.RecordStore.reload()

    on_exit(fn ->
      Req.default_options([])
      # rm_rf, not rm: the failed-promotion test turns `desired` into a directory
      # to force a write error, and File.rm cannot remove a directory — leaving it
      # in tmp to collide with a later run's path.
      File.rm_rf(tmp)
      File.rm_rf(desired)
      restore(Cloudflare, previous_cloudflare)
      restore(Defdo.DDNS.RecordStore, previous_store)
      restore(Adoption, previous_adoption)
      restore(DesiredStateStore, previous_desired)
      Defdo.DDNS.RecordStore.reload()
    end)

    # Start from a clean slate: System.unique_integer restarts each `mix test`,
    # so a leftover file — or the directory the failed-promotion test creates —
    # can sit at this run's path. rm_rf clears either; force overwrites. The
    # refuse-if-exists behaviour is DesiredStateStore's own to test.
    File.rm_rf(desired)
    assert {:ok, _} = DesiredStateStore.seed(force: true)

    {:ok, path: tmp, desired: desired}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp cf_record(type, name, content \\ "defdo.ninja") do
    %{"type" => type, "name" => name, "content" => content, "proxied" => true, "ttl" => 1}
  end

  defp stub_zone(records) do
    Req.Test.stub(__MODULE__, fn conn ->
      if String.contains?(conn.request_path, "dns_records") do
        Req.Test.json(conn, %{"success" => true, "result" => records})
      else
        Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => @zone_id}]})
      end
    end)
  end

  # Two undeclared CNAMEs — only the apex A record is declared.
  defp stub_drift do
    stub_zone([
      cf_record("A", "defdo.ninja", "1.2.3.4"),
      cf_record("CNAME", "foss.defdo.ninja"),
      cf_record("CNAME", "travel.defdo.ninja")
    ])
  end

  describe "discovery" do
    test "files undeclared records as pending" do
      stub_drift()

      assert {:ok, %{added: 2, unchanged: 0}} = Adoption.refresh("defdo.ninja")

      pending = Adoption.list(:pending)
      assert length(pending) == 2

      assert Enum.map(pending, & &1["id"]) == [
               "cname:foss.defdo.ninja",
               "cname:travel.defdo.ninja"
             ]

      assert Enum.all?(pending, &(&1["first_seen"] != nil))
    end

    test "a record becomes pending exactly once across repeated refreshes" do
      stub_drift()

      assert {:ok, %{added: 2}} = Adoption.refresh("defdo.ninja")
      assert {:ok, %{added: 0, unchanged: 2}} = Adoption.refresh("defdo.ninja")
      assert {:ok, %{added: 0, unchanged: 2}} = Adoption.refresh("defdo.ninja")

      assert length(Adoption.list(:pending)) == 2
    end

    test "the id is stable and case-insensitive" do
      stub_zone([cf_record("CNAME", "FOSS.defdo.ninja")])
      assert {:ok, %{added: 1}} = Adoption.refresh("defdo.ninja")

      stub_zone([cf_record("CNAME", "foss.defdo.ninja")])
      assert {:ok, %{added: 0}} = Adoption.refresh("defdo.ninja")

      assert [%{"id" => "cname:foss.defdo.ninja"}] = Adoption.list(:pending)
    end

    test "an inventory failure writes nothing", %{path: path} do
      stub_drift()
      assert {:ok, %{added: 2}} = Adoption.refresh("defdo.ninja")
      before = File.read!(path)

      Req.Test.stub(__MODULE__, fn conn ->
        if String.contains?(conn.request_path, "dns_records") do
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.resp(521, "error code: 521\n")
        else
          Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => @zone_id}]})
        end
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :listing_failed} = Adoption.refresh("defdo.ninja")
      end)

      assert File.read!(path) == before
    end
  end

  describe "decisions" do
    setup do
      stub_drift()
      assert {:ok, _} = Adoption.refresh("defdo.ninja")
      :ok
    end

    test "accepting records the decision" do
      assert {:ok, entry} =
               Adoption.accept("cname:foss.defdo.ninja", %{by: "paridin", note: "ours"})

      assert entry["state"] == "accepted"
      assert entry["decided_by"] == "paridin"
      assert entry["note"] == "ours"
      assert entry["decided_at"] != nil
      assert Enum.map(Adoption.list(:pending), & &1["id"]) == ["cname:travel.defdo.ninja"]
    end

    test "a rejected record never returns to pending, even after more refreshes" do
      assert {:ok, _} = Adoption.reject("cname:travel.defdo.ninja", %{by: "paridin"})

      stub_drift()
      assert {:ok, %{added: 0}} = Adoption.refresh("defdo.ninja")
      assert {:ok, %{added: 0}} = Adoption.refresh("defdo.ninja")

      assert Enum.map(Adoption.list(:pending), & &1["id"]) == ["cname:foss.defdo.ninja"]
      assert [%{"id" => "cname:travel.defdo.ninja"}] = Adoption.list(:rejected)
    end

    test "deciding twice is an idempotent no-op, not an error" do
      assert {:ok, first} = Adoption.accept("cname:foss.defdo.ninja", %{by: "one"})
      assert {:ok, second} = Adoption.accept("cname:foss.defdo.ninja", %{by: "two"})

      assert second == first
      assert second["decided_by"] == "one"
    end

    test "a decision cannot be flipped by the opposite verb" do
      assert {:ok, _} = Adoption.reject("cname:foss.defdo.ninja")
      assert {:ok, entry} = Adoption.accept("cname:foss.defdo.ninja")

      assert entry["state"] == "rejected"
    end

    test "deciding an unknown id errors" do
      assert {:error, :not_found} = Adoption.accept("cname:nope.defdo.ninja")
    end

    test "decisions survive a reload from disk" do
      assert {:ok, _} = Adoption.accept("cname:foss.defdo.ninja", %{by: "paridin"})

      # list/1 re-reads the file every call, so this is a genuine round-trip.
      assert [%{"decided_by" => "paridin"}] = Adoption.list(:accepted)
    end
  end

  describe "persistence" do
    test "a malformed file fails loudly instead of discarding decisions", %{path: path} do
      stub_drift()
      assert {:ok, _} = Adoption.refresh("defdo.ninja")
      assert {:ok, _} = Adoption.reject("cname:foss.defdo.ninja")

      File.write!(path, "this is not json")

      assert_raise RuntimeError, ~r/malformed DDNS adoption file/, fn ->
        Adoption.list(:all)
      end
    end

    test "no temp file is left behind", %{path: path} do
      stub_drift()
      assert {:ok, _} = Adoption.refresh("defdo.ninja")

      refute File.exists?(path <> ".tmp")
      assert File.exists?(path)
    end
  end

  describe "promotion into desired state" do
    setup do
      stub_drift()
      assert {:ok, _} = Adoption.refresh("defdo.ninja")
      :ok
    end

    test "accepting declares the record so the monitor converges it" do
      assert {:ok, _} = Adoption.accept("cname:foss.defdo.ninja")

      assert {:ok, doc} = DesiredStateStore.load()
      names = Enum.map(doc["cloudflare"]["cname_records"], & &1["name"])
      assert "foss.defdo.ninja" in names
    end

    test "accepting twice does not declare it twice" do
      assert {:ok, _} = Adoption.accept("cname:foss.defdo.ninja")
      assert {:ok, _} = Adoption.accept("cname:foss.defdo.ninja")

      assert {:ok, doc} = DesiredStateStore.load()

      declared =
        Enum.filter(doc["cloudflare"]["cname_records"], &(&1["name"] == "foss.defdo.ninja"))

      assert length(declared) == 1
    end

    test "rejecting declares nothing" do
      assert {:ok, _} = Adoption.reject("cname:foss.defdo.ninja")

      assert {:ok, doc} = DesiredStateStore.load()
      names = Enum.map(doc["cloudflare"]["cname_records"], & &1["name"])
      refute "foss.defdo.ninja" in names
    end

    test "a failed promotion rolls the decision back to pending", %{desired: desired} do
      # Make the desired-state write impossible: the path is a directory.
      File.rm!(desired)
      File.mkdir_p!(desired)

      assert {:error, {:promotion_failed, _}} = Adoption.accept("cname:foss.defdo.ninja")

      # "accepted but not declared" is indistinguishable from a rejection at the
      # next sync, so the entry must be back where an operator can act on it.
      assert [%{"state" => "pending"}] =
               Adoption.list(:pending) |> Enum.filter(&(&1["id"] == "cname:foss.defdo.ninja"))

      assert Adoption.list(:accepted) == []
    end
  end
end

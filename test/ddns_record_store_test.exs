defmodule Defdo.DDNS.RecordStoreTest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.Cloudflare.DDNS
  alias Defdo.DDNS.RecordStore

  setup do
    previous_cloudflare_config = Application.get_env(:defdo_ddns, Cloudflare)
    previous_record_store_config = Application.get_env(:defdo_ddns, Defdo.DDNS.RecordStore)

    on_exit(fn ->
      restore_env(:defdo_ddns, Cloudflare, previous_cloudflare_config)
      restore_env(:defdo_ddns, Defdo.DDNS.RecordStore, previous_record_store_config)
      RecordStore.reload()
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp configure_record_store(opts) do
    base = [
      module: Defdo.DDNS.RecordStores.FileEtsStore,
      options: [],
      runtime_snapshot_path: nil,
      init_file_path: nil,
      allow_empty_records: false,
      persist_runtime_changes: false
    ]

    Application.put_env(:defdo_ddns, Defdo.DDNS.RecordStore, Keyword.merge(base, opts))
  end

  defp reload_record_store! do
    assert :ok = RecordStore.reload([])
  end

  defp temp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "defdo_ddns_record_store_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp snapshot_record(domain, name, content, type),
    do: snapshot_record(domain, name, content, type, [])

  defp snapshot_record(domain, name, content, type, opts) do
    %{
      "provider" => Keyword.get(opts, :provider, "cloudflare"),
      "domain" => domain,
      "type" => type,
      "name" => name,
      "content" => content,
      "ttl" => Keyword.get(opts, :ttl, 300),
      "proxied" => Keyword.get(opts, :proxied, false),
      "metadata" => Keyword.get(opts, :metadata, %{})
    }
  end

  defp write_snapshot_file(path, records, updated_at \\ "2026-05-30T00:00:00Z") do
    snapshot = %{"version" => 1, "updated_at" => updated_at, "records" => records}
    File.write!(path, Jason.encode!(snapshot))
  end

  describe "bootstrap precedence" do
    test "loads records from snapshot file" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "join", "@", "CNAME",
          proxied: true,
          ttl: 1,
          metadata: %{"source" => "snapshot"}
        ),
        snapshot_record("example.com", "api", "203.0.113.10", "A")
      ])

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "Loaded DDNS records from snapshot file"
      assert log =~ "count=2"
      assert log =~ "types=A,CNAME"

      assert Enum.any?(RecordStore.records(), &(&1["type"] == "A"))
      assert Enum.any?(RecordStore.records(), &(&1["type"] == "CNAME"))

      assert DDNS.get_cname_records_for_domain("example.com") == [
               %{
                 "type" => "CNAME",
                 "name" => "join.example.com",
                 "content" => "example.com",
                 "proxied" => true,
                 "ttl" => 1
               }
             ]
    end

    test "loads records from init file when snapshot is missing" do
      dir = temp_dir()
      init_path = Path.join(dir, "init.json")
      missing_snapshot_path = Path.join(dir, "missing.json")

      write_snapshot_file(init_path, [
        snapshot_record("example.com", "join", "@", "CNAME", proxied: false, ttl: 120)
      ])

      configure_record_store(
        runtime_snapshot_path: missing_snapshot_path,
        init_file_path: init_path,
        allow_empty_records: false
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "Loaded DDNS records from init file"
      assert log =~ "count=1"
      assert log =~ "types=CNAME"

      assert Enum.any?(RecordStore.records(), &(&1["name"] == "join"))

      assert DDNS.get_cname_records_for_domain("example.com") == [
               %{
                 "type" => "CNAME",
                 "name" => "join.example.com",
                 "content" => "example.com",
                 "proxied" => false,
                 "ttl" => 120
               }
             ]
    end

    test "falls back to CLOUDFLARE_CNAME_RECORDS_JSON" do
      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: true,
        cname_records: [
          %{"name" => "join", "target" => "@", "proxied" => true, "ttl" => "120"}
        ]
      )

      configure_record_store(allow_empty_records: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "Loaded DDNS records from legacy CLOUDFLARE_CNAME_RECORDS_JSON"
      assert log =~ "deprecated"
      assert log =~ "count=1"

      assert DDNS.get_cname_records_for_domain("example.com") == [
               %{
                 "type" => "CNAME",
                 "name" => "join.example.com",
                 "content" => "example.com",
                 "proxied" => true,
                 "ttl" => 1
               }
             ]
    end

    test "snapshot file takes precedence over legacy env" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "join", "@", "CNAME", proxied: false, ttl: 300)
      ])

      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: false,
        cname_records: [
          %{"name" => "legacy", "target" => "@", "proxied" => true, "ttl" => 1}
        ]
      )

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "Loaded DDNS records from snapshot file"

      assert log =~
               "Ignoring deprecated CLOUDFLARE_CNAME_RECORDS_JSON because snapshot file exists"

      assert DDNS.get_cname_records_for_domain("example.com") == [
               %{
                 "type" => "CNAME",
                 "name" => "join.example.com",
                 "content" => "example.com",
                 "proxied" => false,
                 "ttl" => 300
               }
             ]
    end

    test "bootstrap logs do not include sensitive TXT contents" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "txt", "super-secret-token", "TXT")
      ])

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "Loaded DDNS records from snapshot file"
      refute log =~ "super-secret-token"
    end

    test "empty state is rejected by default" do
      Application.put_env(:defdo_ddns, Cloudflare, cname_records: [])
      configure_record_store(allow_empty_records: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :empty_state_not_allowed} = RecordStore.reload([])
        end)

      assert log =~ "empty state"
    end

    test "empty state is allowed only when explicitly configured" do
      Application.put_env(:defdo_ddns, Cloudflare, cname_records: [])
      configure_record_store(allow_empty_records: true)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          reload_record_store!()
        end)

      assert log =~ "[warning]"
      assert log =~ "Bootstrapped DDNS record store with empty state (explicitly allowed)"
      assert RecordStore.records() == []
    end
  end

  describe "diagnostics" do
    test "status/0 returns safe operational metadata without record contents" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")
      init_path = Path.join(dir, "init.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "join", "@", "CNAME", proxied: true, ttl: 1),
        snapshot_record("example.com", "txt", "super-secret-token", "TXT"),
        snapshot_record("example.com", "api", "203.0.113.10", "A")
      ])

      write_snapshot_file(init_path, [
        snapshot_record("example.com", "legacy", "@", "CNAME")
      ])

      configure_record_store(
        runtime_snapshot_path: snapshot_path,
        init_file_path: init_path,
        allow_empty_records: false,
        persist_runtime_changes: true
      )

      reload_record_store!()

      status = RecordStore.status([])

      assert status == RecordStore.diagnostics([])
      assert status.backend == Defdo.DDNS.RecordStores.FileEtsStore
      assert status.source == :snapshot_file
      assert status.record_count == 3
      assert status.record_types == %{"A" => 1, "CNAME" => 1, "TXT" => 1}
      assert status.snapshot_path == snapshot_path
      assert status.init_path == init_path
      assert status.allow_empty_records? == false
      assert status.persist_runtime_records? == true
      assert status.writable? == true
      assert status.persistent? == true
      assert is_binary(status.last_loaded_at)
      assert status.last_persisted_at == nil
      assert status.last_error == nil
      refute Map.has_key?(status, :records)
      refute Map.has_key?(status, :snapshot)
      refute inspect(status) =~ "super-secret-token"
    end
  end

  describe "validation and persistence" do
    test "list_records/1 and export_snapshot/1 expose current runtime state" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "join", "@", "CNAME", proxied: false, ttl: 300)
      ])

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: false)
      reload_record_store!()

      assert RecordStore.list_records([]) == RecordStore.records()

      snapshot = RecordStore.export_snapshot([])
      assert snapshot["version"] == 1
      assert Enum.any?(snapshot["records"], &(&1["type"] == "CNAME"))
    end

    test "malformed file returns a clear error" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "broken.json")
      File.write!(snapshot_path, "{not valid json")

      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: false,
        cname_records: [
          %{"name" => "legacy", "target" => "@", "proxied" => true, "ttl" => 1}
        ]
      )

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: true)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:invalid_snapshot, ^snapshot_path, reason}} = RecordStore.reload()
          assert is_binary(reason)
          assert reason != ""
        end)

      assert log =~ "Invalid DDNS snapshot file"
      assert log =~ snapshot_path
      refute log =~ "Loaded DDNS records from legacy CLOUDFLARE_CNAME_RECORDS_JSON"
    end

    test "malformed init file does not fall back to legacy env" do
      dir = temp_dir()
      init_path = Path.join(dir, "broken-init.json")
      missing_snapshot_path = Path.join(dir, "missing-snapshot.json")
      File.write!(init_path, "{not valid json")

      Application.put_env(:defdo_ddns, Cloudflare,
        proxy_a_records: false,
        cname_records: [
          %{"name" => "legacy", "target" => "@", "proxied" => true, "ttl" => 1}
        ]
      )

      configure_record_store(
        runtime_snapshot_path: missing_snapshot_path,
        init_file_path: init_path,
        allow_empty_records: true
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:invalid_init, ^init_path, reason}} = RecordStore.reload()
          assert is_binary(reason)
          assert reason != ""
        end)

      assert log =~ "Invalid DDNS init file"
      assert log =~ init_path
      refute log =~ "Loaded DDNS records from legacy CLOUDFLARE_CNAME_RECORDS_JSON"
    end

    test "multiple record types are accepted" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      write_snapshot_file(snapshot_path, [
        snapshot_record("example.com", "join", "@", "CNAME", proxied: true, ttl: 1),
        snapshot_record("example.com", "api", "203.0.113.10", "A"),
        snapshot_record("example.com", "txt", "hello", "TXT")
      ])

      configure_record_store(runtime_snapshot_path: snapshot_path, allow_empty_records: false)
      reload_record_store!()

      assert Enum.sort(Enum.map(RecordStore.records(), & &1["type"])) == ["A", "CNAME", "TXT"]

      assert DDNS.get_cname_records_for_domain("example.com") == [
               %{
                 "type" => "CNAME",
                 "name" => "join.example.com",
                 "content" => "example.com",
                 "proxied" => true,
                 "ttl" => 1
               }
             ]
    end

    test "write_snapshot/2 writes a portable snapshot file" do
      dir = temp_dir()
      explicit_path = Path.join(dir, "export.json")

      configure_record_store(
        allow_empty_records: true,
        persist_runtime_changes: false
      )

      reload_record_store!()

      assert :ok =
               RecordStore.replace_records([
                 snapshot_record("example.com", "join", "@", "CNAME", proxied: true, ttl: 1)
               ])

      snapshot = RecordStore.export_snapshot([])
      assert :ok = RecordStore.write_snapshot(explicit_path, [])

      persisted = Jason.decode!(File.read!(explicit_path))

      assert persisted == snapshot
      assert File.exists?(explicit_path)
      assert Enum.sort(File.ls!(dir)) == ["export.json"]
    end

    test "persist/1 writes to the configured snapshot path" do
      dir = temp_dir()
      snapshot_path = Path.join(dir, "records.json")

      configure_record_store(
        runtime_snapshot_path: snapshot_path,
        allow_empty_records: true,
        persist_runtime_changes: false
      )

      reload_record_store!()

      assert :ok =
               RecordStore.replace_records([
                 snapshot_record("example.com", "join", "@", "CNAME", proxied: true, ttl: 1)
               ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = RecordStore.persist([])
        end)

      assert log =~ "Persisted DDNS record snapshot to #{snapshot_path}"
      assert File.exists?(snapshot_path)

      snapshot = Jason.decode!(File.read!(snapshot_path))
      assert snapshot["version"] == 1
      assert length(snapshot["records"]) == 1
      assert Enum.sort(File.ls!(dir)) == ["records.json"]
      assert Enum.all?(snapshot["records"], &is_map/1)

      status = RecordStore.status([])
      assert is_binary(status.last_persisted_at)
      assert status.last_error == nil
    end
  end
end

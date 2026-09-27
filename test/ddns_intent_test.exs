defmodule Defdo.DDNS.IntentTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H04: one source of DNS intent
  per cycle, and never an env fallback when the file is broken.
  """
  use ExUnit.Case, async: false

  alias Defdo.Cloudflare.DDNS
  alias Defdo.DDNS.DesiredState
  alias Defdo.DDNS.DesiredStateStore
  alias Defdo.DDNS.Intent

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)

    dir = Path.join(System.tmp_dir!(), "ddns-intent-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "desired_state.json")

    on_exit(fn ->
      File.rm_rf(dir)
      restore(Cloudflare, previous_cloudflare)
      restore(DesiredStateStore, previous_store)
    end)

    Application.delete_env(:defdo_ddns, DesiredStateStore)
    {:ok, state_path: file}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp write_file(file, cloudflare) do
    {:ok, doc} = DesiredState.new(%{"cloudflare" => cloudflare})
    {:ok, binary} = DesiredState.encode(doc)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, binary)
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)
  end

  test "env intent matches records_to_monitor" do
    Application.put_env(:defdo_ddns, Cloudflare,
      domain_mappings: %{"example.com" => ["@", "www", "*.dev", "api.other.org"]}
    )

    intent = Intent.from_env()

    assert Intent.hostnames(intent, "example.com", :a) ==
             DDNS.records_to_monitor("example.com", :domain_mappings)

    assert Intent.hostnames(intent, "unmapped.test", :a) == []
  end

  test "load uses env when the store is disabled" do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"env.example.com" => []})

    assert {:ok, %{"source" => "env"} = intent} = Intent.load()
    assert Intent.domains(intent) == ["env.example.com"]
  end

  test "load uses the file when configured and ignores env", %{state_path: file} do
    Application.put_env(:defdo_ddns, Cloudflare, domain_mappings: %{"env.example.com" => ["www"]})
    write_file(file, %{"domain_mappings" => %{"file.example.com" => ["www"]}})

    assert {:ok, %{"source" => "desired_state"} = intent} = Intent.load()
    assert Intent.domains(intent) == ["file.example.com"]
  end

  test "load fails on a malformed file", %{state_path: file} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{")
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    assert Intent.load() == {:error, :malformed_desired_state}
  end

  test "domains include CNAME-only domains", %{state_path: file} do
    write_file(file, %{
      "cname_records" => [%{"domain" => "cname-only.test", "name" => "app", "target" => "@"}]
    })

    assert {:ok, intent} = Intent.load()
    assert Intent.domains(intent) == ["cname-only.test"]
  end

  test "domains are de-duplicated case-insensitively, mapping spelling wins", %{
    state_path: file
  } do
    write_file(file, %{
      "domain_mappings" => %{"example.com" => ["www"]},
      "cname_records" => [%{"domain" => "Example.com", "name" => "app", "target" => "@"}]
    })

    assert {:ok, intent} = Intent.load()
    assert Intent.domains(intent) == ["example.com"]
    # ...and the CNAME is still synced under the surviving spelling.
    assert [%{"name" => "app.example.com"}] = Intent.cname_records(intent, "example.com")
  end

  test "mixed-case A and AAAA keys are one zone and both sync", %{state_path: file} do
    write_file(file, %{
      "domain_mappings" => %{"example.com" => ["www"]},
      "aaaa_domain_mappings" => %{"Example.com" => ["v6"]}
    })

    assert {:ok, intent} = Intent.load()
    assert Intent.domains(intent) == ["example.com"]
    assert Intent.hostnames(intent, "example.com", :a) == ["example.com", "www.example.com"]
    assert Intent.hostnames(intent, "example.com", :aaaa) == ["example.com", "v6.example.com"]
  end

  test "an unset CNAME proxied follows proxy_a_records at read time", %{state_path: file} do
    cname = %{"domain" => "example.com", "name" => "app", "target" => "@"}
    write_file(file, %{"proxy_a_records" => true, "cname_records" => [cname]})

    assert {:ok, doc} = DesiredStateStore.load()
    # Stored without a baked-in value, so a later policy change still applies.
    refute Map.has_key?(hd(doc["cloudflare"]["cname_records"]), "proxied")
    assert {:ok, intent} = Intent.load()
    assert [%{"proxied" => true, "ttl" => 1}] = Intent.cname_records(intent, "example.com")

    write_file(file, %{"proxy_a_records" => false, "cname_records" => [cname]})
    assert {:ok, intent} = Intent.load()
    assert [%{"proxied" => false, "ttl" => 300}] = Intent.cname_records(intent, "example.com")
  end

  test "file cname entries normalize like store records", %{state_path: file} do
    write_file(file, %{
      "cname_records" => [
        %{
          "domain" => "example.com",
          "name" => "app",
          "target" => "@",
          "proxied" => true,
          "ttl" => 1
        }
      ]
    })

    assert {:ok, intent} = Intent.load()

    assert Intent.cname_records(intent, "example.com") == [
             %{
               "type" => "CNAME",
               "name" => "app.example.com",
               "content" => "example.com",
               "proxied" => true,
               "ttl" => 1
             }
           ]
  end
end

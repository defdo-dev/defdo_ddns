defmodule Defdo.DDNS.DesiredStateStoreTest do
  @moduledoc """
  Acceptance for `ddns-desired-state-file` slice 01.

  The invariant under test is that intent has exactly one home. Environment
  variables seed the file once and then stop mattering; if they kept winning, or
  a re-seed silently overwrote a hand-edited file, two sources of truth would
  exist and drift apart without anything reporting it.
  """
  use ExUnit.Case, async: false

  alias Defdo.DDNS.DesiredState
  alias Defdo.DDNS.DesiredStateStore

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)

    dir = Path.join(System.tmp_dir!(), "ddns-desired-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "desired_state.json")

    on_exit(fn ->
      File.rm_rf(dir)
      restore(Cloudflare, previous_cloudflare)
      restore(DesiredStateStore, previous_store)
    end)

    {:ok, state_path: file, state_dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp enable(file), do: Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

  defp put_env_config do
    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      domain_mappings: %{"defdo.ninja" => ["api", "www"]},
      aaaa_domain_mappings: %{"defdo.ninja" => ["api"]},
      cname_records: [
        %{"domain" => "defdo.ninja", "name" => "docs", "target" => "@", "proxied" => true}
      ],
      proxy_a_records: true,
      auto_create_missing_records: true,
      proxy_exclude: ["internal.defdo.ninja"]
    )
  end

  describe "disabled" do
    test "reports disabled and reads nothing when no path is configured" do
      Application.delete_env(:defdo_ddns, DesiredStateStore)
      System.delete_env("DDNS_DESIRED_STATE_PATH")

      refute DesiredStateStore.enabled?()
      assert {:error, :disabled} = DesiredStateStore.load()
      assert {:error, :disabled} = DesiredStateStore.seed()
      assert %{"state" => "disabled"} = DesiredStateStore.status()
    end
  end

  describe "seeding" do
    test "writes the file from the environment on first boot", %{state_path: file} do
      enable(file)
      put_env_config()

      assert {:ok, doc} = DesiredStateStore.seed()
      assert File.exists?(file)

      cf = doc["cloudflare"]
      assert cf["domain_mappings"] == %{"defdo.ninja" => ["api", "www"]}
      assert cf["aaaa_domain_mappings"] == %{"defdo.ninja" => ["api"]}
      assert [%{"name" => "docs", "target" => "@", "proxied" => true}] = cf["cname_records"]
      assert cf["proxy_a_records"] == true
      assert cf["auto_create_missing_records"] == true
      assert cf["proxy_exclude"] == ["internal.defdo.ninja"]
      assert doc["version"] == DesiredState.version()
    end

    test "the file wins once written, even after the environment changes", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      # The env is where intent used to live; after seeding it must not matter.
      Application.put_env(:defdo_ddns, Cloudflare,
        auth_token: "test-token",
        domain_mappings: %{"somewhere-else.test" => ["nope"]}
      )

      assert {:ok, doc} = DesiredStateStore.load()
      assert Map.keys(doc["cloudflare"]["domain_mappings"]) == ["defdo.ninja"]
    end

    test "refuses to re-seed over an existing file", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      assert {:error, :already_seeded} = DesiredStateStore.seed()
    end

    test "force re-seeds deliberately", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      Application.put_env(:defdo_ddns, Cloudflare,
        auth_token: "test-token",
        domain_mappings: %{"new.test" => ["a"]}
      )

      assert {:ok, doc} = DesiredStateStore.seed(force: true)
      assert Map.keys(doc["cloudflare"]["domain_mappings"]) == ["new.test"]
    end
  end

  describe "missing file" do
    test "is a loud error, never an empty document", %{state_path: file} do
      enable(file)

      assert {:error, :missing_desired_state} = DesiredStateStore.load()
      assert %{"state" => "error"} = DesiredStateStore.status()
    end

    test "a malformed file is rejected rather than treated as empty", %{
      state_path: file,
      state_dir: dir
    } do
      enable(file)
      File.mkdir_p!(dir)
      File.write!(file, "not json at all")

      assert {:error, :malformed_desired_state} = DesiredStateStore.load()
    end

    test "a future version is refused instead of silently downgraded", %{
      state_path: file,
      state_dir: dir
    } do
      enable(file)
      File.mkdir_p!(dir)
      File.write!(file, Jason.encode!(%{"version" => 99, "cloudflare" => %{}}))

      assert {:error, {:unsupported_version, 99}} = DesiredStateStore.load()
    end
  end

  describe "mutation" do
    test "update/1 round-trips through the file", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      assert {:ok, _} =
               DesiredStateStore.update(fn doc ->
                 update_in(doc, ["cloudflare", "cname_records"], fn records ->
                   records ++
                     [
                       %{
                         "domain" => "defdo.ninja",
                         "name" => "foss",
                         "target" => "@",
                         "proxied" => true
                       }
                     ]
                 end)
               end)

      assert {:ok, doc} = DesiredStateStore.load()
      names = doc["cloudflare"]["cname_records"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["docs", "foss"]
    end

    test "writes leave no temp file behind", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      refute File.exists?(file <> ".tmp")
    end

    test "ordering is deterministic so the file diffs cleanly", %{state_path: file} do
      enable(file)

      Application.put_env(:defdo_ddns, Cloudflare,
        auth_token: "t",
        cname_records: [
          %{"domain" => "defdo.ninja", "name" => "zeta", "target" => "@"},
          %{"domain" => "defdo.ninja", "name" => "alpha", "target" => "@"}
        ]
      )

      assert {:ok, doc} = DesiredStateStore.seed()
      assert Enum.map(doc["cloudflare"]["cname_records"], & &1["name"]) == ["alpha", "zeta"]
    end
  end

  describe "diagnostics" do
    test "status reports counts and never raw payloads", %{state_path: file} do
      enable(file)
      put_env_config()
      assert {:ok, _} = DesiredStateStore.seed()

      status = DesiredStateStore.status()

      assert status["state"] == "loaded"
      assert status["domains"] == 1
      assert status["a_hostnames"] == 2
      assert status["aaaa_hostnames"] == 1
      assert status["cname_records"] == 1

      # No hostname, target or flag value may appear anywhere in the output.
      rendered = inspect(status)
      refute rendered =~ "api"
      refute rendered =~ "docs"
      refute rendered =~ "internal.defdo.ninja"
    end
  end
end

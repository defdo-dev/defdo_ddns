defmodule Defdo.DDNS.API.AuthStoreTest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.DDNS
  alias Defdo.DDNS.API.AuthStore

  setup do
    previous_api_config = Application.get_env(:defdo_ddns, Defdo.DDNS.API)
    Application.put_env(:defdo_ddns, Defdo.DDNS.API, clients: [])
    start_supervised!(AuthStore)

    on_exit(fn ->
      if is_nil(previous_api_config) do
        Application.delete_env(:defdo_ddns, Defdo.DDNS.API)
      else
        Application.put_env(:defdo_ddns, Defdo.DDNS.API, previous_api_config)
      end
    end)

    :ok
  end

  test "set_api_clients/1 replaces client credentials in memory" do
    clients = [
      %{
        "id" => "tenant-a",
        "token" => "tenant-secret",
        "allowed_base_domains" => ["example.com", "example.org"]
      }
    ]

    assert :ok = DDNS.set_api_clients(clients)

    assert %{
             "tenant-a" => %{
               id: "tenant-a",
               token: "[REDACTED]",
               allowed_base_domains: ["example.com", "example.org"]
             }
           } = DDNS.api_clients()

    assert %{
             "tenant-a" => %{
               id: "tenant-a",
               token: "tenant-secret",
               allowed_base_domains: ["example.com", "example.org"]
             }
           } = DDNS.api_clients(redact: false)
  end

  test "clear_api_clients/0 removes runtime credentials" do
    assert :ok =
             DDNS.set_api_clients([
               %{
                 "id" => "tenant-a",
                 "token" => "tenant-secret",
                 "allowed_base_domains" => ["example.com"]
               }
             ])

    assert :ok = DDNS.clear_api_clients()
    assert DDNS.api_clients() == %{}
  end

  test "set_api_clients/1 rejects invalid clients payload" do
    assert {:error, {:invalid_clients, _reason}} =
             DDNS.set_api_clients([%{"id" => "tenant-a"}])
  end

  test "auth ETS table blocks external writes" do
    assert_raise ArgumentError, fn ->
      :ets.insert(:defdo_ddns_api_clients, {"tenant-x", %{id: "tenant-x"}})
    end
  end
end

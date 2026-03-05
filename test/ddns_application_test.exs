defmodule Defdo.DDNS.ApplicationTest do
  @moduledoc false
  use ExUnit.Case

  alias Defdo.DDNS.Application, as: DDNSApplication

  test "validate_api_config!/1 allows disabled API without token" do
    assert :ok = DDNSApplication.validate_api_config!(enabled: false, token: nil)
  end

  test "validate_api_config!/1 allows enabled API with token" do
    assert :ok = DDNSApplication.validate_api_config!(enabled: true, token: "secret")
  end

  test "validate_api_config!/1 allows enabled API with clients config" do
    clients = [
      %{
        "id" => "tenant-a",
        "token" => "tenant-secret",
        "allowed_base_domains" => ["example.com"]
      }
    ]

    assert :ok = DDNSApplication.validate_api_config!(enabled: true, token: nil, clients: clients)
  end

  test "validate_api_config!/1 allows runtime client injection mode" do
    assert :ok =
             DDNSApplication.validate_api_config!(
               enabled: true,
               token: nil,
               clients: [],
               allow_runtime_clients: true
             )
  end

  test "validate_api_config!/1 raises when API enabled and no token/clients" do
    assert_raise ArgumentError,
                 ~r/DDNS_API_TOKEN or DDNS_API_CLIENTS_JSON must be configured/,
                 fn ->
                   DDNSApplication.validate_api_config!(enabled: true, token: nil)
                 end
  end

  test "validate_api_config!/1 raises when API enabled and token blank" do
    assert_raise ArgumentError,
                 ~r/DDNS_API_TOKEN or DDNS_API_CLIENTS_JSON must be configured/,
                 fn ->
                   DDNSApplication.validate_api_config!(enabled: true, token: "   ")
                 end
  end

  test "validate_api_config!/1 raises when clients config is invalid" do
    invalid_clients = [%{"id" => "tenant-a", "allowed_base_domains" => ["example.com"]}]

    assert_raise ArgumentError, ~r/DDNS_API_CLIENTS_JSON invalid/, fn ->
      DDNSApplication.validate_api_config!(enabled: true, token: nil, clients: invalid_clients)
    end
  end
end

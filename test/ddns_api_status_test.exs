defmodule Defdo.DDNS.APIStatusTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H08: `/ready` is an
  unauthenticated probe with reason codes only; `/v1/status` is operator-only.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Defdo.DDNS.API.Router

  setup do
    keys = [Defdo.DDNS.API, :monitor_enabled, Defdo.DDNS.DesiredStateStore]
    previous = Map.new(keys, &{&1, Application.get_env(:defdo_ddns, &1)})

    Application.delete_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "secret",
      clients: [
        %{"id" => "tenant-a", "token" => "tenant-secret", "allowed_base_domains" => ["a.test"]}
      ]
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:defdo_ddns, key)
        {key, value} -> Application.put_env(:defdo_ddns, key, value)
      end)
    end)

    :ok
  end

  defp get(path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> Router.call([])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "GET /ready is 200 when ready" do
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    conn = get("/ready")

    assert conn.status == 200
    assert body(conn) == %{"status" => "ready"}
  end

  test "GET /ready is 503 with reasons" do
    Application.put_env(:defdo_ddns, :monitor_enabled, true)
    conn = get("/ready")

    assert conn.status == 503
    assert body(conn) == %{"status" => "not_ready", "reasons" => ["monitor_not_running"]}
  end

  test "GET /ready needs no token" do
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    assert get("/ready").status == 200
  end

  test "GET /v1/status requires a token" do
    assert get("/v1/status").status == 401
  end

  test "GET /v1/status forbids client tokens" do
    conn =
      get("/v1/status", [
        {"x-client-id", "tenant-a"},
        {"authorization", "Bearer tenant-secret"}
      ])

    assert conn.status == 403
    assert body(conn)["error"] == "forbidden"
  end

  test "GET /v1/status with the operator token" do
    conn = get("/v1/status", [{"authorization", "Bearer secret"}])

    assert conn.status == 200

    assert body(conn) |> Map.keys() |> Enum.sort() ==
             ~w(adoption desired_state monitor ready reasons record_store status)
  end
end

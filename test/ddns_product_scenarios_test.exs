defmodule Defdo.DDNS.ProductScenariosTest do
  @moduledoc """
  Product check for `ddns-service-hardening` phase 2 (slice H11): the
  scenarios in product.md, walked the way the operator and K3s do them — over
  real HTTP against a running Bandit server. The probe side is a raw
  `:gen_tcp` client: `Req.default_options(plug: ...)` would route Req calls
  into the Cloudflare stub instead of the server, and `:inets` is not in this
  app's code path.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.Monitor

  @ip "203.0.113.7"

  setup do
    keys = [
      Cloudflare,
      Defdo.DDNS.API,
      Defdo.DDNS.Heartbeat,
      Defdo.DDNS.DesiredStateStore,
      :cloudflare_req_options,
      :monitor_enabled
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:defdo_ddns, &1)})

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)
    Application.put_env(:defdo_ddns, :monitor_enabled, true)
    Application.delete_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)
    Application.put_env(:defdo_ddns, Defdo.DDNS.Heartbeat, url: nil)

    Application.put_env(:defdo_ddns, Defdo.DDNS.API,
      token: "operator-secret",
      clients: [
        %{"id" => "tenant-a", "token" => "tenant-secret", "allowed_base_domains" => ["a.test"]}
      ]
    )

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      ipv4_lookup_urls: ["https://ip.test"],
      domain_mappings: %{"example.com" => ["www"]},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    {:ok, behaviour} = Agent.start_link(fn -> %{zones: :ok} end)
    {:ok, pings} = Agent.start_link(fn -> 0 end)
    stub(behaviour, pings)

    port = free_port()

    start_supervised!(
      {Bandit, plug: Defdo.DDNS.API.Router, scheme: :http, ip: {127, 0, 0, 1}, port: port}
    )

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:defdo_ddns, key)
        {key, value} -> Application.put_env(:defdo_ddns, key, value)
      end)
    end)

    {:ok, port: port, behaviour: behaviour, pings: pings}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Minimal HTTP/1.1 client over :gen_tcp (kernel only — :inets is not in this
  # app's code path, and Req calls are routed into the Cloudflare stub).
  defp http_get(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    extra = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n#{extra}\r\n"
      )

    response = recv_all(socket, "")
    :gen_tcp.close(socket)

    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1", status | _] = head |> String.split("\r\n") |> hd() |> String.split(" ")
    {String.to_integer(status), Jason.decode!(body)}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp set(behaviour, key, value), do: Agent.update(behaviour, &Map.put(&1, key, value))

  defp stub(behaviour, pings) do
    Req.Test.stub(__MODULE__, fn conn ->
      b = Agent.get(behaviour, & &1)

      cond do
        conn.host == "status.test" ->
          Agent.update(pings, &(&1 + 1))
          Plug.Conn.resp(conn, 200, "ok")

        conn.host == "ip.test" ->
          Plug.Conn.resp(conn, 200, @ip)

        conn.request_path == "/client/v4/zones" and b.zones == :expired ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            403,
            Jason.encode!(%{"success" => false, "errors" => [%{"code" => 9109}]})
          )

        conn.request_path == "/client/v4/zones" ->
          Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "z1"}]})

        String.ends_with?(conn.request_path, "/settings/ssl") ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"value" => "strict"}})

        true ->
          records =
            for name <- ["example.com", "www.example.com"] do
              %{
                "id" => name,
                "type" => "A",
                "name" => name,
                "content" => @ip,
                "proxied" => false,
                "ttl" => 300
              }
            end

          Req.Test.json(conn, %{"success" => true, "result" => records})
      end
    end)
  end

  defp start_monitor do
    capture_log(fn -> start_supervised!({Monitor, refetch_every: :timer.hours(1)}) end)
  end

  defp checkup, do: capture_log(fn -> Monitor.checkup() end)

  test "P-01 a converging DDNS is ready", %{port: port} do
    start_monitor()
    checkup()

    assert http_get(port, "/ready") == {200, %{"status" => "ready"}}
  end

  test "P-01 an expired token makes DDNS not ready, not dead", %{port: port, behaviour: b} do
    set(b, :zones, :expired)
    start_monitor()
    checkup()
    checkup()

    assert {503, %{"status" => "not_ready", "reasons" => reasons}} = http_get(port, "/ready")
    assert "consecutive_failures" in reasons
    assert http_get(port, "/health") == {200, %{"status" => "ok"}}
  end

  test "P-02 one command answers what DDNS is doing", %{port: port} do
    start_monitor()
    checkup()

    assert {200, body} =
             http_get(port, "/v1/status", [{"authorization", "Bearer operator-secret"}])

    assert body["monitor"]["outcome"] == "ok"
    assert body["ready"] == true
    assert is_integer(body["adoption"]["pending"])
    refute Jason.encode!(body) =~ "example.com"
  end

  test "P-02 a tenant client cannot read status", %{port: port} do
    assert {403, %{"error" => "forbidden"}} =
             http_get(port, "/v1/status", [
               {"x-client-id", "tenant-a"},
               {"authorization", "Bearer tenant-secret"}
             ])
  end

  test "P-03 silence when failing, a ping when converging again", %{
    behaviour: b,
    pings: pings
  } do
    Application.put_env(:defdo_ddns, Defdo.DDNS.Heartbeat, url: "https://status.test/ping/T")
    set(b, :zones, :expired)
    start_monitor()
    checkup()

    assert Agent.get(pings, & &1) == 0

    set(b, :zones, :ok)
    checkup()

    assert Agent.get(pings, & &1) == 1
  end

  test "P-04 cycle and request events exist" do
    handler = "p04-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [[:defdo_ddns, :cycle, :stop], [:defdo_ddns, :http, :request, :stop]],
      fn event, _m, _meta, _ -> send(test_pid, {:event, event}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_monitor()
    checkup()

    assert_received {:event, [:defdo_ddns, :cycle, :stop]}
    assert_received {:event, [:defdo_ddns, :http, :request, :stop]}
  end
end

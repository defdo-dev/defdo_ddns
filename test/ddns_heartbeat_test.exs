defmodule Defdo.DDNS.HeartbeatTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H10: ping after ok/degraded
  cycles, silence after failed ones, never raise, never log the URL.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.Heartbeat

  @ip "203.0.113.7"
  @url "https://status.test/ping/SECRET-TOKEN-123"

  setup do
    keys = [Cloudflare, Heartbeat, Defdo.DDNS.DesiredStateStore, :cloudflare_req_options]
    previous = Map.new(keys, &{&1, Application.get_env(:defdo_ddns, &1)})

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)
    Application.delete_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)
    Application.put_env(:defdo_ddns, Heartbeat, url: @url, timeout_ms: 500)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      ipv4_lookup_urls: ["https://ip.test"],
      domain_mappings: %{"example.com" => ["www"]},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    {:ok, pings} = Agent.start_link(fn -> 0 end)
    {:ok, behaviour} = Agent.start_link(fn -> %{zones: :ok, heartbeat: :ok} end)
    stub(pings, behaviour)

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:defdo_ddns, key)
        {key, value} -> Application.put_env(:defdo_ddns, key, value)
      end)
    end)

    {:ok, pings: pings, behaviour: behaviour}
  end

  defp set(behaviour, key, value), do: Agent.update(behaviour, &Map.put(&1, key, value))
  defp pings(agent), do: Agent.get(agent, & &1)

  defp stub(pings, behaviour) do
    Req.Test.stub(__MODULE__, fn conn ->
      b = Agent.get(behaviour, & &1)

      cond do
        conn.host == "status.test" ->
          Agent.update(pings, &(&1 + 1))
          heartbeat_response(conn, b.heartbeat)

        conn.host == "ip.test" ->
          Plug.Conn.resp(conn, 200, @ip)

        conn.request_path == "/client/v4/zones" ->
          if b.zones == :ok,
            do: Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "z1"}]}),
            else: Plug.Conn.resp(conn, 521, "error code: 521")

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

  defp heartbeat_response(conn, :ok), do: Plug.Conn.resp(conn, 200, "ok")
  defp heartbeat_response(conn, :status_500), do: Plug.Conn.resp(conn, 500, "boom")
  defp heartbeat_response(conn, :timeout), do: Req.Test.transport_error(conn, :timeout)
  defp heartbeat_response(conn, :refused), do: Req.Test.transport_error(conn, :econnrefused)

  defp start_monitor do
    capture_log(fn -> start_supervised!({Monitor, refetch_every: :timer.hours(1)}) end)
  end

  defp checkup, do: capture_log(fn -> Monitor.checkup() end)

  test "ok cycle pings once", %{pings: pings} do
    start_monitor()
    # checkup/0 is served after the boot cycle, so both cycles have finished.
    checkup()

    assert pings(pings) == 2
  end

  test "failed cycle sends nothing", %{pings: pings, behaviour: b} do
    set(b, :zones, :error)
    start_monitor()
    checkup()

    assert pings(pings) == 0
    assert {:ok, %{"outcome" => "failed"}} = Monitor.status()
  end

  test "degraded pings unless disabled", %{pings: pings} do
    assert Heartbeat.ping("degraded") == :ok
    assert pings(pings) == 1

    Application.put_env(:defdo_ddns, Heartbeat, url: @url, send_on_degraded: false)
    assert Heartbeat.ping("degraded") == :ok
    assert pings(pings) == 1
  end

  test "no URL, no request", %{pings: pings} do
    Application.put_env(:defdo_ddns, Heartbeat, url: nil)

    refute Heartbeat.enabled?()
    assert Heartbeat.ping("ok") == :ok
    assert pings(pings) == 0
  end

  test "endpoint 500, timeout and transport error never raise", %{behaviour: b} do
    start_monitor()

    for failure <- [:status_500, :timeout, :refused] do
      set(b, :heartbeat, failure)
      capture_log(fn -> assert Heartbeat.ping("ok") == :ok end)
      checkup()
      assert Process.whereis(Monitor)
    end
  end

  test "the token never reaches the log", %{behaviour: b} do
    log =
      capture_log(fn ->
        for failure <- [:status_500, :timeout, :refused] do
          set(b, :heartbeat, failure)
          Heartbeat.ping("ok")
        end
      end)

    assert log =~ "DDNS heartbeat"
    refute log =~ "SECRET-TOKEN-123"
    refute log =~ "status.test/ping"
  end

  test "checkup_once never pings", %{pings: pings} do
    capture_log(fn -> Monitor.checkup_once() end)
    assert pings(pings) == 0
  end
end

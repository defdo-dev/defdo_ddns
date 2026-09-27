defmodule Defdo.DDNS.TelemetryTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H09: span events for cycles
  and outbound HTTP, with no hostnames, URLs or addresses in metadata.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.DDNS
  alias Defdo.Cloudflare.Monitor

  @ip "203.0.113.7"
  @events [
    [:defdo_ddns, :http, :request, :stop],
    [:defdo_ddns, :cycle, :stop]
  ]

  setup do
    keys = [Cloudflare, Defdo.DDNS.DesiredStateStore, :cloudflare_req_options]
    previous = Map.new(keys, &{&1, Application.get_env(:defdo_ddns, &1)})

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)
    Application.delete_env(:defdo_ddns, Defdo.DDNS.DesiredStateStore)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      ipv4_lookup_urls: ["https://ip.test"],
      domain_mappings: %{"example.com" => ["www"]},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    handler = "telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      @events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Req.default_options([])
      Req.Test.set_req_test_to_private()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:defdo_ddns, key)
        {key, value} -> Application.put_env(:defdo_ddns, key, value)
      end)
    end)

    :ok
  end

  defp healthy_stub do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        conn.host == "ip.test" ->
          Plug.Conn.resp(conn, 200, @ip)

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

  defp drain(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain([{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp http_stops, do: for({[_, :http, _, :stop], m, meta} <- drain(), do: {m, meta})

  test "http request stop event per Cloudflare call" do
    healthy_stub()
    assert DDNS.get_zone_id("example.com") == "z1"

    assert [{measurements, meta}] = http_stops()
    assert meta.service == :cloudflare
    assert meta.operation == "get_zone_id"
    assert meta.result == :ok
    assert meta.status == 200
    assert is_integer(measurements.duration)
  end

  test "error result on 521 and on transport error" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.resp(conn, 521, "error code: 521") end)
    capture_log(fn -> DDNS.get_zone_id("example.com") end)
    assert [{_, %{result: :error, status: 521}}] = http_stops()

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    capture_log(fn -> DDNS.get_zone_id("example.com") end)
    assert [{_, %{result: :error, status: nil}}] = http_stops()
  end

  test "one event per listing page" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      page = String.to_integer(conn.query_params["page"])

      Req.Test.json(conn, %{
        "success" => true,
        "result" => [%{"id" => "r#{page}"}],
        "result_info" => %{"page" => page, "total_pages" => 2}
      })
    end)

    assert {:ok, _} = DDNS.fetch_dns_records("z1")

    assert [_, _] =
             for({_, %{operation: "list_dns_records"}} = e <- http_stops(), do: e)
  end

  test "cycle stop event" do
    healthy_stub()
    capture_log(fn -> start_supervised!({Monitor, refetch_every: :timer.hours(1)}) end)
    capture_log(fn -> Monitor.checkup() end)

    cycles = for {[_, :cycle, :stop], m, meta} <- drain(), do: {m, meta}
    assert [{measurements, meta} | _] = cycles
    assert is_integer(measurements.duration)
    assert meta.outcome == "ok"
    assert meta.domains == 1
    assert meta.consecutive_failures == 0
  end

  test "checkup_once emits no cycle event" do
    healthy_stub()
    capture_log(fn -> Monitor.checkup_once() end)

    assert for({[_, :cycle, :stop], _, _} = e <- drain(), do: e) == []
  end

  test "metadata carries no hostnames or URLs" do
    healthy_stub()
    capture_log(fn -> start_supervised!({Monitor, refetch_every: :timer.hours(1)}) end)
    capture_log(fn -> Monitor.checkup() end)

    events = drain()
    # Guard against a vacuous pass: a cycle plus its HTTP calls must be here.
    assert Enum.any?(events, &match?({[_, :cycle, :stop], _, _}, &1))
    assert Enum.count(events, &match?({[_, :http, _, :stop], _, _}, &1)) >= 4

    metadata = events |> Enum.map(&elem(&1, 2)) |> inspect()

    refute metadata =~ "example.com"
    refute metadata =~ "https://"
    refute metadata =~ "203.0.113."
  end
end

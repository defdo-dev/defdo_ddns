defmodule Defdo.DDNS.MonitorCycleTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H05: one listing per zone,
  no auto-create after a failed listing, and a non-blocking cycle status.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.DesiredStateStore

  @ip "203.0.113.7"

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)
    previous_req = Application.get_env(:defdo_ddns, :cloudflare_req_options)

    Req.default_options(plug: {Req.Test, __MODULE__})
    # The monitor makes its calls from its own process; stubs owned by the test
    # process are invisible there unless the stub is shared.
    Req.Test.set_req_test_to_shared()
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)
    Application.delete_env(:defdo_ddns, DesiredStateStore)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      ipv4_lookup_urls: ["https://ip.test"],
      domain_mappings: %{"example.com" => ["www", "api"]},
      aaaa_domain_mappings: %{},
      cname_records: [],
      auto_create_missing_records: true,
      proxy_a_records: false
    )

    {:ok, requests} = Agent.start_link(fn -> [] end)
    {:ok, behaviour} = Agent.start_link(fn -> %{zones: :ok, listing: [], delay: 0} end)

    stub(requests, behaviour)

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
      restore(Cloudflare, previous_cloudflare)
      restore(DesiredStateStore, previous_store)
      restore(:cloudflare_req_options, previous_req)
    end)

    {:ok, requests: requests, behaviour: behaviour}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp set(behaviour, key, value), do: Agent.update(behaviour, &Map.put(&1, key, value))

  defp edge_error(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.resp(521, "error code: 521\n")
  end

  defp stub(requests, behaviour) do
    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(requests, &[{conn.method, conn.request_path || "/"} | &1])
      b = Agent.get(behaviour, & &1)

      cond do
        conn.host == "ip.test" ->
          Plug.Conn.resp(conn, 200, @ip)

        conn.request_path == "/client/v4/zones" ->
          Process.sleep(b.delay)

          if b.zones == :ok,
            do: Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "z1"}]}),
            else: edge_error(conn)

        String.ends_with?(conn.request_path, "/settings/ssl") ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"value" => "strict"}})

        conn.method in ["PUT", "POST"] ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          Req.Test.json(conn, %{"success" => true, "result" => Jason.decode!(raw)})

        b.listing == :error ->
          edge_error(conn)

        true ->
          Req.Test.json(conn, %{"success" => true, "result" => b.listing})
      end
    end)
  end

  defp a_record(name, content) do
    %{
      "id" => "id-#{name}",
      "type" => "A",
      "name" => name,
      "content" => content,
      "proxied" => false,
      "ttl" => 300
    }
  end

  defp count(requests, method, suffix) do
    requests
    |> Agent.get(& &1)
    |> Enum.count(fn {m, path} -> m == method and String.ends_with?(path, suffix) end)
  end

  defp in_sync, do: Enum.map(~w(example.com www.example.com api.example.com), &a_record(&1, @ip))

  test "one listing per zone when nothing changes", %{requests: r, behaviour: b} do
    set(b, :listing, in_sync())

    capture_log(fn -> Monitor.checkup_once() end)

    assert count(r, "GET", "/dns_records") == 1
    assert count(r, "PUT", "") == 0
  end

  test "one re-read after a write", %{requests: r, behaviour: b} do
    set(b, :listing, [
      a_record("example.com", @ip),
      a_record("www.example.com", @ip),
      a_record("api.example.com", "198.51.100.1")
    ])

    capture_log(fn -> Monitor.checkup_once() end)

    assert count(r, "PUT", "") == 1
    assert count(r, "GET", "/dns_records") == 2
  end

  test "a failed listing never auto-creates", %{requests: r, behaviour: b} do
    set(b, :listing, :error)

    capture_log(fn ->
      assert [[message]] = Monitor.checkup_once()

      assert String.starts_with?(
               message,
               "Error - unable to list DNS records for domain=example.com"
             )
    end)

    assert count(r, "POST", "") == 0
  end

  test "status reports the last cycle", %{behaviour: b} do
    set(b, :listing, in_sync())

    capture_log(fn ->
      start_supervised!({Monitor, refetch_every: :timer.hours(1)})
      Monitor.checkup()
    end)

    assert {:ok, status} = Monitor.status()
    assert status["outcome"] == "ok"
    assert status["consecutive_failures"] == 0
    assert is_binary(status["last_success_at"])
    assert is_integer(status["duration_ms"])
    assert status["domains"] == 1
    assert Defdo.DDNS.monitor_status() == {:ok, status}
  end

  test "consecutive failures count and reset", %{behaviour: b} do
    set(b, :listing, in_sync())
    set(b, :zones, :error)

    capture_log(fn ->
      start_supervised!({Monitor, refetch_every: :timer.hours(1)})
      Monitor.checkup()
      Monitor.checkup()
    end)

    assert {:ok, %{"outcome" => "failed", "consecutive_failures" => 3}} = Monitor.status()
    # Zones failed but the domain was processed: it counts.
    assert {:ok, %{"domains" => 1}} = Monitor.status()

    set(b, :zones, :ok)
    capture_log(fn -> Monitor.checkup() end)

    assert {:ok, %{"outcome" => "ok", "consecutive_failures" => 0}} = Monitor.status()
  end

  test "status answers while a cycle is running", %{behaviour: b} do
    set(b, :listing, in_sync())

    capture_log(fn ->
      start_supervised!({Monitor, refetch_every: :timer.hours(1)})
      Monitor.checkup()
    end)

    set(b, :delay, 500)
    task = Task.async(fn -> capture_log(fn -> Monitor.checkup() end) end)
    Process.sleep(50)

    {micros, result} = :timer.tc(&Monitor.status/0)
    assert {:ok, _status} = result
    assert micros < 50_000

    Task.await(task, 5_000)
  end

  test "a cycle that never reaches a domain reports zero domains" do
    dir = Path.join(System.tmp_dir!(), "ddns-cycle-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "desired_state.json")
    File.mkdir_p!(dir)
    File.write!(file, "{")
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)
    on_exit(fn -> File.rm_rf(dir) end)

    capture_log(fn ->
      start_supervised!({Monitor, refetch_every: :timer.hours(1)})
      Monitor.checkup()
    end)

    assert {:ok, %{"outcome" => "failed", "domains" => 0}} = Monitor.status()
  end

  test "status without a monitor" do
    refute Process.whereis(Monitor)
    assert Monitor.status() == {:error, :not_running}
  end

  test "checkup accepts a timeout" do
    Code.ensure_loaded!(Monitor)
    assert function_exported?(Monitor, :checkup, 1)
  end
end

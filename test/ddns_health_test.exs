defmodule Defdo.DDNS.HealthTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H08: readiness reasons and a
  status report that carries no hostnames or addresses.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.DesiredState
  alias Defdo.DDNS.DesiredStateStore
  alias Defdo.DDNS.Health

  @ip "203.0.113.7"

  setup do
    keys = [Cloudflare, DesiredStateStore, Health, :cloudflare_req_options, :monitor_enabled]
    previous = Map.new(keys, &{&1, Application.get_env(:defdo_ddns, &1)})

    dir = Path.join(System.tmp_dir!(), "ddns-health-#{System.unique_integer([:positive])}")

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)
    Application.put_env(:defdo_ddns, :monitor_enabled, true)
    Application.delete_env(:defdo_ddns, DesiredStateStore)
    Application.delete_env(:defdo_ddns, Health)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      ipv4_lookup_urls: ["https://ip.test"],
      domain_mappings: %{"example.com" => ["www"]},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    {:ok, behaviour} = Agent.start_link(fn -> %{zones: :ok, delay: 0} end)
    stub(behaviour)

    on_exit(fn ->
      Req.default_options([])
      Req.Test.set_req_test_to_private()
      File.rm_rf(dir)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:defdo_ddns, key)
        {key, value} -> Application.put_env(:defdo_ddns, key, value)
      end)
    end)

    {:ok, behaviour: behaviour, dir: dir}
  end

  defp set(behaviour, key, value), do: Agent.update(behaviour, &Map.put(&1, key, value))

  defp stub(behaviour) do
    Req.Test.stub(__MODULE__, fn conn ->
      b = Agent.get(behaviour, & &1)

      cond do
        conn.host == "ip.test" ->
          Plug.Conn.resp(conn, 200, @ip)

        conn.request_path == "/client/v4/zones" ->
          Process.sleep(b.delay)

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

  defp start_monitor(refetch_every \\ :timer.hours(1)) do
    capture_log(fn -> start_supervised!({Monitor, refetch_every: refetch_every}) end)
  end

  defp checkup, do: capture_log(fn -> Monitor.checkup() end)

  defp reasons(now \\ DateTime.utc_now()), do: now |> Health.readiness() |> elem(1)

  test "ready when the monitor is disabled and intent loads" do
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    assert Health.readiness() == {:ready, []}
  end

  test "monitor enabled but not running" do
    assert "monitor_not_running" in reasons()
  end

  test "starting before the first cycle", %{behaviour: b} do
    set(b, :delay, 300)
    start_supervised!({Monitor, refetch_every: :timer.hours(1)})
    Process.sleep(50)

    assert "starting" in reasons()
    capture_log(fn -> Process.sleep(400) end)
  end

  test "consecutive failures threshold", %{behaviour: b} do
    set(b, :zones, :error)
    start_monitor()
    checkup()
    checkup()

    assert "consecutive_failures" in reasons()

    Application.put_env(:defdo_ddns, Health, max_consecutive_failures: 10)
    refute "consecutive_failures" in reasons()
  end

  test "stale last success" do
    start_monitor(1_000)
    checkup()

    assert "stale" in reasons(DateTime.add(DateTime.utc_now(), 10, :second))
    refute "stale" in reasons(DateTime.utc_now())
  end

  test "ready after a successful cycle" do
    start_monitor()
    checkup()

    assert Health.readiness() == {:ready, []}
  end

  test "broken desired-state file", %{dir: dir} do
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    file = Path.join(dir, "desired_state.json")
    File.mkdir_p!(dir)
    File.write!(file, "{")
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    assert reasons() == ["desired_state_unavailable"]
  end

  test "readiness never writes the desired-state file", %{dir: dir} do
    # Missing file + seedable env: load/0 would seed it; a probe must not.
    Application.put_env(:defdo_ddns, :monitor_enabled, false)
    file = Path.join(dir, "desired_state.json")
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    assert Health.readiness() == {:ready, []}
    assert %{"desired_state" => %{"state" => "pending_seed"}} = Health.report()
    refute File.exists?(file)
  end

  test "report carries no hostnames or addresses", %{dir: dir} do
    file = Path.join(dir, "desired_state.json")
    File.mkdir_p!(dir)

    {:ok, doc} =
      DesiredState.new(%{
        "cloudflare" => %{
          "domain_mappings" => %{"example.com" => ["www"]},
          "cname_records" => [
            %{"domain" => "example.com", "name" => "secret-host", "target" => "@"}
          ]
        }
      })

    {:ok, binary} = DesiredState.encode(doc)
    File.write!(file, binary)
    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    start_monitor()
    checkup()

    encoded = Jason.encode!(Health.report())
    refute encoded =~ "example.com"
    refute encoded =~ "secret-host"
    refute encoded =~ "203.0.113."
  end
end

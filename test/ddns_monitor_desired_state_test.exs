defmodule Defdo.DDNS.MonitorDesiredStateTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H04, end to end: what the
  desired-state file declares is what the monitor converges and what the
  inventory counts as managed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.DesiredState
  alias Defdo.DDNS.DesiredStateStore
  alias Defdo.DDNS.Reconcile.Inventory

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)
    previous_req = Application.get_env(:defdo_ddns, :cloudflare_req_options)

    dir = Path.join(System.tmp_dir!(), "ddns-monitor-ds-#{System.unique_integer([:positive])}")
    file = Path.join(dir, "desired_state.json")

    Req.default_options(plug: {Req.Test, __MODULE__})
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)

    Application.put_env(:defdo_ddns, Cloudflare,
      auth_token: "test-token",
      domain_mappings: %{},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    Application.put_env(:defdo_ddns, DesiredStateStore, path: file)

    {:ok, requests} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Req.default_options([])
      File.rm_rf(dir)
      restore(Cloudflare, previous_cloudflare)
      restore(DesiredStateStore, previous_store)
      restore(:cloudflare_req_options, previous_req)
    end)

    {:ok, state_path: file, requests: requests}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp write_file(file, cloudflare) do
    {:ok, doc} = DesiredState.new(%{"cloudflare" => cloudflare})
    {:ok, binary} = DesiredState.encode(doc)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, binary)
  end

  defp stub_cloudflare(requests, live_records) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      Agent.update(requests, &[{conn.method, conn.request_path, body} | &1])
      posted? = Agent.get(requests, fn log -> Enum.any?(log, &(elem(&1, 0) == "POST")) end)

      cond do
        conn.request_path == "/client/v4/zones" ->
          Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "z1"}]})

        String.ends_with?(conn.request_path, "/settings/ssl") ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"value" => "strict"}})

        conn.method == "POST" ->
          Req.Test.json(conn, %{"success" => true, "result" => Map.put(body, "id", "new")})

        posted? ->
          Req.Test.json(conn, %{"success" => true, "result" => []})

        true ->
          Req.Test.json(conn, %{"success" => true, "result" => live_records})
      end
    end)
  end

  test "a declared CNAME is created by the next cycle", %{state_path: file, requests: requests} do
    write_file(file, %{
      "cname_records" => [
        %{"domain" => "example.com", "name" => "app.example.com", "target" => "example.com"}
      ]
    })

    stub_cloudflare(requests, [])

    capture_log(fn -> Monitor.checkup_once() end)

    posts =
      requests
      |> Agent.get(& &1)
      |> Enum.filter(&(elem(&1, 0) == "POST"))
      |> Enum.map(&elem(&1, 2))

    assert Enum.any?(posts, &(&1["name"] == "app.example.com" and &1["type"] == "CNAME"))
  end

  test "a malformed file issues no Cloudflare request", %{state_path: file, requests: requests} do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "{")
    stub_cloudflare(requests, [])

    capture_log(fn ->
      assert [message] = Monitor.checkup_once()
      assert String.starts_with?(message, "Error - desired state unavailable")
    end)

    assert Agent.get(requests, & &1) == []
  end

  test "inventory counts an accepted record as managed", %{state_path: file, requests: requests} do
    write_file(file, %{
      "cname_records" => [
        %{"domain" => "example.com", "name" => "foss.example.com", "target" => "example.com"}
      ]
    })

    stub_cloudflare(requests, [
      %{
        "id" => "c1",
        "type" => "CNAME",
        "name" => "foss.example.com",
        "content" => "example.com",
        "proxied" => false,
        "ttl" => 300
      }
    ])

    assert {:ok, report} = Inventory.inventory("example.com")
    assert Enum.map(report["managed"], & &1["name"]) == ["foss.example.com"]
    assert report["unmanaged"] == []
  end
end

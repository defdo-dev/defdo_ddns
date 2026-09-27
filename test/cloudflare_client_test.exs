defmodule Defdo.Cloudflare.ClientTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H02: bounded requests, full
  pagination, and fallback public-IP providers.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.DDNS

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_req = Application.get_env(:defdo_ddns, :cloudflare_req_options)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Application.put_env(:defdo_ddns, Cloudflare, auth_token: "test-token")
    Application.put_env(:defdo_ddns, :cloudflare_req_options, retry: false)

    {:ok, requests} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Req.default_options([])
      restore(Cloudflare, previous_cloudflare)
      restore(:cloudflare_req_options, previous_req)
    end)

    {:ok, requests: requests}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp record(requests, conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    Agent.update(requests, &[conn.query_params | &1])
    conn
  end

  defp record_count(requests), do: requests |> Agent.get(& &1) |> length()

  describe "req_options/0" do
    test "has bounded defaults" do
      Application.delete_env(:defdo_ddns, :cloudflare_req_options)
      opts = DDNS.req_options()

      assert opts[:receive_timeout] == 10_000
      assert opts[:max_retries] == 2
      assert opts[:connect_options][:timeout] == 5_000
    end

    test "lets app env override" do
      assert DDNS.req_options()[:retry] == false
    end
  end

  describe "fetch_dns_records/2 pagination" do
    test "follows total_pages and keeps page order", %{requests: requests} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = record(requests, conn)
        page = String.to_integer(conn.query_params["page"])

        Req.Test.json(conn, %{
          "success" => true,
          "result" => [%{"id" => "r#{page}", "type" => "A", "name" => "h#{page}.example.com"}],
          "result_info" => %{"page" => page, "total_pages" => 3}
        })
      end)

      assert {:ok, records} = DDNS.fetch_dns_records("zone-1")
      assert Enum.map(records, & &1["id"]) == ["r1", "r2", "r3"]
      assert record_count(requests) == 3
    end

    test "sends per_page explicitly", %{requests: requests} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = record(requests, conn)
        assert conn.query_params["per_page"] == "5000"
        Req.Test.json(conn, %{"success" => true, "result" => []})
      end)

      assert {:ok, []} = DDNS.fetch_dns_records("zone-1")
    end

    test "fails whole when a later page fails", %{requests: requests} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = record(requests, conn)

        case conn.query_params["page"] do
          "1" ->
            Req.Test.json(conn, %{
              "success" => true,
              "result" => [%{"id" => "r1"}],
              "result_info" => %{"page" => 1, "total_pages" => 2}
            })

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.resp(521, "error code: 521\n")
        end
      end)

      capture_log(fn ->
        assert DDNS.fetch_dns_records("zone-1") == {:error, :listing_failed}
      end)
    end

    test "stops without result_info", %{requests: requests} do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = record(requests, conn)
        Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "only"}]})
      end)

      assert {:ok, [%{"id" => "only"}]} = DDNS.fetch_dns_records("zone-1")
      assert record_count(requests) == 1
    end
  end

  describe "public IP detection" do
    test "falls back to the next provider" do
      Application.put_env(:defdo_ddns, Cloudflare,
        auth_token: "test-token",
        ipv4_lookup_urls: ["https://first.test", "https://second.test"]
      )

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.host do
          "first.test" -> Plug.Conn.resp(conn, 503, "unavailable")
          "second.test" -> Plug.Conn.resp(conn, 200, "203.0.113.7\n")
        end
      end)

      capture_log(fn -> assert DDNS.get_current_ipv4() == "203.0.113.7" end)
    end
  end
end

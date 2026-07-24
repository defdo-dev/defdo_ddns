defmodule Defdo.Cloudflare.EdgeErrorTest do
  @moduledoc """
  Regression coverage for the Cloudflare edge-failure crash.

  Cloudflare 520-527 responses are a plain-text/HTML page, not the documented
  JSON envelope. The client used to call `Map.has_key?/2` straight on the body,
  so a single transient 521 raised `BadMapError`, killed the monitor, exhausted
  the supervisor restart intensity and shut the whole application down — it then
  stayed down until someone noticed. Every call must degrade, never raise.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Defdo.Cloudflare.DDNS

  @edge_body "error code: 521\n"

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Application.put_env(:defdo_ddns, Cloudflare, auth_token: "test-token")

    on_exit(fn ->
      Req.default_options([])

      if previous_cloudflare,
        do: Application.put_env(:defdo_ddns, Cloudflare, previous_cloudflare),
        else: Application.delete_env(:defdo_ddns, Cloudflare)
    end)

    :ok
  end

  defp stub_edge_error do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(521, @edge_body)
    end)
  end

  describe "Cloudflare edge error (521, non-JSON body)" do
    test "get_zone_id/1 returns nil instead of raising" do
      stub_edge_error()

      log = capture_log(fn -> assert DDNS.get_zone_id("defdo.ninja") == nil end)

      assert log =~ "get_zone_id"
      assert log =~ "521"
    end

    test "list_dns_records/2 returns [] instead of raising" do
      stub_edge_error()

      log = capture_log(fn -> assert DDNS.list_dns_records("zone-123") == [] end)

      assert log =~ "list_dns_records"
      assert log =~ "521"
    end

    test "create_dns_record/2 reports failure instead of raising" do
      stub_edge_error()

      log =
        capture_log(fn ->
          assert DDNS.create_dns_record("zone-123", %{"type" => "CNAME", "name" => "x"}) ==
                   {false, nil}
        end)

      assert log =~ "create_dns_record"
    end

    test "apply_update/2 reports failure instead of raising" do
      stub_edge_error()

      log =
        capture_log(fn ->
          assert DDNS.apply_update("zone-123", {"record-1", ~s({"type":"CNAME"})}) == {false, nil}
        end)

      assert log =~ "apply_update"
    end
  end

  describe "transport failure" do
    test "get_zone_id/1 returns nil when the request never completes" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_log(fn -> assert DDNS.get_zone_id("defdo.ninja") == nil end)

      assert log =~ "transport error"
    end
  end

  describe "well-formed responses still work" do
    test "get_zone_id/1 extracts the zone id from a normal envelope" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"success" => true, "result" => [%{"id" => "zone-abc"}]})
      end)

      assert DDNS.get_zone_id("defdo.ninja") == "zone-abc"
    end

    test "get_zone_id/1 returns nil for an empty result list rather than raising MatchError" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"success" => true, "result" => []})
      end)

      log = capture_log(fn -> assert DDNS.get_zone_id("unknown.tld") == nil end)

      assert log =~ "get_zone_id"
    end
  end
end

defmodule Defdo.DDNS.HardeningInvariantsTest do
  @moduledoc """
  Source-level invariants from the ddns-service-hardening slice set. Each one
  guards a defect that was measured, not imagined; see that set's README.
  Every check asserts its file exists before looking inside it, so deleting or
  renaming a file cannot turn a refutation green.
  """
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  defp source!(relative) do
    path = Path.join(@root, relative)
    assert File.regular?(path), "expected #{relative} to exist"
    File.read!(path)
  end

  test "the monitor reads intent through Intent, not env accessors (H04)" do
    src = source!("lib/defdo/cloudflare/monitor.ex")
    assert src =~ "Intent.load()"

    for forbidden <-
          ~w(get_cloudflare_key records_to_monitor domain_configured? get_cname_records_for_domain get_all_cloudflare_config_domains) do
      refute src =~ forbidden, "monitor.ex must not call #{forbidden}"
    end
  end

  test "the monitor never uses the absence-hiding listing (H05)" do
    src = source!("lib/defdo/cloudflare/monitor.ex")
    assert src =~ "fetch_dns_records("
    refute src =~ "list_dns_records(", "monitor.ex must not call list_dns_records/2"
  end

  test "every Req call in the Cloudflare client carries req_options (H02)" do
    src = source!("lib/defdo/cloudflare/ddns.ex")
    calls = ~r/Req\.(get|put|post)\(/ |> Regex.scan(src) |> length()

    uses =
      src
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ "@spec"))
      |> Enum.count(&(&1 =~ "req_options()"))

    assert calls >= 6, "expected at least 6 Req calls, found #{calls}"
    assert uses >= calls, "#{calls} Req calls but only #{uses} req_options() uses"
  end

  test "stores write through a lock and a unique temp file (H03)" do
    for relative <- ["lib/defdo/ddns/desired_state_store.ex", "lib/defdo/ddns/adoption.ex"] do
      src = source!(relative)
      assert src =~ "FileLock.with_lock", "#{relative} must lock its writes"
      assert src =~ "FileLock.temp_path", "#{relative} must use a unique temp path"
      refute src =~ ~s(<> ".tmp"), "#{relative} still uses a shared temp file"
    end
  end

  test "adoption routes are operator-only (H06)" do
    src = source!("lib/defdo/ddns/api/router.ex")
    assert src =~ "defp authorize_operator("

    uses =
      src
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ "defp authorize"))
      |> Enum.count(&(&1 =~ "authorize(conn)"))

    assert uses == 2, "only upsert and authorize_operator/1 may call authorize/1 (found #{uses})"
  end

  test "status is operator-only and readiness has no auth (H08)" do
    src = source!("lib/defdo/ddns/api/router.ex")
    assert src =~ ~s(get "/ready")
    assert [_, status_route] = String.split(src, ~s(get "/v1/status"), parts: 2)

    body = status_route |> String.split("\n  end", parts: 2) |> hd()
    assert body =~ "authorize_operator(conn)", "/v1/status must require the operator token"
  end

  test "every outbound request is instrumented (H09)" do
    src = source!("lib/defdo/cloudflare/ddns.ex")
    calls = ~r/Req\.(get|put|post)\(/ |> Regex.scan(src) |> length()
    wraps = ~r/instrument\(:(cloudflare|ip_lookup)/ |> Regex.scan(src) |> length()

    assert calls >= 6
    assert wraps >= calls, "#{calls} Req calls but #{wraps} instrument/3 wrappers"
  end

  test "the heartbeat never logs its URL (H10)" do
    src = source!("lib/defdo/ddns/heartbeat.ex")
    refute src =~ ~r/Logger\.\w+\([^\n]*url/, "heartbeat.ex logs the URL"
    refute src =~ "Exception.message", "exception messages can carry the URL"
  end
end

defmodule Defdo.Cloudflare.MonitorTest do
  @moduledoc false
  use ExUnit.Case
  alias Defdo.Cloudflare.Monitor

  setup do
    previous_cloudflare_config = Application.get_env(:defdo_ddns, Cloudflare)

    Application.put_env(:defdo_ddns, Cloudflare,
      domain_mappings: %{},
      aaaa_domain_mappings: %{},
      cname_records: []
    )

    on_exit(fn ->
      if Process.whereis(Monitor) do
        Monitor |> GenServer.stop()
      end

      if previous_cloudflare_config == nil do
        Application.delete_env(:defdo_ddns, Cloudflare)
      else
        Application.put_env(:defdo_ddns, Cloudflare, previous_cloudflare_config)
      end
    end)

    :ok
  end

  describe "GenServer functionality" do
    test "starts and stops monitor process" do
      # Handle case where monitor might already be running
      case Monitor.start_link([]) do
        {:ok, pid} ->
          assert Process.alive?(pid)
          GenServer.stop(pid)
          refute Process.alive?(pid)

        {:error, {:already_started, pid}} ->
          # Monitor is already running, just verify it's alive
          assert Process.alive?(pid)
      end
    end

    test "handles monitor execution with valid configuration" do
      assert Monitor.checkup_once() == []
    end
  end

  describe "process/1" do
    test "handles empty DNS records gracefully" do
      assert Monitor.checkup_once() == []

      case Monitor.start_link([]) do
        {:ok, pid} ->
          assert is_list(Monitor.checkup())
          GenServer.stop(pid)

        {:error, {:already_started, pid}} ->
          assert Process.alive?(pid)
      end
    end
  end
end

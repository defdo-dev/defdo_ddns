defmodule Defdo.DDNS.Health do
  @moduledoc """
  Readiness and a safe status report for probes and operators.

  Readiness means "DDNS can do its job": the record store is up, intent is
  loadable and — when the monitor is enabled — cycles are completing. The
  report carries counts and timestamps only; never hostnames, IPs or tokens.
  """

  alias Defdo.Cloudflare.Monitor
  alias Defdo.DDNS.{Adoption, DesiredStateStore, Intent, RecordStore}

  @spec readiness(DateTime.t()) :: {:ready | :not_ready, [String.t()]}
  def readiness(now \\ DateTime.utc_now()) do
    reasons =
      [record_store_reason(), intent_reason()] ++ monitor_reasons(monitor_enabled?(), now)

    case Enum.reject(reasons, &is_nil/1) do
      [] -> {:ready, []}
      list -> {:not_ready, list}
    end
  end

  @spec report(DateTime.t()) :: map()
  def report(now \\ DateTime.utc_now()) do
    {state, reasons} = readiness(now)

    %{
      "ready" => state == :ready,
      "reasons" => reasons,
      "monitor" => monitor_report(),
      "desired_state" => DesiredStateStore.status(),
      "record_store" => record_store_report(),
      "adoption" => adoption_report()
    }
  end

  defp record_store_reason do
    case RecordStore.status() do
      status when is_map(status) -> nil
      {:error, _reason} -> "record_store_unavailable"
    end
  end

  defp intent_reason do
    case Intent.load() do
      {:ok, _intent} -> nil
      {:error, _reason} -> "desired_state_unavailable"
    end
  end

  defp monitor_reasons(false, _now), do: []

  defp monitor_reasons(true, now) do
    case Monitor.status() do
      {:error, :not_running} -> ["monitor_not_running"]
      {:ok, %{"outcome" => "starting"}} -> ["starting"]
      {:ok, status} -> [failures_reason(status), stale_reason(status, now)]
    end
  end

  defp failures_reason(%{"consecutive_failures" => n}) do
    if n >= config(:max_consecutive_failures, 3), do: "consecutive_failures"
  end

  defp stale_reason(%{"last_success_at" => nil}, _now), do: nil

  defp stale_reason(%{"last_success_at" => at, "refetch_every_ms" => every}, now) do
    {:ok, last, _offset} = DateTime.from_iso8601(at)
    limit_ms = config(:stale_factor, 3) * every

    if DateTime.diff(now, last, :millisecond) > limit_ms, do: "stale"
  end

  defp monitor_report do
    case Monitor.status() do
      {:ok, status} -> status
      {:error, :not_running} -> %{"outcome" => "not_running"}
    end
  end

  # Explicit subset: the backend status map carries atoms, tuples and paths
  # that are either not JSON-encodable or not the operator's business.
  defp record_store_report do
    case RecordStore.status() do
      status when is_map(status) ->
        %{
          "state" => "running",
          "source" => to_string(status[:source]),
          "record_count" => status[:record_count],
          "record_types" => status[:record_types],
          "last_error" => if(status[:last_error], do: inspect(status[:last_error]))
        }

      {:error, reason} ->
        %{"state" => "error", "reason" => inspect(reason)}
    end
  end

  defp adoption_report do
    %{"pending" => length(Adoption.list(:pending))}
  rescue
    error -> %{"state" => "error", "reason" => Exception.message(error)}
  end

  defp monitor_enabled?, do: Application.get_env(:defdo_ddns, :monitor_enabled, true)

  defp config(key, default) do
    :defdo_ddns |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end

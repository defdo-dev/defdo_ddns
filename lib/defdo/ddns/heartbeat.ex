defmodule Defdo.DDNS.Heartbeat do
  @moduledoc """
  Dead-man's switch: one ping per completed cycle, so silence means trouble.

  `"failed"` cycles send nothing — a DDNS that cannot converge must look dead
  to the receiver. The URL carries the receiver's token: it is never logged.
  A ping can never raise into the monitor or wait longer than `timeout_ms`.
  """

  require Logger

  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(url()) and url() != ""

  @doc "Ping for a cycle outcome. Always returns `:ok`."
  @spec ping(String.t()) :: :ok
  def ping(outcome) do
    if enabled?() and should_ping?(outcome), do: send_ping()
    :ok
  end

  defp should_ping?("ok"), do: true
  defp should_ping?("degraded"), do: config(:send_on_degraded, true)
  defp should_ping?(_outcome), do: false

  defp send_ping do
    case Req.get(url(), receive_timeout: config(:timeout_ms, 5_000), retry: false) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("DDNS heartbeat rejected (status=#{status})")

      {:error, reason} ->
        Logger.warning("DDNS heartbeat failed: #{inspect(reason_label(reason))}")
    end
  rescue
    error -> Logger.warning("DDNS heartbeat crashed: #{inspect(error.__struct__)}")
  end

  # Transport errors can embed the request; keep only the reason atom.
  defp reason_label(%{reason: reason}) when is_atom(reason), do: reason
  defp reason_label(reason) when is_atom(reason), do: reason
  defp reason_label(_reason), do: :unknown

  defp url, do: config(:url, nil)

  defp config(key, default) do
    :defdo_ddns |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end

defmodule Defdo.DDNS.API.Router do
  @moduledoc false

  use Plug.Router

  alias Defdo.DDNS.API.DNS

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{status: "ok"})
  end

  post "/v1/dns/upsert" do
    with :ok <- authorize(conn),
         {:ok, result} <- DNS.upsert_free_domain(conn.body_params) do
      json(conn, 200, %{status: "ok", result: result})
    else
      {:error, :unauthorized} ->
        json(conn, 401, %{status: "error", error: "unauthorized"})

      {:error, {:validation, errors}} ->
        json(conn, 422, %{status: "error", error: "validation_failed", details: errors})

      {:error, {:conflict, details}} ->
        json(conn, 409, %{status: "error", error: "dns_conflict", details: details})

      {:error, {:upstream, reason}} ->
        json(conn, 502, %{status: "error", error: "upstream_failed", details: reason})

      {:error, reason} ->
        json(conn, 500, %{status: "error", error: "internal_error", details: inspect(reason)})
    end
  end

  match _ do
    json(conn, 404, %{status: "error", error: "not_found"})
  end

  defp authorize(conn) do
    case configured_token() do
      token when is_binary(token) and token != "" ->
        provided_token =
          conn
          |> Plug.Conn.get_req_header("authorization")
          |> List.first()
          |> parse_bearer_token()
          |> case do
            nil -> conn |> Plug.Conn.get_req_header("x-api-token") |> List.first()
            bearer -> bearer
          end

        if provided_token == token do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        :ok
    end
  end

  defp parse_bearer_token(nil), do: nil

  defp parse_bearer_token(value) when is_binary(value) do
    case String.split(value, " ", parts: 2) do
      ["Bearer", token] -> String.trim(token)
      _ -> nil
    end
  end

  defp configured_token do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> Keyword.get(:token)
  end

  defp json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end

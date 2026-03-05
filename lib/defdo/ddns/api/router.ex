defmodule Defdo.DDNS.API.Router do
  @moduledoc false

  use Plug.Router

  alias Defdo.DDNS.API.AuthConfig
  alias Defdo.DDNS.API.AuthStore
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
    with {:ok, auth_context} <- authorize(conn),
         :ok <- authorize_base_domain(auth_context, conn.body_params),
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
    clients = AuthStore.get_clients()
    client_id = provided_client_id(conn)

    cond do
      map_size(clients) == 0 ->
        authorize_global_token(conn)

      is_binary(client_id) ->
        authorize_client(conn, clients, client_id)

      true ->
        # Compatibility path:
        # when clients are configured but no x-client-id is sent, allow a valid global token.
        authorize_global_token(conn)
    end
  end

  defp authorize_client(conn, clients, client_id) when is_binary(client_id) do
    with %{token: expected_token} = client <- Map.get(clients, client_id),
         true <- secure_compare_tokens?(provided_token(conn), expected_token) do
      {:ok,
       %{mode: :client, client_id: client_id, allowed_base_domains: client.allowed_base_domains}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_global_token(conn) do
    case configured_token() do
      token when is_binary(token) ->
        if secure_compare_tokens?(provided_token(conn), token) do
          {:ok, %{mode: :token}}
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authorize_base_domain(%{mode: :client, allowed_base_domains: allowed_domains}, params)
       when is_map(params) do
    case extract_base_domain(params) do
      nil ->
        :ok

      base_domain when is_binary(base_domain) ->
        if Enum.member?(allowed_domains, base_domain) do
          :ok
        else
          {:error, {:validation, %{"base_domain" => "not allowed for client"}}}
        end

      _ ->
        {:error, {:validation, %{"base_domain" => "not allowed for client"}}}
    end
  end

  defp authorize_base_domain(_auth_context, _params), do: :ok

  defp parse_bearer_token(nil), do: nil

  defp parse_bearer_token(value) when is_binary(value) do
    case String.split(value, " ", parts: 2) do
      ["Bearer", token] -> AuthConfig.normalize_token(token)
      _ -> nil
    end
  end

  defp provided_token(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> parse_bearer_token()
    |> case do
      nil ->
        conn
        |> Plug.Conn.get_req_header("x-api-token")
        |> List.first()
        |> AuthConfig.normalize_token()

      bearer ->
        bearer
    end
  end

  defp provided_client_id(conn) do
    conn
    |> Plug.Conn.get_req_header("x-client-id")
    |> List.first()
    |> normalize_client_id()
  end

  defp secure_compare_tokens?(provided_token, expected_token)
       when is_binary(provided_token) and is_binary(expected_token) and
              byte_size(provided_token) == byte_size(expected_token) do
    Plug.Crypto.secure_compare(provided_token, expected_token)
  end

  defp secure_compare_tokens?(_, _), do: false

  defp configured_token do
    case AuthConfig.from_app_env() do
      {:ok, %{token: token}} -> token
      _ -> nil
    end
  end

  defp extract_base_domain(params) do
    raw_base_domain =
      cond do
        Map.has_key?(params, "base_domain") ->
          Map.get(params, "base_domain")

        Map.has_key?(params, :base_domain) ->
          Map.get(params, :base_domain)

        true ->
          nil
      end

    AuthConfig.normalize_base_domain(raw_base_domain)
  end

  defp normalize_client_id(nil), do: nil

  defp normalize_client_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      client_id -> client_id
    end
  end

  defp normalize_client_id(_), do: nil

  defp json(conn, status, payload) do
    body = Jason.encode!(payload)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end
end

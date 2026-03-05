defmodule Defdo.DDNS.API.AuthConfig do
  @moduledoc false

  @type client :: %{
          id: String.t(),
          token: String.t(),
          allowed_base_domains: [String.t()]
        }

  @type t :: %{
          mode: :clients | :token | :none,
          token: String.t() | nil,
          clients: %{optional(String.t()) => client}
        }

  @spec from_app_env() :: {:ok, t()} | {:error, term()}
  def from_app_env do
    :defdo_ddns
    |> Application.get_env(Defdo.DDNS.API, [])
    |> from_config()
  end

  @spec from_config(keyword()) :: {:ok, t()} | {:error, term()}
  def from_config(config) when is_list(config) do
    token =
      config
      |> Keyword.get(:token)
      |> normalize_token()

    with {:ok, clients_map} <- parse_clients(Keyword.get(config, :clients, [])) do
      mode =
        cond do
          map_size(clients_map) > 0 -> :clients
          is_binary(token) -> :token
          true -> :none
        end

      {:ok, %{mode: mode, token: token, clients: clients_map}}
    end
  end

  @spec parse_clients(term()) :: {:ok, %{optional(String.t()) => client}} | {:error, term()}
  def parse_clients(clients) do
    normalize_clients(clients)
  end

  @spec normalize_base_domain(term()) :: String.t() | nil
  def normalize_base_domain(value), do: normalize_domain(value)

  @spec normalize_token(term()) :: String.t() | nil
  def normalize_token(nil), do: nil

  def normalize_token(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      token -> token
    end
  end

  def normalize_token(_), do: nil

  defp normalize_clients(nil), do: {:ok, %{}}
  defp normalize_clients([]), do: {:ok, %{}}

  defp normalize_clients(clients) when is_list(clients) do
    Enum.reduce_while(clients, {:ok, %{}}, fn entry, {:ok, acc} ->
      with {:ok, normalized} <- normalize_client(entry),
           :ok <- ensure_unique_client_id(acc, normalized.id) do
        {:cont, {:ok, Map.put(acc, normalized.id, normalized)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_clients(_), do: {:error, {:invalid_clients, "must be a JSON array"}}

  defp normalize_client(entry) when is_map(entry) do
    id =
      entry
      |> map_get("id", :id)
      |> case do
        nil -> map_get(entry, "client_id", :client_id)
        value -> value
      end
      |> normalize_client_id()

    token =
      entry
      |> map_get("token", :token)
      |> normalize_token()

    allowed_domains =
      entry
      |> map_get("allowed_base_domains", :allowed_base_domains)
      |> normalize_allowed_domains()

    cond do
      not is_binary(id) ->
        {:error, {:invalid_clients, "each client must include non-empty id"}}

      not is_binary(token) ->
        {:error, {:invalid_clients, "client #{id} must include non-empty token"}}

      allowed_domains == [] ->
        {:error, {:invalid_clients, "client #{id} must include non-empty allowed_base_domains"}}

      true ->
        {:ok, %{id: id, token: token, allowed_base_domains: allowed_domains}}
    end
  end

  defp normalize_client(_),
    do: {:error, {:invalid_clients, "each client entry must be an object"}}

  defp ensure_unique_client_id(clients, id) do
    if Map.has_key?(clients, id) do
      {:error, {:invalid_clients, "duplicate client id #{id}"}}
    else
      :ok
    end
  end

  defp normalize_client_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_client_id(_), do: nil

  defp normalize_allowed_domains(value) when is_binary(value) do
    value
    |> String.split(~r/[,\s]+/, trim: true)
    |> normalize_allowed_domains()
  end

  defp normalize_allowed_domains(value) when is_list(value) do
    value
    |> Enum.map(&normalize_domain/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_allowed_domains(_), do: []

  defp normalize_domain(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> case do
      "" -> nil
      domain -> domain
    end
  end

  defp normalize_domain(_), do: nil

  defp map_get(map, string_key, atom_key) do
    cond do
      Map.has_key?(map, string_key) ->
        Map.get(map, string_key)

      Map.has_key?(map, atom_key) ->
        Map.get(map, atom_key)

      true ->
        nil
    end
  end
end

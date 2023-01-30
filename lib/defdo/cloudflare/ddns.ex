defmodule Defdo.Cloudflare.DDNS do
  @moduledoc """
  We fetch the current domain ip in order to set your ip on cloudflare
  """
  require Logger

  @base_url "https://api.cloudflare.com/client/v4"
  @zone_endpoint @base_url <> "/zones"

  @doc """
  Get the current ip for the running service.

  Keep in mind that you use it to get the current ip and most probably is your pc/router at your home lab.

      iex> Defdo.Cloudflare.DDNS.get_current_ip()
  """
  @spec get_current_ip :: String.t()
  def get_current_ip do
    key = "ip"

    {^key, current_ip} =
      "https://www.cloudflare.com/cdn-cgi/trace"
      |> Req.get()
      |> parse_cl_trace(key)

    current_ip
  end

  @doc """
  Retrieve the zone id for specific domain

      iex> Defdo.Cloudflare.DDNS.get_zone_id("defdo.de")
  """
  @spec get_zone_id(bitstring) :: String.t() | nil
  def get_zone_id(domain) when is_bitstring(domain) do
    body_response =
      Req.get!(
        @zone_endpoint,
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        params: [name: domain]
      ).body

    if Map.has_key?(body_response, "result") && not is_nil(body_response["result"]) do
      [zone | _] = body_response["result"]
      zone["id"]
    else
      errors = body_response["errors"]
      Logger.error(["🛑 ", inspect(errors)])
      nil
    end
  end

  @doc """
  Get the List of DNS records

  use the params to filter the result and get only which are interested

      iex> Defdo.Cloudflare.DDNS.list_dns_records(zone_id, [name: "defdo.de,h.defdo.de"])
  """
  @spec list_dns_records(String.t(), list()) :: list()
  def list_dns_records(zone_id, params \\ []) do
    body_response =
      Req.get!(
        "#{@zone_endpoint}/#{zone_id}/dns_records",
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        params: params
      ).body

    if Map.has_key?(body_response, "result") do
      body_response["result"]
    else
      errors = body_response["errors"]
      Logger.error(["🛑 ", inspect(errors)])
      []
    end
  end

  @doc """
  Applies to cloudflare the record update.
  """
  @spec apply_update(String.t(), {String.t(), String.t()}) :: tuple()
  def apply_update(zone_id, {record_id, body}) when is_bitstring(body) do
    body_response =
      Req.put!(
        "#{@zone_endpoint}/#{zone_id}/dns_records/#{record_id}",
        headers: [authorization: "Bearer #{get_cloudflare_key(:auth_token)}"],
        body: body
      ).body

    if Map.has_key?(body_response, "result") do
      {body_response["success"], body_response["result"]}
    else
      errors = body_response["errors"]
      Logger.error(["🛑 ", inspect(errors)])
      {body_response["success"], nil}
    end
  end

  @doc """
  Check the records which must be updated

  We filter the updatable records and transform them to give the input to apply_update/2

  In fact this give the second parameter to execute the update.
  """
  @spec input_for_update_dns_records(list(), String.t()) :: list()
  def input_for_update_dns_records(records, local_ip) do
    records
    |> Enum.reject(&(&1["content"] == local_ip))
    |> Enum.map(fn record ->
      body =
        %{
          "type" => record["type"],
          "name" => record["name"],
          "ttl" => record["ttl"],
          "proxied" => record["proxied"],
          "content" => local_ip
        }
        |> Jason.encode!()

      {record["id"], body}
    end)
  end

  @doc """
  Retrieve the records to be used to monitor.
  """
  def records_to_monitor(domain) do
    [domain | get_subdomains_for(domain)]
  end

  def get_subdomains_for(domain, subdomains \\ get_cloudflare_config_subdomains()) when is_list(subdomains) do
    subdomains
    |> Enum.map(fn subdomain ->
      maybe_concatenate_domain(subdomain, domain)
    end)
    |> Enum.uniq()
    |> Enum.reject(& &1 == :no_related)
  end

  defp subdomain_belongs_to_domain?(subdomain, domain) do
    String.contains?(subdomain, domain)
  end

  defp maybe_concatenate_domain(subdomain, domain) do
    if subdomain_belongs_to_domain?(subdomain, domain) do
      subdomain
    else
      if !String.contains?(subdomain, ".") do
        "#{subdomain}.#{domain}"
      else
        :no_related
      end
    end
  end

  @doc """
  By parsing the Application config retrieves a list of domains defined.
  """
  def get_cloudflare_config_domains(domain \\ get_cloudflare_key(:domain))
  def get_cloudflare_config_domains(domain) when not is_nil(domain) do
    parse_string_config(domain)
  end
  def get_cloudflare_config_domains(_), do: []
  @doc """
  Get the key from the the Application.
  """
  @spec get_cloudflare_key(atom()) :: String.t()
  def get_cloudflare_key(key, default \\ "") do
    Application.get_env(:defdo_ddns, Cloudflare)
    |> Keyword.get(key, default)
  end

  @doc """
  By parsing the Application config retrieves a list of domains defined.
  """
  def get_cloudflare_config_subdomains(subdomain \\ get_cloudflare_key(:subdomains))
  def get_cloudflare_config_subdomains(subdomain) when subdomain not in [nil, ""] do
    parse_string_config(subdomain)
    # |> Enum.reject(&(&1 == ""))
  end
  def get_cloudflare_config_subdomains(_), do: []

  defp parse_string_config(string) do
    case String.split(string, ~r/(,|\s)/, trim: true) do
      [] ->
        Logger.info("Can't parse the config, it must separate with , or space", ansi_color: :yellow)
        {:error, :missing_config}
      list when is_list(list) ->
        list
    end
  end

  defp parse_cl_trace({:ok, %Req.Response{body: body, status: 200}}, key) do
    body
    |> String.split("\n")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn str ->
      [key, value] = String.split(str, "=")
      {key, value}
    end)
    |> Enum.filter(fn {k, _value} -> k == key end)
    |> List.first()
  end

  defp parse_cl_trace(_, "ip") do
    {"ip", "127.0.0.1"}
  end
end

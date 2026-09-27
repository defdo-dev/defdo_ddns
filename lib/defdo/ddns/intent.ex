defmodule Defdo.DDNS.Intent do
  @moduledoc """
  What DNS should look like, for one cycle, from exactly one source.

  With a desired-state file configured, the file is the only source. Without
  one, intent comes from application env and the record store, as it always
  has. A broken file is an error, never a reason to fall back to env: that
  would resurrect intent someone deliberately removed from the file.

  Load once per cycle and pass the result down; it reads a file.
  """

  alias Defdo.Cloudflare.DDNS
  alias Defdo.DDNS.{DesiredStateStore, RecordStore}

  @type t :: %{required(String.t()) => term()}

  @doc "Load intent from the desired-state file, or from env when the file is disabled."
  @spec load() :: {:ok, t()} | {:error, term()}
  def load do
    case DesiredStateStore.load() do
      {:ok, doc} -> {:ok, from_desired_state(doc)}
      {:error, :disabled} -> {:ok, from_env()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Intent as application env and the record store describe it."
  @spec from_env() :: t()
  def from_env do
    %{
      "source" => "env",
      "domain_mappings" => map_or_empty(DDNS.get_cloudflare_key(:domain_mappings, %{})),
      "aaaa_domain_mappings" => map_or_empty(DDNS.get_cloudflare_key(:aaaa_domain_mappings, %{})),
      "cname_records" => RecordStore.records(),
      "auto_create_missing_records" =>
        DDNS.get_cloudflare_key(:auto_create_missing_records, false) == true,
      "proxy_a_records" => DDNS.get_cloudflare_key(:proxy_a_records, false) == true,
      "proxy_exclude" => DDNS.get_proxy_exclude_patterns()
    }
  end

  @doc "Intent from a canonical desired-state document."
  @spec from_desired_state(map()) :: t()
  def from_desired_state(%{"cloudflare" => cf}) do
    %{
      "source" => "desired_state",
      "domain_mappings" => Map.get(cf, "domain_mappings", %{}),
      "aaaa_domain_mappings" => Map.get(cf, "aaaa_domain_mappings", %{}),
      # File entries carry no "type"; the normalizer filters on it.
      "cname_records" =>
        cf |> Map.get("cname_records", []) |> Enum.map(&Map.put(&1, "type", "CNAME")),
      "auto_create_missing_records" => Map.get(cf, "auto_create_missing_records", false),
      "proxy_a_records" => Map.get(cf, "proxy_a_records", false),
      "proxy_exclude" => DDNS.normalize_proxy_exclude_patterns(Map.get(cf, "proxy_exclude", []))
    }
  end

  @doc """
  Domains to process: A mapping keys ∪ AAAA mapping keys ∪ CNAME entry domains.

  CNAME domains are included so a record the API declares for a base domain
  with no A mapping is still converged.
  """
  @spec domains(t()) :: [String.t()]
  def domains(intent) do
    cname_domains =
      intent["cname_records"]
      |> Enum.map(&(Map.get(&1, "domain") || Map.get(&1, :domain)))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    (Map.keys(intent["domain_mappings"]) ++
       Map.keys(intent["aaaa_domain_mappings"]) ++ cname_domains)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Hostnames to keep on the public IP for `domain`, root included; `[]` if unmapped."
  @spec hostnames(t(), String.t(), :a | :aaaa) :: [String.t()]
  def hostnames(intent, domain, family) do
    case Map.fetch(intent[mapping_key(family)], domain) do
      {:ok, subdomains} when is_list(subdomains) -> DDNS.expand_hostnames(domain, subdomains)
      _ -> []
    end
  end

  @doc "Normalized CNAME records for `domain`."
  @spec cname_records(t(), String.t()) :: [map()]
  def cname_records(intent, domain) do
    DDNS.normalize_cname_records(intent["cname_records"], domain, intent["proxy_a_records"])
  end

  @doc "Proxy policy for A/AAAA planning."
  @spec proxy_opts(t()) :: DDNS.proxy_opts()
  def proxy_opts(intent) do
    %{proxy_a_records: intent["proxy_a_records"], proxy_exclude: intent["proxy_exclude"]}
  end

  defp mapping_key(:a), do: "domain_mappings"
  defp mapping_key(:aaaa), do: "aaaa_domain_mappings"

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}
end

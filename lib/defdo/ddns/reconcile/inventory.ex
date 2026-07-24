defmodule Defdo.DDNS.Reconcile.Inventory do
  @moduledoc """
  Answers one question truthfully, for one zone: which live Cloudflare records do
  we declare, which do we not, and which do we declare but are absent?

  Strictly read-only. It never writes to Cloudflare and never adopts anything;
  deciding what to do with an undeclared record is `Defdo.DDNS.Adoption`'s job.

  Records are classified by identity — the `{type, name}` pair — not by content.
  A declared record whose live content has drifted is still `managed`: converging
  it is the monitor's work, and reporting it as missing would invite adopting a
  record we already own.

  Only the types DDNS manages (`A`, `AAAA`, `CNAME`) are considered. Anything
  else in the zone — MX, TXT, NS — is not ours and must never surface as
  unmanaged, or every zone would look like it needed adopting.
  """

  require Logger

  alias Defdo.Cloudflare.DDNS
  alias Defdo.DDNS.RecordSnapshot

  @managed_types ~w(A AAAA CNAME)

  @type report :: %{
          required(String.t()) => String.t() | list() | map()
        }

  @doc """
  Classify a zone's live records against what DDNS declares.

  Returns `{:ok, report}` or `{:error, reason}`. It reports an error rather than
  a partial answer whenever the truth is unknown: a failed listing must never be
  read as "the zone is empty", which downstream would mean "every declared record
  vanished" and "nothing is declared" at once.
  """
  @spec inventory(String.t()) :: {:ok, report()} | {:error, term()}
  def inventory(domain) when is_binary(domain) do
    with {:ok, zone_id} <- resolve_zone(domain),
         {:ok, live} <- fetch_live(zone_id),
         {:ok, declared} <- declared_records(domain) do
      build_report(domain, live, declared)
    end
  end

  def inventory(_domain), do: {:error, :domain_must_be_a_string}

  # --- reads ------------------------------------------------------------------

  defp resolve_zone(domain) do
    case DDNS.get_zone_id(domain) do
      zone_id when is_binary(zone_id) and zone_id != "" ->
        {:ok, zone_id}

      _ ->
        Logger.error("inventory: unable to resolve zone id for domain=#{domain}")
        {:error, :zone_unresolved}
    end
  end

  defp fetch_live(zone_id) do
    case DDNS.fetch_dns_records(zone_id) do
      {:ok, records} ->
        {:ok, Enum.filter(records, &(record_type(&1) in @managed_types))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What DDNS says should exist, drawn from the same accessors the monitor uses
  # so the two can never disagree about what is declared.
  defp declared_records(domain) do
    a = declared_hostnames(domain, :domain_mappings) |> Enum.map(&{"A", &1})
    aaaa = declared_hostnames(domain, :aaaa_domain_mappings) |> Enum.map(&{"AAAA", &1})

    cname =
      domain
      |> DDNS.get_cname_records_for_domain()
      |> Enum.map(&{"CNAME", &1["name"]})

    records =
      (a ++ aaaa ++ cname)
      |> Enum.reject(fn {_type, name} -> is_nil(name) or name == "" end)
      |> Enum.map(fn {type, name} -> %{"type" => type, "name" => name} end)

    {:ok, records}
  end

  defp declared_hostnames(domain, mapping_key) do
    if DDNS.domain_configured?(domain, mapping_key) do
      DDNS.records_to_monitor(domain, mapping_key)
    else
      []
    end
  end

  # --- classification ---------------------------------------------------------

  defp build_report(domain, live, declared) do
    live_by_key = Map.new(live, &{key(&1), &1})
    declared_by_key = Map.new(declared, &{key(&1), &1})

    live_keys = MapSet.new(Map.keys(live_by_key))
    declared_keys = MapSet.new(Map.keys(declared_by_key))

    managed = take(live_by_key, MapSet.intersection(live_keys, declared_keys))
    unmanaged = take(live_by_key, MapSet.difference(live_keys, declared_keys))
    missing = take(declared_by_key, MapSet.difference(declared_keys, live_keys))

    with {:ok, managed} <- normalize(managed, domain),
         {:ok, unmanaged} <- normalize(unmanaged, domain) do
      {:ok,
       %{
         "domain" => domain,
         "managed" => managed,
         "unmanaged" => unmanaged,
         # Descriptors, not records: a declaration names a hostname, it does not
         # carry the content the zone would hold, so there is nothing for the
         # snapshot codec to normalize. Nothing adopts from this list either —
         # adoption only ever promotes something that already exists upstream.
         "missing" => Enum.map(missing, &Map.put(&1, "domain", domain)),
         "counts" => %{
           "managed" => length(managed),
           "unmanaged" => length(unmanaged),
           "missing" => length(missing)
         }
       }}
    end
  end

  # Deterministic ordering so a report can be diffed between runs.
  defp take(by_key, keys) do
    keys
    |> Enum.sort()
    |> Enum.map(&Map.fetch!(by_key, &1))
  end

  # Live records only. Normalizing through the snapshot codec is what makes an
  # adopted record byte-identical to a declared one once it reaches the store.
  defp normalize(records, domain) do
    records
    |> Enum.map(&Map.put_new(&1, "domain", domain))
    |> RecordSnapshot.normalize_records(source: :inventory)
  end

  defp key(record), do: {record_type(record), String.downcase(record["name"] || "")}

  defp record_type(record), do: record["type"]
end

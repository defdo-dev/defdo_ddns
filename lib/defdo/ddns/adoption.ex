defmodule Defdo.DDNS.Adoption do
  @moduledoc """
  Durable holding area for records that exist in Cloudflare but were never
  declared here.

  Discovery is automatic; adoption never is. A record found by
  `Defdo.DDNS.Reconcile.Inventory` enters as `pending` and stays there until an
  operator decides. There is no configuration flag that skips that step — the
  whole point is that absorbing someone else's record, or deciding a record is
  ours to converge, is a judgement call with consequences.

  Three states, and the transitions are one-way:

      pending ──accept──▶ accepted
              └─reject──▶ rejected

  A rejected record must never resurface as pending, or every refresh would ask
  the same question again and the answer would stop being read. That is why an
  entry is keyed by a derived, stable id rather than something regenerated per
  run, and why `refresh/1` only ever *inserts* entries it has never seen.

  Accepting records the decision *and* promotes the record into
  `Defdo.DDNS.DesiredStateStore`, atomically — see `accept/2`. Adoption therefore
  requires the desired-state file to be configured: without somewhere durable to
  promote into, "accepted" would be a label with no effect on what DDNS
  converges.
  """

  require Logger

  alias Defdo.DDNS.DesiredStateStore
  alias Defdo.DDNS.Reconcile.Inventory

  @states ~w(pending accepted rejected)

  @type entry :: map()

  # --- public API -------------------------------------------------------------

  @doc """
  Run an inventory and file every undeclared record not already known.

  Returns `{:ok, %{added: n, unchanged: n}}`. An inventory failure propagates
  unchanged and writes nothing: a transient Cloudflare error must not be able to
  file adoptions, and it must not be able to look like the zone went quiet.
  """
  @spec refresh(String.t()) ::
          {:ok, %{added: non_neg_integer(), unchanged: non_neg_integer()}} | {:error, term()}
  def refresh(domain) when is_binary(domain) do
    with {:ok, report} <- Inventory.inventory(domain) do
      known = load()

      {entries, added} =
        Enum.reduce(report["unmanaged"], {known, 0}, fn record, {acc, added} ->
          id = entry_id(record)

          if Map.has_key?(acc, id) do
            {acc, added}
          else
            {Map.put(acc, id, new_entry(id, record)), added + 1}
          end
        end)

      with :ok <- save(entries) do
        {:ok, %{added: added, unchanged: length(report["unmanaged"]) - added}}
      end
    end
  end

  @doc "Entries in a given state, or all of them. Ordered by id for stable output."
  @spec list(:pending | :accepted | :rejected | :all) :: [entry()]
  def list(filter \\ :all) do
    load()
    |> Map.values()
    |> Enum.filter(fn entry -> filter == :all or entry["state"] == to_string(filter) end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc "Fetch one entry by id."
  @spec get(String.t()) :: entry() | nil
  def get(id) when is_binary(id), do: Map.get(load(), id)

  @doc """
  Accept a pending record: record the decision, then promote it into desired
  state so the monitor starts converging it.

  Both halves or neither. If the desired-state write fails the decision rolls
  back to pending, because "accepted but absent from desired state" is
  indistinguishable from a rejection at the next sync — the record would be
  silently dropped while the log said it was adopted.

  Deciding twice is a no-op returning the existing entry, not an error: the
  intent is already recorded, and failing would only make an idempotent workflow
  look broken. Promotion is idempotent too — a record already declared is left
  alone rather than duplicated.
  """
  @spec accept(String.t(), map()) :: {:ok, entry()} | {:error, term()}
  def accept(id, meta \\ %{}) do
    with {:ok, entry} <- decide(id, "accepted", meta) do
      case promote(entry) do
        :ok ->
          {:ok, entry}

        {:error, reason} ->
          rollback(id, entry)
          {:error, {:promotion_failed, reason}}
      end
    end
  end

  # --- promotion --------------------------------------------------------------

  # Already-decided entries reaching accept/2 a second time must not re-promote
  # and must not fail; the record is already declared.
  defp promote(%{"state" => "accepted", "record" => record}) do
    case DesiredStateStore.update(&declare(&1, record)) do
      {:ok, _doc} -> :ok
      {:error, :disabled} -> {:error, :desired_state_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp promote(_entry), do: :ok

  defp declare(doc, record) do
    entry = %{
      "domain" => record["domain"] || "",
      "name" => record["name"],
      "target" => record["content"] || "@",
      "proxied" => record["proxied"] || false,
      "ttl" => record["ttl"] || 1
    }

    update_in(doc, ["cloudflare", "cname_records"], fn declared ->
      declared = declared || []

      if Enum.any?(declared, &same_record?(&1, entry)) do
        declared
      else
        declared ++ [entry]
      end
    end)
  end

  defp same_record?(a, b) do
    String.downcase(to_string(a["name"])) == String.downcase(to_string(b["name"])) and
      to_string(a["domain"]) == to_string(b["domain"])
  end

  defp rollback(id, entry) do
    entries = load()

    restored =
      Map.merge(entry, %{
        "state" => "pending",
        "decided_at" => nil,
        "decided_by" => nil,
        "note" => nil
      })

    save(Map.put(entries, id, restored))
  end

  @doc "Reject a pending record. Durable: it never returns to pending."
  @spec reject(String.t(), map()) :: {:ok, entry()} | {:error, term()}
  def reject(id, meta \\ %{}), do: decide(id, "rejected", meta)

  @doc """
  The stable id for a record: `"<type>:<name>"`, lowercased.

  Derived rather than random, so rediscovering the same record maps to the same
  entry and a decision about it survives.
  """
  @spec entry_id(map()) :: String.t()
  def entry_id(record) do
    type = record["type"] |> to_string() |> String.downcase()
    name = record["name"] |> to_string() |> String.downcase()
    "#{type}:#{name}"
  end

  # Under the same volume the record snapshot uses, so a deployment that mounts
  # it gets persistent adoption decisions without configuring another path.
  @default_path "/var/lib/defdo_ddns/adoption.json"

  @doc "Where the adoption file lives."
  @spec path() :: String.t()
  def path do
    Application.get_env(:defdo_ddns, __MODULE__, [])
    |> Keyword.get(:path, System.get_env("DDNS_ADOPTION_PATH", @default_path))
  end

  # --- decisions --------------------------------------------------------------

  defp decide(id, state, meta) when state in @states do
    entries = load()

    case Map.get(entries, id) do
      nil ->
        {:error, :not_found}

      %{"state" => "pending"} = entry ->
        decided =
          Map.merge(entry, %{
            "state" => state,
            "decided_at" => timestamp(),
            "decided_by" => optional_string(meta[:by] || meta["by"]),
            "note" => optional_string(meta[:note] || meta["note"])
          })

        with :ok <- save(Map.put(entries, id, decided)) do
          {:ok, decided}
        end

      already_decided ->
        {:ok, already_decided}
    end
  end

  defp new_entry(id, record) do
    %{
      "id" => id,
      "record" => record,
      "state" => "pending",
      "first_seen" => timestamp(),
      "decided_at" => nil,
      "decided_by" => nil,
      "note" => nil
    }
  end

  # --- persistence ------------------------------------------------------------

  defp load do
    case path() do
      nil ->
        %{}

      file ->
        case File.read(file) do
          {:ok, binary} ->
            decode!(binary, file)

          {:error, :enoent} ->
            %{}

          {:error, reason} ->
            raise "unable to read DDNS adoption file #{file}: #{inspect(reason)}"
        end
    end
  end

  # A malformed file is a hard error, never a silent reset. Resetting would
  # discard every rejection, and the discarded records would come straight back
  # as pending on the next refresh — the one outcome this module exists to
  # prevent.
  defp decode!(binary, file) do
    case Jason.decode(binary) do
      {:ok, %{"entries" => entries}} when is_map(entries) -> entries
      {:ok, entries} when is_map(entries) -> entries
      _ -> raise "malformed DDNS adoption file #{file}: expected a JSON object of entries"
    end
  end

  defp save(entries) do
    case path() do
      nil ->
        Logger.warning("DDNS adoption store has no path configured; decisions are not persisted")
        :ok

      file ->
        payload = Jason.encode!(%{"entries" => entries}, pretty: true)
        temp = file <> ".tmp"

        with :ok <- File.mkdir_p(Path.dirname(file)),
             :ok <- File.write(temp, payload),
             # Rename is atomic on the same filesystem, so a crash mid-write
             # never leaves a half-written file where a decision used to be.
             :ok <- File.rename(temp, file) do
          :ok
        else
          {:error, reason} -> {:error, {:adoption_write_failed, reason}}
        end
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp optional_string(nil), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(value), do: to_string(value)
end

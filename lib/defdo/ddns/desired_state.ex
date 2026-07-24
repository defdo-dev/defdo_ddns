defmodule Defdo.DDNS.DesiredState do
  @moduledoc """
  Portable codec for the desired-state file: what DNS *should* look like.

  This is the contract that replaces reading intent out of environment
  variables. It is deliberately separate from `Defdo.DDNS.RecordSnapshot`, which
  captures what the runtime *observed* — conflating the two is how a snapshot of
  reality quietly becomes the definition of intent.

  Canonical shape:

      %{
        "version" => 1,
        "updated_at" => "2026-07-24T00:00:00Z",
        "cloudflare" => %{
          "domain_mappings" => %{"example.com" => ["www", "api"]},
          "aaaa_domain_mappings" => %{"example.com" => ["www"]},
          "cname_records" => [%{"domain" => ..., "name" => ..., "target" => ...,
                               "proxied" => true, "ttl" => 1}],
          "auto_create_missing_records" => true,
          "proxy_a_records" => true,
          "proxy_exclude" => ["internal.example.com"]
        }
      }

  Everything is string-keyed and deterministically ordered so the file diffs
  cleanly between runs and `String.to_atom/1` is never reachable from input.
  """

  @version 1

  @cname_keys ~w(domain name target proxied ttl)

  @type t :: map()

  @doc "The current file format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Build a canonical desired-state document from loose input.

  Accepts the shape this module emits, the inner `cloudflare` map on its own, or
  a keyword list in the shape `config :defdo_ddns, Cloudflare` uses — which is
  what makes seeding from the existing environment a one-liner.
  """
  @spec new(map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(input, opts \\ [])

  def new(input, opts) when is_list(input) do
    if Keyword.keyword?(input) do
      input |> Map.new(fn {k, v} -> {to_string(k), v} end) |> new(opts)
    else
      {:error, :desired_state_must_be_a_map}
    end
  end

  def new(input, opts) when is_map(input) do
    cloudflare = Map.get(input, "cloudflare", input)

    with {:ok, mappings} <- normalize_mappings(cloudflare, "domain_mappings"),
         {:ok, aaaa} <- normalize_mappings(cloudflare, "aaaa_domain_mappings"),
         {:ok, cnames} <- normalize_cname_records(Map.get(cloudflare, "cname_records", [])),
         {:ok, updated_at} <- resolve_updated_at(opts) do
      {:ok,
       %{
         "version" => @version,
         "updated_at" => updated_at,
         "cloudflare" => %{
           "domain_mappings" => mappings,
           "aaaa_domain_mappings" => aaaa,
           "cname_records" => cnames,
           "auto_create_missing_records" =>
             boolean(Map.get(cloudflare, "auto_create_missing_records"), false),
           "proxy_a_records" => boolean(Map.get(cloudflare, "proxy_a_records"), false),
           "proxy_exclude" => string_list(Map.get(cloudflare, "proxy_exclude", []))
         }
       }}
    end
  end

  def new(_input, _opts), do: {:error, :desired_state_must_be_a_map}

  @doc "Validate a decoded document, rejecting anything not in canonical shape."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%{"version" => version, "cloudflare" => cloudflare} = doc)
      when is_integer(version) and is_map(cloudflare) do
    cond do
      version > @version -> {:error, {:unsupported_version, version}}
      true -> new(doc, updated_at: Map.get(doc, "updated_at"))
    end
  end

  def validate(doc) when is_map(doc), do: {:error, :missing_version_or_cloudflare}
  def validate(_doc), do: {:error, :desired_state_must_be_a_map}

  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(doc) when is_map(doc) do
    case Jason.encode(doc, pretty: true) do
      {:ok, binary} -> {:ok, binary <> "\n"}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  def encode(_doc), do: {:error, :desired_state_must_be_a_map}

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, doc} -> validate(doc)
      {:error, _reason} -> {:error, :malformed_desired_state}
    end
  end

  def decode(_binary), do: {:error, :desired_state_must_be_binary}

  @doc """
  Counts by kind, safe to log.

  Never returns hostnames, targets or flag values — a desired-state file names
  every host in the estate, so "how many" is the most that may reach a log line.
  """
  @spec safe_summary(t()) :: map()
  def safe_summary(%{"cloudflare" => cf} = doc) do
    %{
      "version" => Map.get(doc, "version"),
      "updated_at" => Map.get(doc, "updated_at"),
      "domains" => map_size(Map.get(cf, "domain_mappings", %{})),
      "aaaa_domains" => map_size(Map.get(cf, "aaaa_domain_mappings", %{})),
      "a_hostnames" => count_hostnames(Map.get(cf, "domain_mappings", %{})),
      "aaaa_hostnames" => count_hostnames(Map.get(cf, "aaaa_domain_mappings", %{})),
      "cname_records" => length(Map.get(cf, "cname_records", []))
    }
  end

  def safe_summary(_doc), do: %{}

  defp count_hostnames(mappings) when is_map(mappings) do
    Enum.reduce(mappings, 0, fn {_domain, hosts}, acc -> acc + length(hosts) end)
  end

  defp count_hostnames(_mappings), do: 0

  # --- normalization ----------------------------------------------------------

  defp normalize_mappings(cloudflare, key) do
    case Map.get(cloudflare, key, %{}) do
      map when is_map(map) ->
        normalized =
          map
          |> Enum.map(fn {domain, hosts} -> {to_string(domain), string_list(hosts)} end)
          |> Enum.reject(fn {domain, _hosts} -> domain == "" end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Map.new()

        {:ok, normalized}

      other ->
        {:error, {:invalid_mappings, key, type_of(other)}}
    end
  end

  defp normalize_cname_records(records) when is_list(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case normalize_cname_record(record) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} ->
        {:ok, Enum.sort_by(Enum.reverse(list), &{&1["domain"], &1["name"]})}

      error ->
        error
    end
  end

  defp normalize_cname_records(other), do: {:error, {:invalid_cname_records, type_of(other)}}

  defp normalize_cname_record(record) when is_map(record) do
    get = fn key -> Map.get(record, key) || Map.get(record, String.to_existing_atom(key)) end

    name = trimmed(get.("name"))
    target = trimmed(get.("target") || get.("content"))

    cond do
      is_nil(name) ->
        {:error, :missing_cname_name}

      is_nil(target) ->
        {:error, :missing_cname_target}

      true ->
        {:ok,
         %{
           "domain" => trimmed(get.("domain")) || "",
           "name" => name,
           "target" => target,
           "proxied" => boolean(get.("proxied"), false),
           "ttl" => ttl(get.("ttl"))
         }
         |> Map.take(@cname_keys)}
    end
  end

  defp normalize_cname_record(other), do: {:error, {:invalid_cname_record, type_of(other)}}

  defp resolve_updated_at(opts) do
    case Keyword.get(opts, :updated_at) do
      nil -> {:ok, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_updated_at, type_of(other)}}
    end
  end

  # --- coercion ---------------------------------------------------------------

  defp string_list(value) when is_list(value) do
    value
    |> Enum.map(&trimmed/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp string_list(nil), do: []
  defp string_list(value) when is_binary(value), do: string_list(String.split(value, ","))
  defp string_list(_value), do: []

  defp trimmed(nil), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(value), do: value |> to_string() |> trimmed()

  defp boolean(true, _default), do: true
  defp boolean(false, _default), do: false
  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean(nil, default), do: default
  defp boolean(_other, default), do: default

  defp ttl(value) when is_integer(value) and value > 0, do: value

  defp ttl(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp ttl(_value), do: 1

  defp type_of(value) when is_map(value), do: :map
  defp type_of(value) when is_list(value), do: :list
  defp type_of(value) when is_binary(value), do: :string
  defp type_of(nil), do: :nil_value
  defp type_of(_value), do: :unknown
end

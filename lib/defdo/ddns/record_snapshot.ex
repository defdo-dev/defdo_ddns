defmodule Defdo.DDNS.RecordSnapshot do
  @moduledoc """
  Portable snapshot codec for DDNS records.

  This module owns the canonical DDNS record shape and the JSON snapshot
  interchange format so stores and future adapters can share the same rules.
  """

  @snapshot_version 1
  @default_provider "cloudflare"

  @type record :: %{required(String.t()) => any()}
  @type snapshot :: %{required(String.t()) => any()}

  @spec new([record()], keyword()) :: {:ok, snapshot()} | {:error, term()}
  def new(records, opts \\ []) do
    with {:ok, normalized_records} <- normalize_records(records, opts),
         {:ok, updated_at} <- resolve_updated_at(opts) do
      {:ok, build_snapshot(normalized_records, updated_at)}
    end
  end

  @spec normalize_records([record()], keyword()) :: {:ok, [record()]} | {:error, term()}
  def normalize_records(records, opts \\ [])

  def normalize_records(records, opts) when is_list(records) do
    source = Keyword.get(opts, :source, :snapshot)
    default_provider = Keyword.get(opts, :default_provider, @default_provider)

    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case normalize_record(record, source, default_provider) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_records} -> {:ok, Enum.reverse(normalized_records)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_records(_records, _opts), do: {:error, :records_must_be_a_list}

  @spec validate_snapshot(map() | any(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def validate_snapshot(snapshot, opts \\ [])

  def validate_snapshot(snapshot, opts) when is_map(snapshot) do
    version = snapshot_value(snapshot, "version")
    updated_at = snapshot_value(snapshot, "updated_at")
    records = snapshot_value(snapshot, "records")

    cond do
      version != @snapshot_version ->
        {:error, {:unsupported_snapshot_version, version}}

      not valid_updated_at?(updated_at) ->
        {:error, :invalid_snapshot_updated_at}

      not is_list(records) ->
        {:error, :invalid_snapshot_records}

      true ->
        case normalize_records(records, opts) do
          {:ok, normalized_records} ->
            {:ok, build_snapshot(normalized_records, updated_at)}

          {:error, reason} ->
            {:error, {:invalid_snapshot_record, reason}}
        end
    end
  end

  def validate_snapshot(_snapshot, _opts), do: {:error, :snapshot_must_be_a_map}

  @spec encode(snapshot(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def encode(snapshot, opts \\ []) do
    with {:ok, canonical_snapshot} <- validate_snapshot(snapshot, opts),
         {:ok, encoded} <- Jason.encode(canonical_snapshot) do
      {:ok, encoded}
    end
  end

  @spec decode(String.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) do
    case Jason.decode(String.trim(binary)) do
      {:ok, decoded} ->
        validate_snapshot(decoded, opts)

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  def decode(_binary, _opts), do: {:error, :snapshot_must_be_binary}

  @spec from_legacy_cname_records([record()], keyword()) :: {:ok, snapshot()} | {:error, term()}
  def from_legacy_cname_records(records, opts \\ []) do
    opts = Keyword.put(opts, :source, :legacy_cname)

    with {:ok, normalized_records} <- normalize_records(records, opts),
         {:ok, updated_at} <- resolve_updated_at(opts) do
      {:ok, build_snapshot(normalized_records, updated_at)}
    end
  end

  @spec from_legacy_cname_env(String.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def from_legacy_cname_env(binary, opts \\ [])

  def from_legacy_cname_env(binary, opts) when is_binary(binary) do
    with {:ok, legacy_records} <- decode_legacy_env(binary),
         {:ok, snapshot} <- from_legacy_cname_records(legacy_records, opts) do
      {:ok, snapshot}
    end
  end

  def from_legacy_cname_env(_binary, _opts), do: {:error, :legacy_env_must_be_binary}

  defp decode_legacy_env(binary) do
    case Jason.decode(String.trim(binary)) do
      {:ok, decoded} ->
        legacy_env_records(decoded)

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp legacy_env_records(records) when is_list(records), do: {:ok, records}
  defp legacy_env_records(%{"records" => records}) when is_list(records), do: {:ok, records}
  defp legacy_env_records(%{records: records}) when is_list(records), do: {:ok, records}
  defp legacy_env_records(_), do: {:error, :legacy_env_must_be_a_list}

  defp normalize_record(record, source, default_provider) when is_map(record) do
    provider = normalize_optional_string(value(record, "provider")) || default_provider
    domain = normalize_optional_string(value(record, "domain"))
    type = normalize_type(value(record, "type"), source)
    name = normalize_required_string(value(record, "name"))
    content = normalize_optional_string(value(record, "content") || value(record, "target"))
    ttl = normalize_ttl(value(record, "ttl"))
    proxied = normalize_proxied(value(record, "proxied"))
    metadata = normalize_metadata(value(record, "metadata"))

    cond do
      is_nil(type) ->
        {:error, :missing_record_type}

      is_nil(name) ->
        {:error, :missing_record_name}

      is_nil(content) ->
        {:error, :missing_record_content}

      metadata == :invalid ->
        {:error, :invalid_record_metadata}

      true ->
        {:ok,
         %{
           "provider" => provider,
           "domain" => domain,
           "type" => type,
           "name" => name,
           "content" => content,
           "ttl" => ttl,
           "proxied" => proxied,
           "metadata" => metadata
         }}
    end
  end

  defp normalize_record(_record, _source, _default_provider), do: {:error, :record_must_be_a_map}

  defp normalize_type(nil, :legacy_cname), do: "CNAME"
  defp normalize_type(nil, _source), do: nil

  defp normalize_type(value, _source) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> nil
      type -> type
    end
  end

  defp normalize_type(value, _source) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.upcase()
  end

  defp normalize_type(_value, _source), do: nil

  defp normalize_required_string(value) do
    case normalize_optional_string(value) do
      nil -> nil
      string -> string
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.trim()
    |> case do
      "" -> nil
      string -> string
    end
  end

  defp normalize_optional_string(value) when is_integer(value) do
    Integer.to_string(value)
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_ttl(value) when is_integer(value) and value > 0, do: value

  defp normalize_ttl(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_ttl(_value), do: nil

  defp normalize_proxied(nil), do: nil
  defp normalize_proxied(value) when is_boolean(value), do: value

  defp normalize_proxied(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> Kernel.in(["true", "1", "yes", "on"])
  end

  defp normalize_proxied(_value), do: nil

  defp normalize_metadata(nil), do: %{}
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: :invalid

  defp build_snapshot(records, updated_at) do
    %{
      "version" => @snapshot_version,
      "updated_at" => updated_at,
      "records" => records
    }
  end

  defp resolve_updated_at(opts) do
    case Keyword.get(opts, :updated_at) do
      nil ->
        {:ok, current_timestamp()}

      value when is_binary(value) ->
        normalized = String.trim(value)

        case valid_updated_at?(normalized) do
          true -> {:ok, normalized}
          false -> {:error, :invalid_updated_at}
        end

      _ ->
        {:error, :invalid_updated_at}
    end
  end

  defp valid_updated_at?(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, _datetime, _offset} -> true
      _ -> false
    end
  end

  defp valid_updated_at?(_value), do: false

  defp current_timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp snapshot_value(snapshot, key) when is_map(snapshot) and is_binary(key) do
    cond do
      Map.has_key?(snapshot, key) ->
        Map.get(snapshot, key)

      Map.has_key?(snapshot, key_to_atom(key)) ->
        Map.get(snapshot, key_to_atom(key))

      true ->
        nil
    end
  end

  defp snapshot_value(_snapshot, _key), do: nil

  defp value(record, key) when is_map(record) and is_binary(key) do
    cond do
      Map.has_key?(record, key) ->
        Map.get(record, key)

      Map.has_key?(record, key_to_atom(key)) ->
        Map.get(record, key_to_atom(key))

      true ->
        nil
    end
  end

  defp value(_record, _key), do: nil

  defp key_to_atom("provider"), do: :provider
  defp key_to_atom("domain"), do: :domain
  defp key_to_atom("type"), do: :type
  defp key_to_atom("name"), do: :name
  defp key_to_atom("content"), do: :content
  defp key_to_atom("target"), do: :target
  defp key_to_atom("ttl"), do: :ttl
  defp key_to_atom("proxied"), do: :proxied
  defp key_to_atom("metadata"), do: :metadata
  defp key_to_atom("version"), do: :version
  defp key_to_atom("updated_at"), do: :updated_at
  defp key_to_atom("records"), do: :records
  defp key_to_atom(_), do: nil
end

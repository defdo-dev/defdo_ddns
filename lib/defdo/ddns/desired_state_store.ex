defmodule Defdo.DDNS.DesiredStateStore do
  @moduledoc """
  File-backed owner of DDNS desired state.

  The file is authoritative once it exists. Environment variables are a seed for
  the first boot and nothing more — leaving them as a live fallback is how two
  sources of truth appear and quietly disagree.

  ## No process

  The slice specified starting this before the monitor. It is implemented as an
  on-demand reader instead, with no entry in the supervision tree, for one
  reason: a store that "fails loudly" at boot is a new way for the application to
  die on startup and stay dead. That is exactly the failure 0.3.4 fixed, where a
  transient Cloudflare error killed the monitor, exhausted the restart intensity
  and shut everything down unnoticed for eleven days. Reading a small file on a
  five-minute tick costs nothing and cannot brick a boot.

  "Fails loudly" is therefore scoped: it is an error from `load/0` and `seed/0`,
  raised where a caller asked for desired state, not where the release starts.

  ## Disabled by default

  With no `DDNS_DESIRED_STATE_PATH` configured the store reports `:disabled` and
  callers fall back to the existing env-driven accessors. Adoption of the file is
  opt-in per deployment rather than a flag day.
  """

  require Logger

  alias Defdo.DDNS.DesiredState

  @default_path "/var/lib/defdo_ddns/desired_state.json"

  @doc "Configured file path, or nil when the store is disabled."
  @spec path() :: String.t() | nil
  def path do
    case config(:path, System.get_env("DDNS_DESIRED_STATE_PATH")) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc "Whether a desired-state file is configured for this deployment."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(path())

  @doc """
  Read desired state.

  * `{:ok, doc}` — the file exists and is canonical.
  * `{:error, :disabled}` — no path configured; callers use the env accessors.
  * `{:error, :missing_desired_state}` — a path is configured, there is no file,
    and there is nothing in the environment to seed from. Loud on purpose:
    treating "no intent anywhere" as an empty document would silently unmanage
    every record in the estate. When the file is absent but the environment does
    carry config, the file is seeded from it on this first read (see
    `seed_on_missing/1`) — the release runs no `mix`, so this is what lets a
    fresh deployment produce the file without an operator step.
  """
  @spec load() :: {:ok, DesiredState.t()} | {:error, term()}
  def load do
    case path() do
      nil ->
        {:error, :disabled}

      file ->
        case File.read(file) do
          {:ok, binary} ->
            DesiredState.decode(binary)

          {:error, :enoent} ->
            # Lazy seed on first read. The slice wanted the file written from env
            # on a first boot with a seed present; doing it here rather than in a
            # boot process keeps the "no supervision entry" property — a seed
            # failure returns an error to the caller instead of failing the
            # release to start. Only reachable when the file is absent, so it
            # never overwrites a file someone edited.
            seed_on_missing(file)

          {:error, reason} ->
            {:error, {:desired_state_unreadable, reason}}
        end
    end
  end

  defp seed_on_missing(file) do
    if env_seedable?() do
      case seed() do
        {:ok, doc} ->
          {:ok, doc}

        # A racing writer created the file between the read and the seed; read it.
        {:error, :already_seeded} ->
          reread(file)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :missing_desired_state}
    end
  end

  defp reread(file) do
    case File.read(file) do
      {:ok, binary} -> DesiredState.decode(binary)
      {:error, reason} -> {:error, {:desired_state_unreadable, reason}}
    end
  end

  defp env_seedable? do
    cf = env_config()

    map_size(Map.get(cf, "domain_mappings", %{}) |> to_map()) > 0 or
      map_size(Map.get(cf, "aaaa_domain_mappings", %{}) |> to_map()) > 0 or
      length(List.wrap(Map.get(cf, "cname_records", []))) > 0
  end

  defp to_map(v) when is_map(v), do: v
  defp to_map(_), do: %{}

  @doc """
  Write the file from the current environment configuration, once.

  Refuses when the file already exists: the file is authoritative, and silently
  overwriting it from env would resurrect whatever the env still says long after
  someone edited the file deliberately. Pass `force: true` to re-seed knowingly.
  """
  @spec seed(keyword()) :: {:ok, DesiredState.t()} | {:error, term()}
  def seed(opts \\ []) do
    with {:ok, file} <- require_path(),
         :ok <- refuse_existing(file, Keyword.get(opts, :force, false)),
         {:ok, doc} <- DesiredState.new(env_config()),
         :ok <- write(file, doc) do
      Logger.info(
        "DDNS desired state seeded from environment #{inspect(DesiredState.safe_summary(doc))}"
      )

      {:ok, doc}
    end
  end

  @doc "Persist a document, replacing whatever is on disk."
  @spec persist(DesiredState.t()) :: {:ok, DesiredState.t()} | {:error, term()}
  def persist(doc) do
    with {:ok, file} <- require_path(),
         {:ok, canonical} <- DesiredState.new(doc),
         :ok <- write(file, canonical) do
      {:ok, canonical}
    end
  end

  @doc """
  Read, transform, write — the path every mutation takes, including adoption
  promoting a record into desired state.
  """
  @spec update((DesiredState.t() -> DesiredState.t())) ::
          {:ok, DesiredState.t()} | {:error, term()}
  def update(fun) when is_function(fun, 1) do
    with {:ok, doc} <- load() do
      persist(fun.(doc))
    end
  end

  @doc """
  Declare a CNAME record as managed. Idempotent.

  Two paths reach this: adoption promoting a record an operator accepted, and
  the provisioning API declaring a record this deployment just created. They
  must write the entry identically — if the shapes diverged, the same record
  could be declared twice, or fail to match itself on the next reconcile and
  reappear as drift. Sharing one function is what prevents that.

  Returns `{:error, :disabled}` when no desired-state file is configured, which
  callers are expected to treat as "nothing to record", not as a failure.
  """
  @spec declare(map()) :: {:ok, DesiredState.t()} | {:error, term()}
  def declare(record) when is_map(record) do
    entry = entry_for(record)

    case load() do
      {:ok, doc} ->
        persist(put_cname(doc, entry))

      # `load/0` refuses to treat a missing file as an empty document, and it is
      # right to: for a *read*, "no intent anywhere" would silently unmanage the
      # whole estate. A declaration is the opposite operation — it adds a fact
      # rather than inferring the absence of one — so starting from an empty
      # document is correct here, and it is the only way the first record a
      # fresh deployment provisions actually gets recorded.
      {:error, :missing_desired_state} ->
        with {:ok, empty} <- DesiredState.new(%{}) do
          persist(put_cname(empty, entry))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp entry_for(record) do
    %{
      "domain" => record["domain"] || "",
      "name" => record["name"],
      "target" => record["content"] || "@",
      "proxied" => record["proxied"] || false,
      "ttl" => record["ttl"] || 1
    }
  end

  defp put_cname(doc, entry) do
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

  @doc "Counts and metadata only — never hostnames, targets or flag values."
  @spec status() :: map()
  def status do
    case load() do
      {:ok, doc} ->
        Map.merge(%{"state" => "loaded", "path" => path()}, DesiredState.safe_summary(doc))

      {:error, :disabled} ->
        %{"state" => "disabled"}

      {:error, reason} ->
        %{"state" => "error", "path" => path(), "reason" => inspect(reason)}
    end
  end

  # --- internals --------------------------------------------------------------

  defp require_path do
    case path() do
      nil -> {:error, :disabled}
      file -> {:ok, file}
    end
  end

  defp refuse_existing(file, force) do
    cond do
      force -> :ok
      File.exists?(file) -> {:error, :already_seeded}
      true -> :ok
    end
  end

  # Temp file plus rename: atomic on the same filesystem, so a crash mid-write
  # never leaves a truncated file where the estate's intent used to be.
  defp write(file, doc) do
    with {:ok, binary} <- DesiredState.encode(doc),
         :ok <- File.mkdir_p(Path.dirname(file)),
         temp = file <> ".tmp",
         :ok <- File.write(temp, binary),
         :ok <- File.rename(temp, file) do
      :ok
    else
      {:error, reason} -> {:error, {:desired_state_write_failed, reason}}
    end
  end

  defp env_config do
    Application.get_env(:defdo_ddns, Cloudflare, [])
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
    |> Map.take(~w(domain_mappings aaaa_domain_mappings cname_records
                   auto_create_missing_records proxy_a_records proxy_exclude))
  end

  defp config(key, default) do
    Application.get_env(:defdo_ddns, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  @doc "The default path a deployment should use when it adopts the file."
  @spec default_path() :: String.t()
  def default_path, do: @default_path
end

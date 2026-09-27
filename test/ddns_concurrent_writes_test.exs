defmodule Defdo.DDNS.ConcurrentWritesTest do
  @moduledoc """
  Acceptance for `ddns-service-hardening` slice H03.

  Both JSON stores did an unserialized read-modify-write through a shared
  `<file>.tmp`. Measured before the fix: 40 concurrent declarations returned
  2 `:ok` / 38 errors and left one record on disk.
  """
  use ExUnit.Case, async: false

  alias Defdo.DDNS.Adoption
  alias Defdo.DDNS.DesiredStateStore
  alias Defdo.DDNS.FileLock

  setup do
    previous_cloudflare = Application.get_env(:defdo_ddns, Cloudflare)
    previous_store = Application.get_env(:defdo_ddns, DesiredStateStore)
    previous_adoption = Application.get_env(:defdo_ddns, Adoption)

    dir = Path.join(System.tmp_dir!(), "ddns-concurrent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Application.put_env(:defdo_ddns, Cloudflare, [])

    Application.put_env(:defdo_ddns, DesiredStateStore,
      path: Path.join(dir, "desired_state.json")
    )

    Application.put_env(:defdo_ddns, Adoption, path: Path.join(dir, "adoption.json"))

    on_exit(fn ->
      File.rm_rf(dir)
      restore(Cloudflare, previous_cloudflare)
      restore(DesiredStateStore, previous_store)
      restore(Adoption, previous_adoption)
    end)

    {:ok, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:defdo_ddns, key)
  defp restore(key, value), do: Application.put_env(:defdo_ddns, key, value)

  defp declare_concurrently(range) do
    range
    |> Task.async_stream(
      fn i ->
        DesiredStateStore.declare(%{
          "domain" => "example.com",
          "name" => "h#{i}.example.com",
          "content" => "example.com",
          "proxied" => true,
          "ttl" => 1
        })
      end,
      max_concurrency: Enum.count(range),
      timeout: 30_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  test "40 concurrent declarations all persist" do
    results = declare_concurrently(1..40)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           inspect(Enum.frequencies_by(results, &elem(&1, 0)))

    assert {:ok, doc} = DesiredStateStore.load()
    assert length(doc["cloudflare"]["cname_records"]) == 40
  end

  test "concurrent rejections are all recorded" do
    entries =
      Map.new(1..30, fn i ->
        id = "cname:h#{i}.example.com"

        {id,
         %{
           "id" => id,
           "state" => "pending",
           "record" => %{"type" => "CNAME", "name" => "h#{i}.example.com"},
           "first_seen" => "2026-01-01T00:00:00Z",
           "decided_at" => nil,
           "decided_by" => nil,
           "note" => nil
         }}
      end)

    File.write!(Adoption.path(), Jason.encode!(%{"entries" => entries}))

    entries
    |> Map.keys()
    |> Task.async_stream(&Adoption.reject(&1, %{"by" => "test"}), max_concurrency: 30)
    |> Stream.run()

    assert length(Adoption.list(:rejected)) == 30
    assert Adoption.list(:pending) == []
  end

  test "no temp files are left behind", %{dir: dir} do
    declare_concurrently(1..20)

    assert Path.wildcard(Path.join(dir, "*.tmp")) == []
  end

  test "the lock is re-entrant", %{dir: dir} do
    path = Path.join(dir, "lock-target")

    assert FileLock.with_lock(path, fn -> FileLock.with_lock(path, fn -> :inner end) end) ==
             :inner
  end

  test "the lock excludes concurrent holders", %{dir: dir} do
    path = Path.join(dir, "lock-target")
    inside = :counters.new(1, [])
    max_seen = :counters.new(1, [])

    1..20
    |> Task.async_stream(
      fn _ ->
        FileLock.with_lock(path, fn ->
          :counters.add(inside, 1, 1)
          now = :counters.get(inside, 1)
          if now > :counters.get(max_seen, 1), do: :counters.put(max_seen, 1, now)
          Process.sleep(2)
          :counters.sub(inside, 1, 1)
        end)
      end,
      max_concurrency: 20
    )
    |> Stream.run()

    assert :counters.get(max_seen, 1) == 1
  end
end

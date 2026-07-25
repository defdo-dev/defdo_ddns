defmodule Mix.Tasks.Defdo.Ddns.Adoption.Reject do
  @shortdoc "Refuse a discovered record, permanently"

  @moduledoc """
      mix defdo.ddns.adoption.reject <id> [--by NAME] [--note TEXT]

  The record stays in Cloudflare — nothing here deletes anything — but DDNS stops
  offering it for adoption. The decision is durable: it never returns to pending,
  which is what keeps the list worth reading.
  """
  use Mix.Task

  alias Defdo.DDNS.Adoption
  alias Defdo.DDNS.Adoption.Reporter

  @impl Mix.Task
  def run([id | rest]) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(rest, strict: [by: :string, note: :string])

    case Adoption.reject(id, Map.new(opts)) do
      {:ok, entry} ->
        Mix.shell().info("rejected:")
        Reporter.render_entry(entry)

      {:error, :not_found} ->
        Mix.raise("no adoption entry with id #{id}")

      {:error, reason} ->
        Mix.raise("reject failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix defdo.ddns.adoption.reject <id> [--by N] [--note T]")
end

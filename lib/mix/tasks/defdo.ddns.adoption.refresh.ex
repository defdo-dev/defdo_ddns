defmodule Mix.Tasks.Defdo.Ddns.Adoption.Refresh do
  @shortdoc "Discover Cloudflare records that exist but were never declared"

  @moduledoc """
  Run an inventory of a zone and file every undeclared record as pending.

      mix defdo.ddns.adoption.refresh defdo.ninja

  Read-only against Cloudflare: it never creates, updates or deletes a record.
  Records already known — in any state — are left untouched, so a record that was
  rejected once does not come back to be asked about again.
  """
  use Mix.Task

  alias Defdo.DDNS.Adoption

  @impl Mix.Task
  def run([domain]) do
    Mix.Task.run("app.start")

    case Adoption.refresh(domain) do
      {:ok, %{added: added, unchanged: unchanged}} ->
        Mix.shell().info("#{domain}: #{added} new, #{unchanged} already known")
        Defdo.DDNS.Adoption.Reporter.render(:pending)

      {:error, reason} ->
        # Nothing was written; the zone is simply unknown right now.
        Mix.raise("refresh failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix defdo.ddns.adoption.refresh <domain>")
end

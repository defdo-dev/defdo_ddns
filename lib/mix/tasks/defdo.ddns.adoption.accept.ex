defmodule Mix.Tasks.Defdo.Ddns.Adoption.Accept do
  @shortdoc "Adopt a discovered record into desired state"

  @moduledoc """
      mix defdo.ddns.adoption.accept <id> [--by NAME] [--note TEXT]

  Records the decision and declares the record, atomically — from here the
  monitor converges it like any other. If the desired-state write fails the
  decision rolls back to pending rather than leaving a record marked adopted that
  nothing actually manages.

  Ids come from `mix defdo.ddns.adoption.list`, e.g. `cname:foss.defdo.ninja`.
  """
  use Mix.Task

  alias Defdo.DDNS.Adoption
  alias Defdo.DDNS.Adoption.Reporter

  @impl Mix.Task
  def run([id | rest]) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(rest, strict: [by: :string, note: :string])

    case Adoption.accept(id, Map.new(opts)) do
      {:ok, entry} ->
        Mix.shell().info("accepted and declared:")
        Reporter.render_entry(entry)

      {:error, :not_found} ->
        Mix.raise("no adoption entry with id #{id}")

      {:error, {:promotion_failed, reason}} ->
        Mix.raise("could not declare the record (left pending): #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("accept failed: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix defdo.ddns.adoption.accept <id> [--by N] [--note T]")
end

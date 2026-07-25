defmodule Defdo.DDNS.Adoption.Reporter do
  @moduledoc """
  Shared rendering for the adoption mix tasks.

  Redaction is the reason this is one module rather than three copies. An
  adoption list names every host somebody stood up; the target it points at is
  the part that reveals infrastructure, so it is truncated everywhere rather
  than in whichever task remembered to.
  """

  alias Defdo.DDNS.Adoption

  @doc "One line per entry: state, type, name, when it was first seen."
  @spec render(:pending | :accepted | :rejected | :all) :: :ok
  def render(filter) do
    case Adoption.list(filter) do
      [] ->
        say("no #{filter} records")

      entries ->
        Enum.each(entries, &say(line(&1)))
        say("")
        say("#{length(entries)} #{filter} record(s)")
    end

    :ok
  end

  @doc "Render a single decided entry, for accept/reject output."
  @spec render_entry(map()) :: :ok
  def render_entry(entry), do: say(line(entry))

  defp line(entry) do
    record = entry["record"] || %{}

    [
      String.pad_trailing(entry["state"] || "?", 9),
      String.pad_trailing(record["type"] || "?", 6),
      String.pad_trailing(record["name"] || entry["id"], 34),
      "-> " <> redact(record["content"]),
      "  first seen " <> (entry["first_seen"] || "?"),
      decided_by(entry)
    ]
    |> Enum.join("")
  end

  defp decided_by(%{"decided_by" => by}) when is_binary(by), do: "  by " <> by
  defp decided_by(_entry), do: ""

  # Enough to tell two targets apart, not enough to map the estate from a log.
  defp redact(nil), do: "-"

  defp redact(content) when is_binary(content) do
    case String.length(content) do
      n when n <= 12 -> content
      _ -> String.slice(content, 0, 12) <> "…"
    end
  end

  defp redact(other), do: inspect(other)

  defp say(message), do: Mix.shell().info(message)
end

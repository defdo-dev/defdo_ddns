defmodule Mix.Tasks.Defdo.Ddns.Adoption.List do
  @shortdoc "List discovered records awaiting or holding a decision"

  @moduledoc """
      mix defdo.ddns.adoption.list [--state pending|accepted|rejected|all]

  Defaults to `pending` — the list that needs someone to act. Targets are
  truncated: this names every host somebody stood up, and the target is the part
  that maps the estate.
  """
  use Mix.Task

  alias Defdo.DDNS.Adoption.Reporter

  @states ~w(pending accepted rejected all)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [state: :string])
    state = Keyword.get(opts, :state, "pending")

    unless state in @states do
      Mix.raise("unknown --state #{state}; expected one of: #{Enum.join(@states, ", ")}")
    end

    Reporter.render(String.to_existing_atom(state))
  end
end

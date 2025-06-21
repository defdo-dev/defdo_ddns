defmodule Defdo.DDNS.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :defdo_ddns,
      version: "0.2.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      releases: [
        defdo_ddns: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Defdo.DDNS.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.3"},
      {:req, "~> 0.5.0"}
    ]
  end
end

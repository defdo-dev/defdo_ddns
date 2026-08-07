defmodule Defdo.DDNS.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :defdo_ddns,
      version: "0.5.1",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
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
      # Req is the only HTTP client here. The pin was `~> 0.5.0`, which locked
      # out every fix after 0.5.x — the advisories on 0.5.10 have no patch
      # inside that range.
      {:req, "~> 0.6"},
      {:plug, "~> 1.18"},
      {:bandit, "~> 1.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # No mox, no bypass: neither appeared in a single test. bypass was the only
  # thing pulling plug_cowboy -> cowboy -> cowlib, a second HTTP server stack
  # carried purely to be unused. Bandit serves, Req calls out; nothing else
  # speaks HTTP here.

  defp description do
    "Cloudflare DDNS updater for A/AAAA/CNAME records with proxy-aware synchronization."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/defdo-dev/defdo_ddns",
        "Changelog" => "https://github.com/defdo-dev/defdo_ddns/blob/main/CHANGELOG.md"
      },
      maintainers: ["defdo-dev"],
      files: ~w(lib config mix.exs mix.lock README.md CHANGELOG.md LICENSE.md .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

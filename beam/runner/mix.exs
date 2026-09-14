defmodule BeamRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_runner,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BeamRunner.Application, []}
    ]
  end

  defp deps do
    [
      # The Elixir sidecar under test — always the current main, matching the
      # harness' no-drift philosophy (nothing vendored, nothing pinned).
      {:odoshi_beam, git: "https://github.com/shishi-odoshi/beam.git", branch: "main"}
    ]
  end
end

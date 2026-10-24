defmodule Detchi.MixProject do
  use Mix.Project

  def project do
    [
      app: :detchi,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Detchi.Application, []}
    ]
  end

  defp deps do
    [
      {:yamerl, "~> 0.10"}
    ]
  end

  # app: nil keeps the escript from starting :detchi before main/1;
  # only `detchi run` starts the application (docs/basic-design.md, 3).
  defp escript do
    [main_module: Detchi.CLI, name: "detchi", app: nil]
  end

  # Tests start the application themselves, as `detchi run` does.
  defp aliases do
    [test: "test --no-start"]
  end
end

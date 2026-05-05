# Release steps:
# 1. mix deps.update ex_doc
# 2. Update version, CHANGELOG, commit, and push tag
# 3. Once CI finishes, run MIX_ENV=prod mix elixir_make.checksum --all
# 4. Publish to Hex with MIX_ENV=docs mix hex.publish
# 5. Add -dev version back
defmodule Adbc.MixProject do
  use Mix.Project

  @version "0.12.1"
  @github_url "https://github.com/elixir-explorer/adbc"

  def project do
    [
      app: :adbc,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description: "Apache Arrow ADBC bindings for Elixir",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_env: fn -> %{"FINE_INCLUDE_DIR" => Fine.include_dir()} end
    ] ++ precompiled()
  end

  defp precompiled do
    if System.get_env("ADBC_BUILD") in ["1", "true"] do
      []
    else
      [
        make_precompiler: {:nif, CCPrecompiler},
        make_precompiler_url:
          "#{@github_url}/releases/download/v#{@version}/@{artefact_filename}",
        make_precompiler_filename: "adbc_nif",
        make_precompiler_priv_paths: [
          "adbc_nif.*",
          "adbc_dll_loader.dll",
          "bin",
          "lib",
          "include"
        ],
        make_precompiler_nif_versions: [versions: ["2.17"]],
        cc_precompiler: [
          cleanup: "clean",
          compilers: %{
            {:unix, :linux} => %{
              "x86_64-linux-gnu" => {
                "x86_64-linux-gnu-gcc",
                "x86_64-linux-gnu-g++"
              },
              "aarch64-linux-gnu" => {
                "aarch64-linux-gnu-gcc",
                "aarch64-linux-gnu-g++"
              }
            },
            {:unix, :darwin} => %{
              :include_default_ones => true
            },
            {:win32, :nt} => %{
              :include_default_ones => true
            }
          }
        ]
      ]
    end
  end

  def application do
    [
      extra_applications: [:logger, inets: :optional, ssl: :optional]
    ]
  end

  defp deps do
    [
      # compilation
      {:cc_precompiler, "~> 0.1.8 or ~> 0.2", runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},

      # nif
      {:fine, "~> 0.1.0", runtime: false},

      # runtime
      {:decimal, "~> 2.1 or ~> 3.0"},
      {:table, "~> 0.1.2"},
      {:pythonx, "~> 0.4.0", optional: true},

      # docs
      {:ex_doc, "~> 0.29", only: :docs, runtime: false}
    ]
  end

  defp docs do
    [
      main: "Adbc.Database",
      source_ref: "v#{@version}",
      source_url: @github_url,
      groups_for_modules: [
        "Result types": [
          Adbc.Result,
          Adbc.IngestResult,
          Adbc.StreamResult
        ]
      ]
    ]
  end

  defp package() do
    [
      name: "adbc",
      files:
        ~w(3rd_party/apache-arrow-adbc 3rd_party/nanoarrow c_src lib mix.exs README* LICENSE* CMakeLists.txt Makefile Makefile.win checksum.exs),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @github_url}
    ]
  end
end

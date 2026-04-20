Mix.install([{:req, "~> 0.4"}])

defmodule Update do
  # To update duckdb driver, just bump this version
  # https://github.com/duckdb/duckdb/releases/
  @duckdb_version "1.5.1"

  # To update ADBC drivers, bump the tag and version accordingly
  # https://github.com/apache/arrow-adbc/releases
  @adbc_driver_version "1.10.0"
  @adbc_tag "apache-arrow-adbc-22"
  @adbc_drivers ~w(sqlite postgresql flightsql snowflake bigquery)a

  # To update foundry (community) drivers, bump versions here
  # https://docs.adbc-drivers.org / https://github.com/adbc-drivers
  @foundry_drivers [
    databricks: "0.1.2",
    mysql: "0.3.1",
    trino: "0.3.1",
    exasol: "0.7.0"
  ]

  def versions do
    Map.new(@adbc_drivers, &{&1, @adbc_driver_version})
    |> Map.merge(%{duckdb: @duckdb_version})
    |> Map.merge(Map.new(@foundry_drivers))
  end

  def mappings do
    %{}
    |> Map.merge(adbc_mappings(@adbc_driver_version, @adbc_tag))
    |> Map.merge(duckdb_mappings(@duckdb_version))
    |> Map.merge(foundry_mappings())
  end

  defp duckdb_mappings(duckdb_version) do
    assets =
      fetch_assets!("https://api.github.com/repos/duckdb/duckdb/releases/tags/v#{duckdb_version}")

    IO.puts("Generating duckdb")

    zip_files =
      Enum.filter(assets, fn %{"name" => name} ->
        String.starts_with?(name, "libduckdb") and String.ends_with?(name, ".zip") and
          not String.contains?(name, "src") and not String.ends_with?(name, "-musl.zip")
      end)

    {aarch64_apple_darwin, zip_files} = data_for(zip_files, ["osx", "universal"])
    {x86_64_apple_darwin, zip_files} = {aarch64_apple_darwin, zip_files}
    {aarch64_linux_gnu, zip_files} = data_for(zip_files, ["linux", "arm64"])
    {x86_64_linux_gnu, zip_files} = data_for(zip_files, ["linux", "amd64"])
    {x86_64_windows_msvc, zip_files} = data_for(zip_files, ["windows", "amd64"])
    {aarch64_windows_msvc, zip_files} = data_for(zip_files, ["windows", "arm64"])

    if zip_files != [] do
      IO.puts("The following zip files for duckdb are not being used:\n\n#{inspect(zip_files)}")
    end

    %{
      duckdb: %{
        "aarch64-apple-darwin" => aarch64_apple_darwin,
        "x86_64-apple-darwin" => x86_64_apple_darwin,
        "aarch64-linux-gnu" => aarch64_linux_gnu,
        "x86_64-linux-gnu" => x86_64_linux_gnu,
        "x86_64-windows-msvc" => x86_64_windows_msvc,
        "aarch64-windows-msvc" => aarch64_windows_msvc
      }
    }
  end

  defp adbc_mappings(version, tag) do
    assets = fetch_assets!("https://api.github.com/repos/apache/arrow-adbc/releases/tags/#{tag}")

    for driver <- @adbc_drivers, into: %{} do
      IO.puts("Generating #{driver}")
      prefix = "adbc_driver_#{driver}-#{version}"
      suffix = ".whl"

      wheels =
        Enum.filter(assets, fn %{"name" => name} ->
          String.starts_with?(name, prefix) and String.ends_with?(name, suffix)
        end)

      {aarch64_apple_darwin, wheels} = data_for(wheels, ["macosx", "arm64"])
      {x86_64_apple_darwin, wheels} = data_for(wheels, ["macosx", "x86_64"])
      {aarch64_linux_gnu, wheels} = data_for(wheels, ["manylinux", "aarch64"])
      {x86_64_linux_gnu, wheels} = data_for(wheels, ["manylinux", "x86_64"])
      {x86_64_windows_msvc, wheels} = data_for(wheels, ["win_amd64"])

      if wheels != [] do
        IO.puts("The following wheels for #{driver} are not being used:\n\n#{inspect(wheels)}")
      end

      data =
        %{
          "aarch64-apple-darwin" => aarch64_apple_darwin,
          "x86_64-apple-darwin" => x86_64_apple_darwin,
          "aarch64-linux-gnu" => aarch64_linux_gnu,
          "x86_64-linux-gnu" => x86_64_linux_gnu,
          "x86_64-windows-msvc" => x86_64_windows_msvc
        }

      {driver, data}
    end
  end

  defp foundry_mappings do
    for {driver, version} <- @foundry_drivers, into: %{} do
      IO.puts("Generating #{driver} (foundry)")
      name = Atom.to_string(driver)
      tag = "#{foundry_tag_prefix(driver)}%2Fv#{version}"

      assets =
        fetch_assets!("https://api.github.com/repos/adbc-drivers/#{name}/releases/tags/#{tag}")

      tarballs =
        Enum.filter(assets, fn %{"name" => n} ->
          String.starts_with?(n, "#{name}_") and String.ends_with?(n, ".tar.gz")
        end)

      {aarch64_apple_darwin, tarballs} = data_for(tarballs, ["macos", "arm64"])
      {aarch64_linux_gnu, tarballs} = data_for(tarballs, ["linux", "arm64"])
      {x86_64_linux_gnu, tarballs} = data_for(tarballs, ["linux", "amd64"])
      {x86_64_windows_msvc, tarballs} = data_for(tarballs, ["windows", "amd64"])

      if tarballs != [] do
        IO.puts(
          "The following tarballs for #{driver} are not being used:\n\n#{inspect(tarballs)}"
        )
      end

      data = %{
        "aarch64-apple-darwin" => aarch64_apple_darwin,
        "aarch64-linux-gnu" => aarch64_linux_gnu,
        "x86_64-linux-gnu" => x86_64_linux_gnu,
        "x86_64-windows-msvc" => x86_64_windows_msvc
      }

      {driver, data}
    end
  end

  defp foundry_tag_prefix(:exasol), do: "src"
  defp foundry_tag_prefix(_), do: "go"

  defp data_for(wheels, parts) do
    case Enum.split_with(wheels, fn %{"name" => name} -> Enum.all?(parts, &(name =~ &1)) end) do
      {[%{"browser_download_url" => url}], rest} -> {%{url: url}, rest}
      {[], _rest} -> raise "no entries matching #{inspect(parts)}\n\n#{inspect(wheels)}"
      {_, _rest} -> raise "many entries matching #{inspect(parts)}\n\n#{inspect(wheels)}"
    end
  end

  defp fetch_assets!(url) do
    opts =
      if token = System.get_env("GITHUB_TOKEN") do
        [auth: {:bearer, token}]
      else
        []
      end

    release = Req.get!(url, opts)

    if release.status != 200 do
      raise "unknown GitHub release #{url}\n\n#{inspect(release)}"
    end

    release.body["assets"]
  end
end

file = "lib/adbc/driver.ex"
versions = Update.versions()
mappings = Update.mappings()

case String.split(File.read!(file), "# == GENERATED CONSTANTS ==") do
  [pre, _mid, post] ->
    time =
      NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

    mid = """
    # == GENERATED CONSTANTS ==

    # Generated by update.exs at #{time}. Do not change manually.
    @generated_driver_versions #{inspect(versions)}
    @generated_driver_data #{inspect(mappings)}

    # == GENERATED CONSTANTS ==
    """

    File.write!(file, [Code.format_string!(pre <> mid <> post), "\n"])

  _ ->
    raise "could not find # == GENERATED CONSTANTS == chunks in #{file}"
end

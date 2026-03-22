defmodule Adbc.DLLLoaderNif do
  # We don't use on_load callbacks because this module
  # needs to be invoked from Adbc.Nif and if both have
  # @on_load the order is not guaranteed in a release.
  @moduledoc false

  def init do
    case :os.type() do
      {:win32, _} ->
        priv_dir = :code.priv_dir(:adbc)
        File.mkdir_p!(Path.join(priv_dir, "bin"))
        path = :filename.join(priv_dir, ~c"adbc_dll_loader")
        :erlang.load_nif(path, 0)

      _ ->
        :ok
    end
  end

  def __unused__ do
    0
  end
end

defmodule Adbc.IPC do
  @moduledoc """
  Module for loading and saving Arrow IPC data.
  """

  import Adbc.Helper, only: [error_to_exception: 1]
  alias Adbc.ArrayStream

  @doc """
  Return IPC endianness.
  """
  @spec endianness() :: :big | :little
  def endianness do
    Adbc.Nif.adbc_ipc_system_endianness()
  end

  @doc """
  Load IPC stream from a file.

  Note: this function is intended to load raw IPC stream data that is dumped
  to a file using `dump_stream/1` or the same data from other libraries.

  It is NOT intended to load Arrow IPC files.
  """
  @spec load_stream_file(Path.t()) :: term() | {:error, File.posix()}
  def load_stream_file(filepath) do
    with {:ok, data} <- File.read(filepath) do
      load_stream(data)
    end
  end

  @doc """
  Load from in-memory IPC stream data.
  """
  @spec load_stream(binary) :: term() | {:error, Adbc.Error.t()}
  def load_stream(data) do
    case Adbc.Nif.adbc_ipc_load_stream_binary(data) do
      {:error, reason} ->
        {:error, error_to_exception(reason)}

      stream_ref when is_reference(stream_ref) ->
        stream_ref
        |> ArrayStream.stream_results(nil)
        |> tap(fn _ -> Adbc.Nif.adbc_arrow_array_stream_release(stream_ref) end)
    end
  end

  @doc """
  Dump Adbc.Result to in-memory IPC stream data.
  """
  @spec dump_stream(list(Adbc.Column.t())) :: binary | {:error, Adbc.Error.t()}
  def dump_stream(columns) when is_list(columns) do
    case Adbc.Nif.adbc_ipc_dump_stream_binary(columns) do
      {:error, reason} ->
        {:error, error_to_exception(reason)}

      data ->
        data
    end
  end
end

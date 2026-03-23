defmodule Adbc.StreamResult do
  @moduledoc """
  Represents an unmaterialized Arrow stream.

  It may be created from a query via `Adbc.Connection.query_pointer/4`
  or from in-memory IPC stream data via `from_ipc_stream/1`.

  The stream can only be consumed **once** - after being passed to
  `bulk_insert/3` or other operations, it becomes invalid.

  It contains:

    * `:ref` - internal reference to the stream (do not use directly)
    * `:conn` - internal connection pid (do not use directly)
    * `:pointer` - pointer to the ArrowArrayStream (integer memory address)
    * `:num_rows` - the number of rows affected by the query, may be `nil`
      for queries depending on the database driver

  > ### Garbage collection {: .warning}
  >
  > You must always hold a whole reference to the struct,
  > and not individual fields. For example, if you only
  > keep a reference to `result.pointer`, then the struct will
  > be GCed, and so would be the stream.
  """
  defstruct [:conn, :ref, :pointer, :num_rows]

  @type t :: %__MODULE__{
          conn: pid() | nil,
          ref: reference(),
          pointer: non_neg_integer(),
          num_rows: non_neg_integer() | nil
        }

  @doc """
  Load an `Adbc.StreamResult` from in-memory IPC stream data.

  The stream is not materialized, and can be passed directly to
  `Adbc.Connection.bulk_insert/3` or `Adbc.Connection.ingest/2`.
  """
  @spec from_ipc_stream(binary) :: {:ok, t()} | {:error, Adbc.Error.t()}
  def from_ipc_stream(data) when is_binary(data) do
    case Adbc.Nif.adbc_ipc_load_stream_binary(data) do
      {:error, reason} ->
        {:error, Adbc.Helper.error_to_exception(reason)}

      stream_ref when is_reference(stream_ref) ->
        pointer = Adbc.Nif.adbc_arrow_array_stream_get_pointer(stream_ref)

        {:ok,
         %Adbc.StreamResult{
           conn: nil,
           ref: stream_ref,
           pointer: pointer,
           num_rows: nil
         }}
    end
  end

  @doc """
  Same as `from_ipc_stream/1` but raises on error.
  """
  @spec from_ipc_stream!(binary) :: t()
  def from_ipc_stream!(data) when is_binary(data) do
    case from_ipc_stream(data) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end
end

defmodule Adbc.IngestResult do
  @moduledoc """
  Represents the result of an `Adbc.Connection.ingest/2` operation.

  The data is stored in a temporary table that is automatically
  dropped when this struct is garbage collected.

  It contains:

    * `:ref` - internal reference that controls the table lifetime (do not use directly)
    * `:table` - the name of the temporary table
    * `:num_rows` - the number of rows ingested

  > ### Garbage collection {: .warning}
  >
  > You must always hold a whole reference to the struct,
  > and not individual fields. For example, if you only
  > keep a reference to `result.table`, then the struct will
  > be GCed, and so would be the table.
  """
  defstruct [:ref, :table, :num_rows]

  @type t :: %__MODULE__{
          ref: reference(),
          table: String.t(),
          num_rows: non_neg_integer()
        }
end

defmodule Adbc.Result do
  @moduledoc """
  A struct returned as result from queries.

  It has two fields:

    * `:data` - a list of `Adbc.Column`. The `Adbc.Column` may
      not yet have been materialized

    * `:num_rows` - the number of rows returned, if returned
      by the database
  """
  defstruct [:num_rows, :data]

  @type t :: %Adbc.Result{
          num_rows: non_neg_integer() | nil,
          data: [Adbc.Column.t()]
        }

  import Adbc.Helper, only: [error_to_exception: 1]

  @doc """
  Load an `Adbc.Result` from in-memory IPC stream data.
  """
  @spec from_ipc_stream(binary) :: {:ok, t()} | {:error, Adbc.Error.t()}
  def from_ipc_stream(data) when is_binary(data) do
    case Adbc.Nif.adbc_ipc_load_stream_binary(data) do
      {:error, reason} ->
        {:error, error_to_exception(reason)}

      stream_ref when is_reference(stream_ref) ->
        try do
          stream_results(stream_ref, nil)
        after
          Adbc.Nif.adbc_arrow_array_stream_release(stream_ref)
        end
    end
  end

  @doc """
  Same as `from_ipc_stream/1` but raises on error.
  """
  @spec from_ipc_stream!(binary) :: t()
  def from_ipc_stream!(data) when is_binary(data) do
    case from_ipc_stream(data) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Dump an `Adbc.Result` to in-memory IPC stream data.
  """
  @spec to_ipc_stream(t()) :: binary
  def to_ipc_stream(%Adbc.Result{data: batches}) when is_list(batches) do
    case Adbc.Nif.adbc_ipc_dump_stream_binary(batches) do
      {:error, reason} ->
        raise error_to_exception(reason)

      {:ok, data} ->
        data
    end
  end

  @doc """
  `materialize/1` converts the result set's data from reference type to regular Elixir terms.
  """
  @spec materialize(%Adbc.Result{} | {:ok, %Adbc.Result{}} | {:error, String.t()}) ::
          %Adbc.Result{} | {:ok, %Adbc.Result{}} | {:error, String.t()}
  def materialize(%Adbc.Result{data: batches} = result) when is_list(batches) do
    %{
      result
      | data: Enum.map(batches, fn columns -> Enum.map(columns, &Adbc.Column.materialize/1) end)
    }
  end

  @doc """
  Returns a map of columns as a result.
  """
  def to_map(%Adbc.Result{data: batches}) do
    batches
    |> Enum.zip_with(fn [%{field: %{name: name}} | _] = columns ->
      {name, Enum.flat_map(columns, &(&1 |> Adbc.Column.materialize() |> Adbc.Column.to_list()))}
    end)
    |> Map.new()
  end

  @doc """
  Consumes Arrow data from a Python object that implements the
  [ArrowStream Export interface](https://arrow.apache.org/docs/format/CDataInterface/PyCapsuleInterface.html#arrowstream-export).

  The interface is typically implemented for dataframe objects, including
  ones from Pandas and Polars.

  It returns an ok-tuple with `Adbc.Result` or an error-tuple.
  You often want to call `Adbc.Result.materialize/1` or
  `Adbc.Result.to_map/1` on the results to consume it.
  """
  def from_py(py_object) do
    case Adbc.Helper.from_py(py_object) do
      {:ok, stream_ref, capsule} ->
        stream_ref
        |> stream_results(nil)
        |> tap(fn _ -> Adbc.Helper.noop(capsule) end)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Same as `from_py/1` but raises on error.
  """
  def from_py!(py_object) do
    case from_py(py_object) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  defp stream_results(reference, num_rows), do: stream_results(reference, [], num_rows)

  defp stream_results(reference, acc, num_rows) do
    case Adbc.Nif.adbc_arrow_array_stream_next(reference) do
      {:ok, columns} ->
        stream_results(reference, [columns | acc], num_rows)

      :end_of_series ->
        {:ok, %Adbc.Result{data: Enum.reverse(acc), num_rows: num_rows}}

      {:error, reason} ->
        {:error, error_to_exception(reason)}
    end
  end
end

defimpl Table.Reader, for: Adbc.Result do
  def init(%Adbc.Result{data: batches, num_rows: num_rows}) do
    # Group columns across batches by position, materialize and concatenate
    names =
      case batches do
        [first_batch | _] -> Enum.map(first_batch, & &1.field.name)
        [] -> []
      end

    data =
      Enum.zip_with(batches, fn columns_at_pos ->
        Enum.flat_map(columns_at_pos, fn column ->
          column |> Adbc.Column.materialize() |> Adbc.Column.to_list()
        end)
      end)

    {:columns, %{columns: names, count: num_rows}, data}
  end
end

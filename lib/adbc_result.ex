defmodule Adbc.StreamResult do
  @moduledoc """
  Represents an unmaterialized Arrow stream from a query.

  This struct can only be used within the callback passed to
  `Adbc.Connection.query_pointer/4`. The stream can only be consumed
  **once** - after being passed to `bulk_insert/3` or other operations,
  it becomes invalid.

  It contains:

    * `:ref` - internal reference to the stream (do not use directly)
    * `:conn` - internal connection pid (do not use directly)
    * `:pointer` - pointer to the ArrowArrayStream (integer memory address)
    * `:num_rows` - the number of rows affected by the query, may be `nil`
      for queries depending on the database driver
  """
  defstruct [:conn, :ref, :pointer, :num_rows]

  @type t :: %__MODULE__{
          conn: pid(),
          ref: reference(),
          pointer: non_neg_integer(),
          num_rows: non_neg_integer() | nil
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

  @doc """
  `materialize/1` converts the result set's data from reference type to regular Elixir terms.
  """
  @spec materialize(%Adbc.Result{} | {:ok, %Adbc.Result{}} | {:error, String.t()}) ::
          %Adbc.Result{} | {:ok, %Adbc.Result{}} | {:error, String.t()}
  def materialize(%Adbc.Result{data: data} = result) when is_list(data) do
    %{result | data: Enum.map(data, &Adbc.Column.materialize/1)}
  end

  @doc """
  Returns a map of columns as a result.
  """
  def to_map(result = %Adbc.Result{}) do
    Map.new(result.data, fn %Adbc.Column{name: name} = column ->
      {name, column |> Adbc.Column.materialize() |> Adbc.Column.to_list()}
    end)
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
  if Code.ensure_loaded?(Pythonx) do
    def from_py(py_object) when is_struct(py_object, Pythonx.Object) do
      {_, globals} =
        Pythonx.eval(
          """
          if hasattr(object, "__arrow_c_stream__"):
            import ctypes

            has_stream = True
            capsule = object.__arrow_c_stream__()
            ctypes.pythonapi.PyCapsule_GetPointer.restype = ctypes.c_void_p
            ctypes.pythonapi.PyCapsule_GetPointer.argtypes = [ctypes.py_object, ctypes.c_char_p]
            pointer = ctypes.pythonapi.PyCapsule_GetPointer(capsule, b"arrow_array_stream")

          else:
            has_stream = False
            capsule = None
            pointer = None
          """,
          %{"object" => py_object}
        )

      if Pythonx.decode(globals["has_stream"]) do
        # We need to keep a reference to the stream, until we consume it.
        capsule = globals["capsule"]
        pointer = Pythonx.decode(globals["pointer"])

        with {:ok, stream_ref} <- Adbc.Nif.adbc_arrow_array_stream_from_pointer(pointer) do
          do_stream_results(stream_ref, [], capsule)
        end
      else
        raise ArgumentError, """
        the given Python object does not support ArrowStream Export interface (__arrow_c_stream__ method is missing)
        """
      end
    end
  else
    def from_py(_py_object) do
      raise """
      Adbc.Result.from_py/4 requires pythonx to be available, add it to your mix.exs:

          {:pythonx, "~> 0.4.0"}
      """
    end
  end

  defp do_stream_results(reference, acc, capsule) do
    case Adbc.Nif.adbc_arrow_array_stream_next(reference) do
      {:ok, result} ->
        do_stream_results(reference, [result | acc], capsule)

      :end_of_series ->
        {:ok, %Adbc.Result{data: merge_columns(Enum.reverse(acc)), num_rows: nil}}

      {:error, reason} ->
        {:error, Adbc.Helper.error_to_exception(reason)}
    end
  end

  defp merge_columns(chucked_results) do
    Enum.zip_with(chucked_results, fn columns ->
      Enum.reduce(columns, fn column, merged_column ->
        %{merged_column | data: merged_column.data ++ column.data}
      end)
    end)
  end
end

defimpl Table.Reader, for: Adbc.Result do
  def init(result) do
    data =
      Enum.map(result.data, fn column ->
        column
        |> Adbc.Column.materialize()
        |> Adbc.Column.to_list()
      end)

    names = Enum.map(result.data, & &1.name)
    {:columns, %{columns: names, count: result.num_rows}, data}
  end
end

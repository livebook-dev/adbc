defmodule Adbc.ArrayStream do
  @moduledoc """
  Internal module for AdbcArrayStream. Not intended for public use.
  """

  import Adbc.Helper, only: [error_to_exception: 1]

  def stream_results(reference, num_rows), do: stream_results(reference, [], num_rows)

  def stream_results(reference, acc, num_rows) do
    case Adbc.Nif.adbc_arrow_array_stream_next(reference) do
      {:ok, result} ->
        stream_results(reference, [result | acc], num_rows)

      :end_of_series ->
        {:ok, %Adbc.Result{data: merge_columns(Enum.reverse(acc)), num_rows: num_rows}}

      {:error, reason} ->
        {:error, error_to_exception(reason)}
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

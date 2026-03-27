defmodule Adbc.Nif do
  @moduledoc false

  @on_load :load_nif
  def load_nif do
    :ok = Adbc.DLLLoaderNif.init()
    nif_file = ~c"#{:code.priv_dir(:adbc)}/adbc_nif"

    case :erlang.load_nif(nif_file, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> IO.puts("Failed to load nif: #{inspect(reason)}")
    end
  end

  def adbc_database_new, do: :erlang.nif_error(:not_loaded)

  def adbc_database_get_option(_self, _type, _key), do: :erlang.nif_error(:not_loaded)

  def adbc_database_set_option(_self, _type, _key, _value), do: :erlang.nif_error(:not_loaded)

  def adbc_database_init(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_connection_new, do: :erlang.nif_error(:not_loaded)

  def adbc_connection_get_option(_self, _type, _key), do: :erlang.nif_error(:not_loaded)

  def adbc_connection_set_option(_self, _type, _key, _value), do: :erlang.nif_error(:not_loaded)

  def adbc_connection_init(_self, _database), do: :erlang.nif_error(:not_loaded)

  def adbc_connection_get_info(_self, _info_codes), do: :erlang.nif_error(:not_loaded)

  def adbc_connection_get_objects(
        _self,
        _depth,
        _catalog,
        _db_schema,
        _table_name,
        _table_type,
        _column_name
      ),
      do: :erlang.nif_error(:not_loaded)

  def adbc_connection_get_table_types(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_new(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_get_option(_self, _type, _key), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_set_option(_self, _type, _key, _value), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_execute_query(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_execute(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_prepare(_self), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_set_sql_query(_self, _query), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_bind(_self, _values), do: :erlang.nif_error(:not_loaded)

  def adbc_statement_bind_stream(_self, _stream), do: :erlang.nif_error(:not_loaded)

  def adbc_arrow_array_stream_get_pointer(_arrow_array_stream), do: :erlang.nif_error(:not_loaded)

  def adbc_arrow_array_stream_from_pointer(_pointer), do: :erlang.nif_error(:not_loaded)

  def adbc_arrow_array_stream_next(_arrow_array_stream), do: :erlang.nif_error(:not_loaded)

  def adbc_arrow_array_stream_release(_arrow_array_stream), do: :erlang.nif_error(:not_loaded)

  def adbc_column_materialize(_data_ref), do: :erlang.nif_error(:not_loaded)

  def adbc_ipc_system_endianness, do: :erlang.nif_error(:not_loaded)

  def adbc_ipc_load_stream_binary(_binary), do: :erlang.nif_error(:not_loaded)

  def adbc_ipc_dump_stream_ref(_stream_ref), do: :erlang.nif_error(:not_loaded)

  def adbc_delete_on_gc_new(_pid, _table_name), do: :erlang.nif_error(:not_loaded)
end

defmodule Adbc.Connection do
  @moduledoc """
  Documentation for `Adbc.Connection`.

  Connection are modelled as processes. They require
  an `Adbc.Database` to be started.
  """

  @type t :: GenServer.server()

  use GenServer
  import Adbc.Helper, only: [error_to_exception: 1]

  python_object =
    if Code.ensure_loaded?(Pythonx),
      do: quote(do: Pythonx.Object.t()),
      else: quote(do: none())

  @doc """
  Starts a connection process.

  ## Options

    * `:database` (required) - the database process to connect to

    * `:process_options` - the options to be given to the underlying
      process. See `GenServer.start_link/3` for all options

  ## Examples

      Adbc.Connection.start_link(
        database: MyApp.DB,
        process_options: [name: MyApp.Conn]
      )

  In your supervision tree it would be started like this:

      children = [
        {Adbc.Connection,
         database: MyApp.DB,
         process_options: [name: MyApp.Conn]}
      ]

  """
  def start_link(opts) do
    {db, opts} = Keyword.pop(opts, :database, nil)

    unless db do
      raise ArgumentError, ":database option must be specified"
    end

    {process_options, opts} = Keyword.pop(opts, :process_options, [])

    with {:ok, conn} <- Adbc.Nif.adbc_connection_new(),
         :ok <- init_options(conn, opts) do
      GenServer.start_link(__MODULE__, {db, conn}, process_options)
    else
      {:error, reason} -> {:error, error_to_exception(reason)}
    end
  end

  @doc """
  Get a string type option of the connection.
  """
  @spec get_string_option(pid(), atom() | String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def get_string_option(conn, key) when is_pid(conn) do
    Adbc.Helper.option(conn, :adbc_connection_get_option, [:string, to_string(key)])
  end

  @doc """
  Get a binary (bytes) type option of the connection.
  """
  @spec get_binary_option(pid(), atom() | String.t()) :: {:ok, binary()} | {:error, String.t()}
  def get_binary_option(conn, key) when is_pid(conn) do
    Adbc.Helper.option(conn, :adbc_connection_get_option, [:binary, to_string(key)])
  end

  @doc """
  Get an integer type option of the connection.
  """
  @spec get_integer_option(pid(), atom() | String.t()) :: {:ok, integer()} | {:error, String.t()}
  def get_integer_option(conn, key) when is_pid(conn) do
    Adbc.Helper.option(conn, :adbc_connection_get_option, [:integer, to_string(key)])
  end

  @doc """
  Get a float type option of the connection.
  """
  @spec get_float_option(pid(), atom() | String.t()) :: {:ok, float()} | {:error, String.t()}
  def get_float_option(conn, key) when is_pid(conn) do
    Adbc.Helper.option(conn, :adbc_connection_get_option, [:float, to_string(key)])
  end

  @doc """
  Set option for the connection.

  - If `value` is an atom or a string, then corresponding string option will be set.
  - If `value` is a `{:binary, iodata()}`-tuple, then corresponding binary option will be set.
  - If `value` is an integer, then corresponding integer option will be set.
  - If `value` is a float, then corresponding float option will be set.
  """
  @spec set_option(
          pid(),
          atom() | String.t(),
          atom() | {:binary, iodata()} | String.t() | number()
        ) ::
          :ok | {:error, String.t()}
  def set_option(conn, key, value)

  def set_option(conn, key, value) when is_pid(conn) and (is_atom(value) or is_binary(value)) do
    Adbc.Helper.option(conn, :adbc_connection_set_option, [:string, key, value])
  end

  def set_option(conn, key, {:binary, value}) when is_pid(conn) do
    Adbc.Helper.option(conn, :adbc_connection_set_option, [:binary, key, value])
  end

  def set_option(conn, key, value) when is_pid(conn) and is_integer(value) do
    Adbc.Helper.option(conn, :adbc_connection_set_option, [:integer, key, value])
  end

  def set_option(conn, key, value) when is_pid(conn) and is_float(value) do
    Adbc.Helper.option(conn, :adbc_connection_set_option, [:float, key, value])
  end

  defp init_options(ref, opts) do
    Enum.reduce_while(opts, :ok, fn
      {key, value}, :ok when is_atom(value) or is_binary(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_connection_set_option, [:string, key, value])

      {key, {:binary, value}}, :ok ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_connection_set_option, [:binary, key, value])

      {key, value}, :ok when is_integer(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_connection_set_option, [:integer, key, value])

      {key, value}, :ok when is_float(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_connection_set_option, [:float, key, value])
    end)
  end

  defp init_statement_options(ref, opts) do
    Enum.reduce_while(opts, :ok, fn
      {key, value}, :ok when is_atom(value) or is_binary(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_statement_set_option, [:string, key, value])

      {key, {:binary, value}}, :ok ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_statement_set_option, [:binary, key, value])

      {key, value}, :ok when is_integer(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_statement_set_option, [:integer, key, value])

      {key, value}, :ok when is_float(value) ->
        Adbc.Helper.option_ok_or_halt(ref, :adbc_statement_set_option, [:float, key, value])
    end)
  end

  @doc """
  Runs the given `query` with `params` and `statement_options`.

  It returns an ok-tuple with `Adbc.Result` or an error-tuple.
  You often want to call `Adbc.Result.to_map/1` on the result
  to consume it.
  """
  @spec query(t(), binary | reference, [term], Keyword.t()) ::
          {:ok, Adbc.Result.t()} | {:error, Exception.t()}
  def query(conn, query, params \\ [], statement_options \\ [])
      when (is_binary(query) or is_reference(query)) and is_list(params) and
             is_list(statement_options) do
    stream(conn, {:query, query, params_to_columns(params), statement_options}, &stream_results/3)
  end

  @doc """
  Same as `query/4` but raises an exception on error.

  It returns an `Adbc.Result` struct. You often want to call
  `Adbc.Result.to_map/1` on the result to consume it.
  """
  @spec query!(t(), binary | reference, [term], Keyword.t()) :: Adbc.Result.t()
  def query!(conn, query, params \\ [], statement_options \\ [])
      when (is_binary(query) or is_reference(query)) and is_list(params) and
             is_list(statement_options) do
    case query(conn, query, params, statement_options) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Runs the given `query` with `params` and `statement_options`, returning
  only the number of affected rows.

  Unlike `query/4`, this function does not return any data. This is useful
  for DDL statements (CREATE TABLE, DROP TABLE, etc.) and DML statements
  (INSERT, UPDATE, DELETE) where you don't need the result set.

  Returns `{:ok, rows_affected}` where `rows_affected` is a non-negative
  integer or `nil` if the driver does not report it.
  """
  @spec execute(t(), binary | reference, [term], Keyword.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, Exception.t()}
  def execute(conn, query, params \\ [], statement_options \\ [])
      when (is_binary(query) or is_reference(query)) and is_list(params) and
             is_list(statement_options) do
    command(conn, {:execute, query, params_to_columns(params), statement_options})
  end

  @doc """
  Same as `execute/4` but raises an exception on error.
  """
  @spec execute!(t(), binary | reference, [term], Keyword.t()) :: non_neg_integer() | nil
  def execute!(conn, query, params \\ [], statement_options \\ [])
      when (is_binary(query) or is_reference(query)) and is_list(params) and
             is_list(statement_options) do
    case execute(conn, query, params, statement_options) do
      {:ok, rows_affected} -> rows_affected
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Prepares the given `query`.
  """
  @spec prepare(t(), binary) :: {:ok, reference} | {:error, Exception.t()}
  def prepare(conn, query) when is_binary(query) do
    command(conn, {:prepare, query})
  end

  @doc """
  Performs a bulk insert operation.

  This function creates a table (or appends to an existing one) and inserts
  columns in supported databases. This should be more efficient than using SQL
  query in supported databases.

  Columns can be given as:

    * a keyword list of column name to data, where values are either plain lists
      (converted via `Adbc.Column.new/2`) or `Adbc.Column.t()` structs (the name
      from the keyword key overrides the column's name)

    * a list of `Adbc.Column.t()` structs

    * an `Adbc.StreamResult.t()` (obtained from `query_pointer/4`) to efficiently
      insert query results without materializing the data

    * a `Pythonx.Object` representing a PyArrow `RecordBatchReader`
      (requires the `pythonx` package)

  ## Arguments

    * `conn` - The connection process
    * `columns_or_stream` - Columns as a keyword list, a list of `Adbc.Column.t()`,
      an `Adbc.StreamResult.t()`, or a `Pythonx.Object`
    * `opts` - Options for the bulk insert operation

  ## Options

    * `:table` (required) - The name of the target table for bulk insert

    * `:mode` (optional) - The ingestion mode. When not specified, the default behavior
      is driver-dependent but typically behaves like `:create`. Available modes:
      * `:create` - Create the table and insert data; error if the table already exists
      * `:append` - Insert data into existing table; error if the table does not exist
        or if the schema does not match
      * `:replace` - Drop the table if it exists, create it, and insert data
      * `:create_append` - Create the table if it does not exist, otherwise append;
        error if the table exists but the schema does not match

    * `:catalog` (optional) - The catalog of the table. Support is driver-dependent.
      Not supported with `:temporary`.

    * `:schema` (optional) - The database schema of the table. Support is driver-dependent.
      For example, SQLite does not support this option. Not supported with `:temporary`.

    * `:temporary` (optional) - If `true`, create a temporary table. Default is `false`.
      Cannot be used with `:catalog` or `:schema`.

  ## Examples

      # Using a keyword list (types are inferred, use Adbc.Column for explicit types)
      Adbc.Connection.bulk_insert(conn,
        [id: [1, 2, 3], name: Adbc.Column.string(["Alice", "Bob", "Charlie"])],
        table: "users"
      )
      #=> {:ok, 3}

      # Using a list of columns
      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      Adbc.Connection.bulk_insert(conn, columns, table: "users")
      #=> {:ok, 3}

      # Append to an existing table
      Adbc.Connection.bulk_insert(conn, columns, table: "users", mode: :append)
      #=> {:ok, 3}

      # Create a temporary table
      Adbc.Connection.bulk_insert(conn, columns, table: "temp_users", temporary: true)
      #=> {:ok, 3}

      # Replace an existing table
      Adbc.Connection.bulk_insert(conn, columns, table: "users", mode: :replace)
      #=> {:ok, 3}

      # Efficiently insert from a query (within query_pointer callback)
      # This is most useful for transferring across databases.
      # Within the same database, you most likely have custom SQL commands,
      # such as COPY, CREATE TEMPORARY TABLE, etc.
      Adbc.Connection.query_pointer(source_conn, "SELECT * FROM source_table", fn stream ->
        Adbc.Connection.bulk_insert(dest_conn, stream, table: "dest_table")
      end)

  """
  @spec bulk_insert(
          t(),
          [Adbc.Column.t()]
          | keyword(list() | Adbc.Column.t())
          | Adbc.StreamResult.t()
          | unquote(python_object),
          Keyword.t()
        ) ::
          {:ok, non_neg_integer()} | {:error, Exception.t()}
  def bulk_insert(conn, columns_or_stream, opts \\ [])

  def bulk_insert(conn, %Adbc.StreamResult{} = stream, opts) when is_list(opts) do
    if stream.conn && stream.conn == GenServer.whereis(conn) do
      raise ArgumentError, "cannot use bulk_insert to transfer results over the same connection"
    end

    statement_options = build_ingest_options(opts)
    command(conn, {:bulk_insert_stream, stream.ref, nil, statement_options})
  end

  if Code.ensure_loaded?(Pythonx) do
    def bulk_insert(conn, %Pythonx.Object{} = py_object, opts) when is_list(opts) do
      statement_options = build_ingest_options(opts)

      case Adbc.Helper.from_py(py_object) do
        {:ok, stream_ref, capsule} ->
          command(conn, {:bulk_insert_stream, stream_ref, capsule, statement_options})

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def bulk_insert(conn, columns, opts) when is_list(columns) and is_list(opts) do
    statement_options = build_ingest_options(opts)
    command(conn, {:bulk_insert, to_columns(columns), statement_options})
  end

  @doc """
  Same as `bulk_insert/3` but raises an exception on error.
  """
  @spec bulk_insert!(
          t(),
          [Adbc.Column.t()]
          | keyword(list() | Adbc.Column.t())
          | Adbc.StreamResult.t()
          | unquote(python_object),
          Keyword.t()
        ) ::
          non_neg_integer()
  def bulk_insert!(conn, columns_or_stream, opts \\ []) do
    case bulk_insert(conn, columns_or_stream, opts) do
      {:ok, rows_affected} -> rows_affected
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Ingests columns into a temporary table that is automatically dropped
  when the returned result is garbage collected.

  Columns can be given as:

    * a keyword list of column name to data, where values are either plain lists
      (converted via `Adbc.Column.new/2`) or `Adbc.Column.t()` structs (the name
      from the keyword key overrides the column's name)

    * a list of `Adbc.Column.t()` structs

    * an `Adbc.StreamResult.t()` (obtained from `query_pointer/4`) to efficiently
      insert query results without materializing the data

    * a `Pythonx.Object` representing a PyArrow `RecordBatchReader`
      (requires the `pythonx` package)

  Returns `{:ok, %Adbc.IngestResult{}}` on success.

  > ### Garbage collection {: .warning}
  >
  > You must always hold a whole reference to the struct,
  > and not individual fields. For example, if you only
  > keep a reference to `result.table`, then the struct will
  > be GCed, and so would be the table.

  ## Examples

      # Using a keyword list
      {:ok, result} = Adbc.Connection.ingest(conn,
        id: [1, 2, 3],
        name: Adbc.Column.string(["Alice", "Bob", "Charlie"])
      )
      result.table
      #=> "adbc_ingest_0"
      result.num_rows
      #=> 3

      # Using a list of columns
      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      {:ok, result} = Adbc.Connection.ingest(conn, columns)

  """
  @spec ingest(
          t(),
          [Adbc.Column.t()]
          | keyword(list() | Adbc.Column.t())
          | Adbc.StreamResult.t()
          | unquote(python_object)
        ) ::
          {:ok, Adbc.IngestResult.t()} | {:error, Exception.t()}
  def ingest(conn, %Adbc.StreamResult{} = stream) do
    if stream.conn && stream.conn == GenServer.whereis(conn) do
      raise ArgumentError, "cannot use ingest to transfer results over the same connection"
    end

    command(conn, {:ingest_stream, stream.ref, nil})
  end

  if Code.ensure_loaded?(Pythonx) do
    def ingest(conn, %Pythonx.Object{} = py_object) do
      case Adbc.Helper.from_py(py_object) do
        {:ok, stream_ref, capsule} -> command(conn, {:ingest_stream, stream_ref, capsule})
        {:error, error} -> {:error, error}
      end
    end
  end

  def ingest(conn, columns) when is_list(columns) do
    command(conn, {:ingest, to_columns(columns)})
  end

  @doc """
  Same as `ingest/2` but raises an exception on error.
  """
  @spec ingest!(
          t(),
          [Adbc.Column.t()]
          | keyword(list() | Adbc.Column.t())
          | Adbc.StreamResult.t()
          | unquote(python_object)
        ) ::
          Adbc.IngestResult.t()
  def ingest!(conn, columns_or_stream) do
    case ingest(conn, columns_or_stream) do
      {:ok, result} -> result
      {:error, reason} -> raise reason
    end
  end

  defp build_ingest_options(opts) do
    unless opts[:table] do
      raise ArgumentError, ":table option must be specified"
    end

    statement_options = []

    statement_options =
      if table = opts[:table] do
        [{"adbc.ingest.target_table", table} | statement_options]
      else
        statement_options
      end

    statement_options =
      case opts[:mode] do
        nil ->
          statement_options

        :create ->
          [{"adbc.ingest.mode", "adbc.ingest.mode.create"} | statement_options]

        :append ->
          [{"adbc.ingest.mode", "adbc.ingest.mode.append"} | statement_options]

        :replace ->
          [{"adbc.ingest.mode", "adbc.ingest.mode.replace"} | statement_options]

        :create_append ->
          [{"adbc.ingest.mode", "adbc.ingest.mode.create_append"} | statement_options]

        other ->
          raise ArgumentError,
                "invalid :mode option #{inspect(other)}, expected one of: :create, :append, :replace, :create_append"
      end

    statement_options =
      if catalog = opts[:catalog] do
        [{"adbc.ingest.target_catalog", catalog} | statement_options]
      else
        statement_options
      end

    statement_options =
      if schema = opts[:schema] do
        [{"adbc.ingest.target_db_schema", schema} | statement_options]
      else
        statement_options
      end

    statement_options =
      if opts[:temporary] do
        [{"adbc.ingest.temporary", "true"} | statement_options]
      else
        statement_options
      end

    statement_options
  end

  defp to_columns([{key, _value} | _] = keyword) when is_atom(key) do
    Enum.map(keyword, fn
      {name, %Adbc.Column{} = col} ->
        %{col | field: %{col.field | name: Atom.to_string(name)}}

      {name, data} when is_list(data) ->
        Adbc.Column.new(data, name: Atom.to_string(name))
    end)
  end

  defp to_columns(columns) do
    columns
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%Adbc.Column{field: %{name: nil} = field} = col, i} ->
        %{col | field: %{field | name: "col#{i}"}}

      {col, _i} ->
        col
    end)
  end

  defp params_to_columns(params) when is_list(params) do
    Enum.map(params, fn
      %Adbc.Column{} = col -> col
      param -> Adbc.Column.new([param])
    end)
  end

  @doc """
  Runs the given `query` with `params` and
  pass the `Adbc.StreamResult` to the given function.

  The `Adbc.StreamResult` holds a pointer to a valid ArrowStream through
  the duration of the function. A `Adbc.StreamResult` can only be consumed once.

  The callback function should accept a single argument of type
  `Adbc.StreamResult.t()`. For backwards compatibility, 2-arity
  functions are still supported but deprecated (a warning will be emitted).
  """
  def query_pointer(conn, query, params \\ [], fun, statement_options \\ [])
      when (is_binary(query) or is_reference(query)) and is_list(params) and is_function(fun) and
             is_list(statement_options) do
    stream(conn, {:query, query, params_to_columns(params), statement_options}, fn conn,
                                                                                   stream_ref,
                                                                                   rows_affected ->
      pointer = Adbc.Nif.adbc_arrow_array_stream_get_pointer(stream_ref)

      if is_function(fun, 2) do
        IO.warn(
          "query_pointer/5 callback should be 1-arity (receiving %Adbc.StreamResult{}), 2-arity is deprecated"
        )

        {:ok, fun.(pointer, rows_affected)}
      else
        stream_result = %Adbc.StreamResult{
          conn: conn,
          ref: stream_ref,
          pointer: pointer,
          num_rows: normalize_rows(rows_affected)
        }

        {:ok, fun.(stream_result)}
      end
    end)
  end

  @doc ~S'''
  Runs the given `query` with `params` and `statement_options`.

  This function requires `pythonx` to be installed, with the `pyarrow`
  package available in the installation.

  The return value is an ok-tuple with `Pythonx.Object` - an instance
  of [`pyarrow.Table`](https://arrow.apache.org/docs/python/generated/pyarrow.Table.html).

  The table object can then be used to efficiently create a polars dataframe:

      {:ok, py_table} = Adbc.Connection.py_query(conn, "SELECT * FROM ...", [])

      Pythonx.eval(
        """
        import polars
        df = polars.from_arrow(py_table)

        # ...
        """,
        %{"py_table" => py_table}
      )

  or a pandas dataframe:

      {:ok, py_table} = Adbc.Connection.py_query(conn, "SELECT * FROM ...", [])

      Pythonx.eval(
        """
        df = py_table.to_pandas()

        # ...
        """,
        %{"py_table" => py_table}
      )

  '''
  if Code.ensure_loaded?(Pythonx) do
    def py_query(conn, query, params \\ [], statement_options \\ [])
        when (is_binary(query) or is_reference(query)) and is_list(params) and
               is_list(statement_options) do
      fun = fn stream_result ->
        {_, globals} =
          Pythonx.eval(
            """
            try:
              import pyarrow
              reader = pyarrow.RecordBatchReader._import_from_c(pointer)
              pyarrow_available = True
              table = reader.read_all()
            except ImportError:
              pyarrow_available = False
              table = None
            """,
            %{"pointer" => stream_result.pointer}
          )

        {Pythonx.decode(globals["pyarrow_available"]), globals["table"]}
      end

      case query_pointer(conn, query, params, fun, statement_options) do
        {:ok, {pyarrow_available, py_table}} ->
          if not pyarrow_available do
            raise """
            Adbc.Connection.py_query/4 requires pyarrow package to be available in your pythonx installation. Add it to your dependency list:

                pyarrow==23.0.0
            """
          end

          {:ok, py_table}

        other ->
          other
      end
    end
  else
    def py_query(_conn, query, params \\ [], statement_options \\ [])
        when (is_binary(query) or is_reference(query)) and is_list(params) and
               is_list(statement_options) do
      raise """
      Adbc.Connection.py_query/4 requires pythonx to be available, add it to your mix.exs:

          {:pythonx, "~> 0.4.0"}
      """
    end
  end

  @doc """
  Get metadata about the database/driver.

  The result is an Arrow dataset with the following schema:

  | Field Name                 |  Field Type    | Null Constraint  |
  | -------------------------- | ---------------|----------------- |
  | `info_name`                |  `uint32`      | not null         |
  | `info_value`               |  `INFO_SCHEMA` |                  |

  `INFO_SCHEMA` is a dense union with members:

  | Field Name       | Type Code |  Field Type                   |
  | -----------------| --------- | ----------------------------- |
  | `string_value`              | 0 |  `utf8`                    |
  | `bool_value`                | 1 |  `bool`                    |
  | `int64_value`               | 2 |  `int64`                   |
  | `int32_bitmask`             | 3 |  `int32`                   |
  | `string_list`               | 4 |  `list<utf8>`              |
  | `int32_to_int32_list_map`   | 5 |  `map<int32, list<int32>>` |

  Each metadatum is identified by an integer code. The recognized
  codes are defined as constants. Codes [0, 10_000) are reserved
  for ADBC usage. Drivers/vendors will ignore requests for
  unrecognized codes (the row will be omitted from the result).
  """
  @spec get_info(t(), list(non_neg_integer())) ::
          {:ok, Adbc.Result.t()} | {:error, Exception.t()}
  def get_info(conn, info_codes \\ []) when is_list(info_codes) do
    stream(conn, {:adbc_connection_get_info, [info_codes]}, &stream_results/3)
  end

  @doc """
  Get a hierarchical view of all catalogs, database schemas, tables, and columns.

  The result is an Arrow dataset with the following schema:

  | Field Name               | Field Type                |
  |--------------------------|---------------------------|
  | `catalog_name`           | `utf8`                    |
  | `catalog_db_schemas`     | `list<DB_SCHEMA_SCHEMA>`  |

  `DB_SCHEMA_SCHEMA` is a Struct with fields:

  | Field Name             | Field Type              |
  |------------------------|-------------------------|
  | `db_schema_name`       | `utf8`                  |
  | `db_schema_tables`     | `list<TABLE_SCHEMA>`    |

  `TABLE_SCHEMA` is a Struct with fields:

  | Field Name           | Field Type                | Null Contstraint   |
  |----------------------|---------------------------|--------------------|
  | `table_name`         | `utf8`                    | not null           |
  | `table_type`         | `utf8`                    | not null           |
  | `table_columns`      | `list<COLUMN_SCHEMA>`     |                    |
  | `table_constraints`  | `list<CONSTRAINT_SCHEMA>` |                    |

  `COLUMN_SCHEMA` is a Struct with fields:

  | Field Name                 | Field Type  | Null Contstraint | Comments |
  |----------------------------|-------------|------------------|----------|
  | `column_name`              | `utf8`      | not null         |          |
  | `ordinal_position`         | `int32`     |                  | (1)      |
  | `remarks`                  | `utf8`      |                  | (2)      |
  | `xdbc_data_type`           | `int16`     |                  | (3)      |
  | `xdbc_type_name`           | `utf8`      |                  | (3)      |
  | `xdbc_column_size`         | `int32`     |                  | (3)      |
  | `xdbc_decimal_digits`      | `int16`     |                  | (3)      |
  | `xdbc_num_prec_radix`      | `int16`     |                  | (3)      |
  | `xdbc_nullable`            | `int16`     |                  | (3)      |
  | `xdbc_column_def`          | `utf8`      |                  | (3)      |
  | `xdbc_sql_data_type`       | `int16`     |                  | (3)      |
  | `xdbc_datetime_sub`        | `int16`     |                  | (3)      |
  | `xdbc_char_octet_length`   | `int32`     |                  | (3)      |
  | `xdbc_is_nullable`         | `utf8`      |                  | (3)      |
  | `xdbc_scope_catalog`       | `utf8`      |                  | (3)      |
  | `xdbc_scope_schema`        | `utf8`      |                  | (3)      |
  | `xdbc_scope_table`         | `utf8`      |                  | (3)      |
  | `xdbc_is_autoincrement`    | `bool`      |                  | (3)      |
  | `xdbc_is_generatedcolumn`  | `bool`      |                  | (3)      |

  1. The column's ordinal position in the table (starting from 1).
  2. Database-specific description of the column.
  3. Optional value. Should be null if not supported by the driver.
     `xdbc_` values are meant to provide JDBC/ODBC-compatible metadata
     in an agnostic manner.

  `CONSTRAINT_SCHEMA` is a Struct with fields:

  | Field Name                | Field Type           | Null Contstraint | Comments |
  |---------------------------|----------------------|------------------|----------|
  | `constraint_name`         | `utf8`               |                  |          |
  | `constraint_type`         | `utf8`               | not null         | (1)      |
  | `constraint_column_names` | `list<utf8>`         | not null         | (2)      |
  | `constraint_column_usage` | `list<USAGE_SCHEMA>` |                  | (3)      |

  1. One of 'CHECK', 'FOREIGN KEY', 'PRIMARY KEY', or 'UNIQUE'.
  2. The columns on the current table that are constrained, in order.
  3. For FOREIGN KEY only, the referenced table and columns.

  `USAGE_SCHEMA` is a Struct with fields:

  | Field Name               | Field Type    | Null Contstraint |
  |--------------------------|---------------|------------------|
  | `fk_catalog`             | `utf8`        |                  |
  | `fk_db_schema`           | `utf8`        |                  |
  | `fk_table`               | `utf8`        | not null         |
  | `fk_column_name`         | `utf8`        | not null         |
  """
  @spec get_objects(
          t(),
          non_neg_integer(),
          catalog: String.t(),
          db_schema: String.t(),
          table_name: String.t(),
          table_type: [String.t()],
          column_name: String.t()
        ) :: {:ok, Adbc.Result.t()} | {:error, Exception.t()}
  def get_objects(conn, depth, opts \\ [])
      when is_integer(depth) and depth >= 0 do
    opts = Keyword.validate!(opts, [:catalog, :db_schema, :table_name, :table_type, :column_name])

    args = [
      depth,
      opts[:catalog],
      opts[:db_schema],
      opts[:table_name],
      opts[:table_type],
      opts[:column_name]
    ]

    stream(conn, {:adbc_connection_get_objects, args}, &stream_results/3)
  end

  @doc """
  Gets the underlying driver of a connection process.

  ## Examples

      ADBC.Connection.get_driver(conn)
      #=> {:ok, :sqlite}
  """
  @spec get_driver(t()) :: {:ok, atom() | String.t()} | :error
  def get_driver(conn) do
    with pid when pid != nil <- GenServer.whereis(conn),
         {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {:adbc_driver, module} <- List.keyfind(dictionary, :adbc_driver, 0),
         do: {:ok, module},
         else: (_ -> :error)
  end

  @doc """
  Get a list of table types in the database.

  The result is an Arrow dataset with the following schema:

  | Field Name     | Field Type    | Null Contstraint |
  |----------------|---------------|------------------|
  | `table_type`   | `utf8`        | not null         |

  """
  @spec get_table_types(t) ::
          {:ok, Adbc.Result.t()} | {:error, Exception.t()}
  def get_table_types(conn) do
    stream(conn, {:adbc_connection_get_table_types, []}, &stream_results/3)
  end

  defp command(conn, command) do
    case GenServer.call(conn, {:command, command}, :infinity) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, error_to_exception(reason)}
    end
  end

  defp stream(conn, command, fun) do
    case GenServer.call(conn, {:stream, command}, :infinity) do
      {:ok, conn, unlock_ref, stream_ref, rows_affected} ->
        try do
          fun.(conn, stream_ref, normalize_rows(rows_affected))
        after
          GenServer.cast(conn, {:unlock, unlock_ref})
        end

      {:error, reason} ->
        {:error, error_to_exception(reason)}
    end
  end

  defp normalize_rows(nil), do: nil
  defp normalize_rows(-1), do: nil
  defp normalize_rows(rows) when is_integer(rows) and rows >= 0, do: rows

  defp stream_results(_conn, reference, num_rows), do: do_stream_results(reference, [], num_rows)

  defp do_stream_results(reference, acc, num_rows) do
    case Adbc.Nif.adbc_arrow_array_stream_next(reference) do
      {:ok, :end_of_series} ->
        {:ok, %Adbc.Result{data: Enum.reverse(acc), num_rows: num_rows}}

      {:ok, columns} ->
        do_stream_results(reference, [columns | acc], num_rows)

      {:error, reason} ->
        {:error, error_to_exception(reason)}
    end
  end

  ## Callbacks

  @impl true
  def init({db, conn}) do
    case GenServer.call(db, {:initialize_connection, conn}, :infinity) do
      {:ok, driver} ->
        Process.put(:adbc_driver, driver)
        {:ok, %{conn: conn, lock: :none, queue: :queue.new(), ingest_counter: 0}}

      {:error, reason} ->
        {:stop, error_to_exception(reason)}
    end
  end

  @impl true
  def handle_call({:stream, command}, from, state) do
    state = update_in(state.queue, &:queue.in({:stream, command, from}, &1))
    {:noreply, maybe_dequeue(state)}
  end

  def handle_call({:command, command}, from, state) do
    state = update_in(state.queue, &:queue.in({:command, command, from}, &1))
    {:noreply, maybe_dequeue(state)}
  end

  def handle_call({:option, func, args}, _from, state = %{conn: conn}) do
    {:reply, Adbc.Helper.option(conn, func, args), state}
  end

  @impl true
  def handle_cast({:unlock, ref}, %{lock: {ref, stream_ref}} = state) do
    # We could let the GC be the one release it but,
    # since a stream can be a large resource, we release
    # it now and let the GC free the remaining resources.
    Adbc.Nif.adbc_arrow_array_stream_release(stream_ref)
    Process.demonitor(ref, [:flush])
    {:noreply, maybe_dequeue(%{state | lock: :none})}
  end

  @impl true
  def handle_info({:DOWN, ref, _, _, _}, %{lock: {ref, stream_ref}} = state) do
    Adbc.Nif.adbc_arrow_array_stream_release(stream_ref)
    {:noreply, maybe_dequeue(%{state | lock: :none})}
  end

  def handle_info({:execute_on_gc, statement}, state) do
    state = update_in(state.queue, &:queue.in({:command, {:execute_on_gc, statement}, nil}, &1))
    {:noreply, maybe_dequeue(state)}
  end

  ## Queue helpers

  defp maybe_dequeue(%{lock: :none, queue: queue} = state) do
    case :queue.out(queue) do
      {:empty, queue} ->
        %{state | queue: queue}

      {{:value, {:command, command, from}}, queue} ->
        {result, state} = handle_command(command, %{state | queue: queue})
        if from, do: GenServer.reply(from, result)
        maybe_dequeue(state)

      {{:value, {:stream, command, from}}, queue} ->
        {pid, _} = from

        case handle_stream(command, state.conn) do
          {:ok, stream_ref, rows_affected} when is_reference(stream_ref) ->
            unlock_ref = Process.monitor(pid)
            GenServer.reply(from, {:ok, self(), unlock_ref, stream_ref, rows_affected})
            %{state | lock: {unlock_ref, stream_ref}, queue: queue}

          {:error, error} ->
            GenServer.reply(from, {:error, error})
            maybe_dequeue(%{state | queue: queue})
        end
    end
  end

  defp maybe_dequeue(state), do: state

  defp handle_command({:prepare, query}, state) do
    with {:ok, stmt} <- create_statement(state.conn, query),
         :ok <- Adbc.Nif.adbc_statement_prepare(stmt) do
      {{:ok, stmt}, state}
    else
      error -> {error, state}
    end
  end

  defp handle_command({:bulk_insert_stream, stream_ref, capsule, options}, state) do
    result =
      with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(state.conn),
           :ok <- init_statement_options(stmt, options),
           :ok <- Adbc.Nif.adbc_statement_bind_stream(stmt, stream_ref),
           {:ok, rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        Adbc.Helper.noop(capsule)
        {:ok, rows_affected}
      end

    {result, state}
  end

  defp handle_command({:bulk_insert, columns, options}, state) do
    result =
      with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(state.conn),
           :ok <- init_statement_options(stmt, options),
           :ok <- Adbc.Nif.adbc_statement_bind(stmt, columns),
           {:ok, rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        {:ok, rows_affected}
      end

    {result, state}
  end

  defp handle_command({:ingest_stream, stream_ref, capsule}, state) do
    {table_name, options, state} = next_ingest_opts(state)

    result =
      with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(state.conn),
           :ok <- init_statement_options(stmt, options),
           :ok <- Adbc.Nif.adbc_statement_bind_stream(stmt, stream_ref),
           {:ok, rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        Adbc.Helper.noop(capsule)
        ref = Adbc.Nif.adbc_execute_on_gc_new(self(), "DROP TABLE IF EXISTS #{table_name}")
        {:ok, %Adbc.IngestResult{ref: ref, table: table_name, num_rows: rows_affected}}
      end

    {result, state}
  end

  defp handle_command({:ingest, columns}, state) do
    {table_name, options, state} = next_ingest_opts(state)

    result =
      with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(state.conn),
           :ok <- init_statement_options(stmt, options),
           :ok <- Adbc.Nif.adbc_statement_bind(stmt, columns),
           {:ok, rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        ref = Adbc.Nif.adbc_execute_on_gc_new(self(), "DROP TABLE IF EXISTS #{table_name}")
        {:ok, %Adbc.IngestResult{ref: ref, table: table_name, num_rows: rows_affected}}
      end

    {result, state}
  end

  defp handle_command({:execute, query_or_prepared, params, statement_options}, state) do
    result =
      with {:ok, stmt} <- ensure_statement(state.conn, query_or_prepared, statement_options),
           :ok <- maybe_bind(stmt, params),
           {:ok, rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        {:ok, normalize_rows(rows_affected)}
      end

    {result, state}
  end

  defp handle_command({:execute_on_gc, statement}, state) do
    result =
      with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(state.conn),
           :ok <- Adbc.Nif.adbc_statement_set_sql_query(stmt, statement),
           {:ok, _rows_affected} <- Adbc.Nif.adbc_statement_execute(stmt) do
        :ok
      end

    {result, state}
  end

  defp next_ingest_opts(state) do
    counter = state.ingest_counter
    table_name = "adbc_ingest_#{counter}"

    options = [
      {"adbc.ingest.target_table", table_name},
      {"adbc.ingest.temporary", "true"}
    ]

    {table_name, options, %{state | ingest_counter: counter + 1}}
  end

  defp handle_stream({:query, query_or_prepared, params, statement_options}, conn) do
    with {:ok, stmt} <- ensure_statement(conn, query_or_prepared, statement_options),
         :ok <- maybe_bind(stmt, params) do
      Adbc.Nif.adbc_statement_execute_query(stmt)
    end
  end

  defp handle_stream({name, args}, conn) do
    with {:ok, stream_ref} <- apply(Adbc.Nif, name, [conn | args]) do
      {:ok, stream_ref, -1}
    end
  end

  defp ensure_statement(conn, query, statement_options)
       when is_binary(query) and is_list(statement_options),
       do: create_statement(conn, query, statement_options)

  defp ensure_statement(_conn, prepared, _statement_options) when is_reference(prepared),
    do: {:ok, prepared}

  defp create_statement(conn, query, statement_options \\ []) when is_list(statement_options) do
    with {:ok, stmt} <- Adbc.Nif.adbc_statement_new(conn),
         :ok <- Adbc.Nif.adbc_statement_set_sql_query(stmt, query),
         :ok <- init_statement_options(stmt, statement_options) do
      {:ok, stmt}
    end
  end

  defp maybe_bind(_stmt, []), do: :ok

  defp maybe_bind(stmt, params) do
    Adbc.Nif.adbc_statement_bind(stmt, params)
  end
end

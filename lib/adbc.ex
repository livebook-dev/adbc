defmodule Adbc do
  @moduledoc """
  Bindings for Arrow Database Connectivity (ADBC).

  Adbc provides a standard database interface using the
  Apache Arrow format.

  ## Installation

  First, add `:adbc` as a dependency in your `mix.exs`:

      {:adbc, "~> 0.1"}

  Now, in your config/config.exs, configure the drivers you
  are going to use:

      config :adbc, :drivers, [:sqlite]

  If you are using a notebook or scripting, you can also use
  `Adbc.download_driver!/1` to dynamically download one. See
  the function for more information on downloading drivers.

  Then start the database and the relevant connection processes
  in your supervision tree:

      children = [
        {Adbc.Database,
         driver: :sqlite,
         process_options: [name: MyApp.DB]},
        {Adbc.Connection,
         database: MyApp.DB,
         process_options: [name: MyApp.Conn]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  In a notebook, the above would look like this:

      db = Kino.start_child!({Adbc.Database, driver: :sqlite})
      conn = Kino.start_child!({Adbc.Connection, database: db})

  And now you can make queries with:

      # For named connections
      {:ok, _} = Adbc.Connection.query(MyApp.Conn, "SELECT 123")

      # When using the conn PID directly
      {:ok, _} = Adbc.Connection.query(conn, "SELECT 123")

  ## Supported drivers

  Below we list all drivers supported out of the box. You may also
  give the full path to a driver in the `:driver` option to load other
  existing drivers.

  ### DuckDB

  The DuckDB driver provides access to DuckDB databases. See their
  [documentation](https://duckdb.org/docs/stable/clients/adbc) for more details.

  #### Examples

  For in memory;

      {Adbc.Database, driver: :duckdb}

  To use an existing file:

      {Adbc.Database, driver: :duckdb, path: "duck.duckdb"}

  Note if you are pointing to your own build of duckdb you will need to set the entrypoint like so:

      {Adbc.Database, driver: "/usr/local/lib/libduckdb.so", entrypoint: "duckdb_adbc_init"}

  ### PostgreSQL

  The PostgreSQL driver provides access to any database that supports
  the PostgreSQL wire format. It is implemented as a wrapper around
  `libpq`.

  #### Examples

      {Adbc.Database, driver: :postgresql, uri: "postgresql://postgres@localhost"}

  You must pass the `:uri` option using Postgres'
  [connection URI](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING):

  ### Sqlite

  The SQLite driver provides access to SQLite databases.

  #### Examples

      {Adbc.Database, driver: :sqlite, uri: ":memory:"}
      {Adbc.Database, driver: :sqlite, uri: "./db/my.db"}
      {Adbc.Database, driver: :sqlite, uri: "file:/path/to/file/in/disk.db"}

  The `:uri` option should be, ":memory:", a filename or
  [URI filename](https://www.sqlite.org/c3ref/open.html#urifilenamesinsqlite3open).
  If omitted, it will default to an in-memory database, but
  one that is shared across all connections.

  ### Snowflake

  The Snowflake driver provides access to Snowflake Database Warehouses.

  #### Examples

  Snowflake recommends PKCS8 key pair authentication, using `auth_jwt` as shown below:

      {Adbc.Database, driver: :snowflake,
       uri:
        "<user>@<account>.<region>.snowflakecomputing.com/<database>?warehouse=<warehouse>&role=<role>&authenticator=SNOWFLAKE_JWT",
       "adbc.snowflake.sql.auth_type": "auth_jwt",
       "adbc.snowflake.sql.client_option.jwt_private_key_pkcs8_value":
         File.read!(System.fetch_env!("SNOWFLAKE_ENCRYPTED_KEY_FILE")),
       "adbc.snowflake.sql.client_option.jwt_private_key_pkcs8_password":
         System.fetch_env!("SNOWFLAKE_KEY_PASSWORD")}

  See [Account identifiers](https://docs.snowflake.com/en/user-guide/admin-account-identifier) for more information.

  For backwards compatibility, you may also use username+password as shown below:

      {Adbc.Database, driver: :snowflake, uri: "..."}

  where Snowflake URI should be of one of the following formats:

      user[:password]@account/database/schema[?param1=value1&paramN=valueN]
      user[:password]@account/database[?param1=value1&paramN=valueN]
      user[:password]@host:port/database/schema?account=user_account[&param1=value1&paramN=valueN]
      host:port/database/schema?account=user_account[&param1=value1&paramN=valueN]

  The first two are the most recommended formats. The schema, database and parameters are optional.
  """

  @doc """
  Downloads a driver and returns the download status.

  It returns `:ok` or `{:error, binary}`. See `download_driver!/1`
  for more information.
  """
  @spec download_driver(atom, keyword) :: :ok | {:error, binary}
  def download_driver(driver, opts \\ []) when is_atom(driver) and is_list(opts) do
    Adbc.Driver.download(driver, opts)
  end

  @doc """
  Downloads a driver and raises in case of errors.

  It returns `:ok`.

  See `Adbc` module documentation for all supported drivers.

  ## Options

    * `:version` - the version of the asset being downloaded
    * `:url` - the url to find the precompiled asset

  For example, to download the latest DuckDB driver, you must find its
  [latest release on GitHub](https://github.com/duckdb/duckdb/releases/),
  and pass the version and the precompiled asset to your OS. For example,
  if the latest version is v1.3.0, you can invoke:

      Adbc.download_driver!(:duckdb,
        version: "1.3.0",
        url: "https://github.com/duckdb/duckdb/releases/download/v1.3.0/libduckdb-osx-universal.zip"
      )

  And then start the driver passing the version option:

      {Adbc.Database, driver: :duckdb, version: "1.3.0"}

  Note you can also configure the `:adbc` application to download
  a custom driver during compilation too:

      config :adbc, :drivers,
        [{:duckdb, version: ..., url: ...}]

  """
  @spec download_driver!(atom, keyword) :: :ok
  def download_driver!(driver, opts \\ []) when is_atom(driver) and is_list(opts) do
    case download_driver(driver, opts) do
      :ok -> :ok
      {:error, reason} -> raise "could not download Adbc driver for #{driver}: " <> reason
    end
  end
end

for driver <- Application.compile_env(:adbc, :drivers, []) do
  case driver do
    {driver, opts} -> Adbc.download_driver!(driver, opts)
    driver -> Adbc.download_driver!(driver)
  end
end

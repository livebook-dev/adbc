# Adbc

[![Hex.pm](https://img.shields.io/hexpm/v/adbc.svg?style=flat&color=blue)](https://hex.pm/packages/adbc)

Elixir bindings for Arrow Database Connectivity (ADBC).

Adbc provides a standard database interface using the
Apache Arrow format. See [`Adbc`](https://hexdocs.pm/adbc/Adbc.html)
documentation for setting it up and the available drivers.

## Quick run-through

First, add `:adbc` as a dependency in your `mix.exs`:

```elixir
{:adbc, "~> 0.6"}
```

Now, in your config/config.exs, configure the drivers you
are going to use. Let's use sqlite3 as an example
(see [`Adbc`](https://hexdocs.pm/adbc/Adbc.html) for all
supported drivers):

```elixir
config :adbc, :drivers, [:sqlite]
```

If you are using a notebook or scripting, you can also use
`Adbc.download_driver!/1` to dynamically download one.

Then start the database and the relevant connection processes
in your supervision tree:

```elixir
children = [
  {Adbc.Database,
   driver: :sqlite,
   process_options: [name: MyApp.DB]},
  {Adbc.Connection,
   database: MyApp.DB,
   process_options: [name: MyApp.Conn]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

In a notebook, the above would look like this:

```elixir
{:ok, db} = Kino.start_child({Adbc.Database, driver: :sqlite})
{:ok, conn} = Kino.start_child({Adbc.Connection, database: db})
```

And now you can make queries with:

```elixir
# For named connections
{:ok, _} = Adbc.Connection.query(MyApp.Conn, "SELECT 123")

# When using the conn PID directly
{:ok, _} = Adbc.Connection.query(conn, "SELECT 123")
```

## Precompiled artifacts

This project ships with precompiled artifacts. You can force the artifacts to be built by setting `ADBC_BUILD=1` or via the following application configuration:

```elixir
config :elixir_make, :force_build, adbc: true
```

This does require you have `cmake` installed.

## License

Copyright 2023 Cocoa Xu, José Valim

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

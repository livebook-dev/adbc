# CHANGELOG

## v0.12.1

#### Enhancements

* Relax decimal requirement

## v0.12.0

#### Enhancements

* Add ADBC Driver Foundry community drivers (databricks, mysql, trino, exasol)
* Support decimals in `Adbc.Column.new`
* Improve reliability and resource management by using FINE

## v0.11.0

#### Enhancements

* Allow maps to be given to `Adbc.Column.new`
* Optimize `Adbc.Column.to_list` when there is no validity
* Add `Adbc.Connection.execute` which does not return a result set

#### Backwards incompatible changes

* Move `Adbc.Result.to_ipc_stream` to `Adbc.StreamResult.to_ipc_stream`

## v0.10.0

#### Enhancements

* Add `Adbc.Column.new` that automatically infers column types
* Add `Adbc.Column.has_validity?` that returns if the column has a validity bitmap (and therefore may have nils)
* Add `Adbc.Column.to_binary` that returns the binary blob of a column (as a reference to its underlying arrow buffer)
* Add `Adbc.Connection.ingest` that copies that into a temporary table that is removed when its result is garbage collected
* Allow a keyword list in `Adbc.Connection.ingest` and `Adbc.Connection.bulk_insert`
* Add `Adbc.Result.to_columns` to access column data while keeping its underlying struct private
* Add `Adbc.Result.from_ipc_stream` and `Adbc.Result.to_ipc_stream`
* Add `Adbc.StreamResult.from_ipc_stream`

#### Backwards incompatible changes

* The data field of `Adbc.Result` is now private. Use `Adbc.Result.to_columns` to retrieve its contents in a similar shape as before
* Move schema properties from `Adbc.Column` into `Adbc.Field`

## v0.9.0

Require Erlang/OTP 26+.

#### Enhancements

* Add `Adbc.Connection.bulk_insert`
* Add `Adbc.Connection.py_query` for fetching Python tables
* Add `Adbc.Result.from_py` to read data from Python
* Allow fast data transfer across connections
* Add support for string/binary view types

## v0.8.0

Require Erlang/OTP 26+.

#### Enhancements

* Support structs in `Adbc.Column.to_list`
* Implement `Table.Reader` for `ADBC.Result`
* Update to latest DuckDB
* Allow version to be given on database start

## v0.7.9

#### Changes

* Update to latest ADBC
* Update to latest DuckDB
* Update to Erlang/OTP 25+

#### Fixes

* Ensure all arrow fields are correctly decoded
* Properly handle decimal fields where the bits are set

## v0.7.8

#### Fixes

* Initialize DLL on nif load (#126)
* Fixed the issue introduced in #122
* Creating `bin` directory if it does not exist on Windows before adding it to the DLL searching path (#123)
* Embedding dll loader as another NIF to avoid failures when running in release mode (#120)

## v0.7.3

#### Fixes

* Assign NIFs to `ERL_NIF_DIRTY_JOB_{CPU,IO}_BOUND` accordingly (#119)

## v0.7.2

#### Changed

* Improve compatibility with latest Decimal

## v0.7.1

#### Changed

* Use `ArrowArrayInitFromType` when building list of strings

## v0.7.0

#### Changed

* Added an environment variable `ADBC_BUILD`. Set to `true` to force compile locally.
* Updated to ADBC library 16-rc0.

## v0.6.5

#### Added

* Added an environment variable `ADBC_PREFER_PRECOMPILED`. Set to `false` to force compile locally.

#### Changed

* Updated to ADBC library 15.

## v0.6.4

#### Fixes

* Fixed the issue with the `clean` target in the Makefile not removing all relevant files (#109)

## v0.6.3

#### Changes

* Updated to ADBC library 14, https://github.com/apache/arrow-adbc/releases/tag/apache-arrow-adbc-14
* Updated to DuckDB 1.1.2, https://github.com/duckdb/duckdb/releases/tag/v1.1.2
* Added precompiled binaries for `aarch64-linux-gnu`.

## v0.6.2

#### Fixes

* Handle `nil` values in `Adbc.Column.materialize/1` for decimal type (#103)

## v0.6.1

#### Changes

* Precompiling NIFs on `ubuntu-20.04` thus lowering the minimum required GLIBCXX version to `3.4.21`.

## v0.6.0

#### Breaking changes
* To avoid allocating data twice for inputs, the results now by default will return references in the data field of `Adbc.Column`.

  If you need to use them in the Elixir world, you can use `Adbc.Result.materialize/1` and
  `Adbc.Column.materialize/1` to convert the data to regular Elixir terms.

  ```elixir
  iex> {:ok, results} = Connection.query(conn, "SELECT 123 as num, 456.78 as fp")
  {:ok,
    results = %Adbc.Result{
      data: [
          %Adbc.Column{
            name: "num",
            type: :s64,
            metadata: nil,
            nullable: true,
            data: [#Reference<0.351247108.3006922760.20174>]
          },
          %Adbc.Column{
            name: "fp",
            type: :f64,
            metadata: nil,
            nullable: true,
            data: [#Reference<0.351247108.3006922760.20175>]
          }
      ],
      num_rows: nil
  }}
  iex> Adbc.Result.materialize(results)
  %Adbc.Result{
    data: [
      %Adbc.Column{
        name: "num",
        type: :s64,
        nullable: true,
        metadata: nil,
        data: [123]
      },
      %Adbc.Column{
        name: "fp",
        type: :f64,
        nullable: true,
        metadata: nil,
        data: [456.78]
      }
    ]
  }
  ```

## v0.5.0

#### Breaking changes
* Signed integer types and functions are now renamed from `s{8,16,32,64}` to `i{8,16,32,64}`

#### Changes
* Updated to ADBC library 12.

#### Fix
* Boolean arrays are now correctly parsed.
* Include `CMakeLists.txt` in package files

#### Added
* Added support for dictionary encoded array

## v0.4.2

#### Added
* Added support for run-end encoded array

#### Fix
* Include `CMakeLists.txt` in package files

## v0.4.1

#### Fix
* Remove debug print

## v0.4.0

#### Changes
* Use `Adbc.Column` for inputs and outputs of result sets

  `Adbc.Column` is a new module that represents columns in a result set. It
  supports all primitive types and lists of primitive types (nested list support
  is not yet implemented).

  Use `Adbc.Result.to_map/1`` to convert a result set to a maps of lists, where
  each key is a column name and the value is a list of values for that column.

* Add `ADBC_CACERTS_PATH` to allow for custom certs (#75)
* Support bind named parameters via `Adbc.Column` (#84)
* Expose more APIs (#64)
  - `Adbc.Database.get_option/2`
  - `Adbc.{Database,Connection}.{get,set}_option`
  - `Adbc.Connection.query_with_options/4`

#### Fixes
* Fix: set parameter length (rows) correctly (#85)
* Fix: parsing dense/sparse union (#63)

## v0.3.1

* Fix erroneous ADBC driver URLs

## v0.3.0

* Update to ADBC 0.11.0-rc0
* Builtin support for DuckDB
* Fix tables in inline docs of `Adbc.Connection` (@lkarthee in #57)
* Default to erlang certificate store (@lkarthee in #57)

## v0.2.3

* Update to ADBC 0.10.0
* Using NIF version 2.16 for all precompilation targets (@cocoa-xu in #54)
* Add API for prepared queries (@dlindenkreuz in #51)

## v0.2.2

* Update to ADBC 0.8.0

## v0.2.1

* Fix URLs for downloading drivers

## v0.2.0

* Update to ADBC 0.7.0
* Parse date, time, and timestamps

## v0.1.1

* Add `Adbc.Connection.get_driver/1`
* Add `Adbc.Connection.query!/3`

## v0.1.0

* Initial release.

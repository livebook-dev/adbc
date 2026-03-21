defmodule Adbc.DuckDBTest do
  use ExUnit.Case, async: true

  alias Adbc.Connection

  @moduletag :duckdb

  setup do
    db = start_supervised!({Adbc.Database, driver: :duckdb})
    conn = start_supervised!({Connection, database: db})

    %{db: db, conn: conn}
  end

  test "error", %{conn: conn} do
    assert {:error, %Adbc.Error{} = error} =
             Adbc.Connection.query(conn, "SELECT * from $1", ["foo"])

    assert Exception.message(error) =~ "Parser Error"
  end

  test "structs", %{conn: conn} do
    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "struct_pack(col1 := 1, col2 := 2)",
                   type:
                     {:struct,
                      [
                        %Adbc.Field{
                          name: "col1",
                          type: :s32,
                          nullable: true,
                          metadata: nil
                        },
                        %Adbc.Field{
                          name: "col2",
                          type: :s32,
                          nullable: true,
                          metadata: nil
                        }
                      ]}
                 }
               }
             ],
             num_rows: 0
           } = Adbc.Connection.query!(conn, "SELECT struct_pack(col1 := 1, col2 := 2)")
  end

  test "decimal128", %{conn: conn} do
    columns = [
      Adbc.Column.decimal128([Decimal.new("1.23"), Decimal.new("-4.56"), nil], 10, 2,
        name: "dec_col",
        nullable: true
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "decimals")

    {:ok, result} = Connection.query(conn, "SELECT * FROM decimals")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["dec_col"] == [Decimal.new("1.23"), Decimal.new("-4.56"), nil]
  end

  @tag :unix
  test "lists", %{conn: conn} do
    columns = [
      Adbc.Column.s32([1, 2, 3], name: "id"),
      Adbc.Column.list(
        [[10, 20], [30], [40, 50, 60]],
        Adbc.Field.new(:s32),
        name: "nums"
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "lists")

    {:ok, result} = Connection.query(conn, "SELECT * FROM lists ORDER BY id")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["id"] == [1, 2, 3]
    assert map["nums"] == [[10, 20], [30], [40, 50, 60]]
  end

  test "dictionary", %{conn: conn} do
    columns = [
      Adbc.Column.dictionary(
        Adbc.Column.s32([0, 1, 0, 2, 1], nullable: true),
        Adbc.Column.string(["foo", "bar", "baz"]),
        name: "val"
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "dicts")

    {:ok, result} = Connection.query(conn, "SELECT * FROM dicts")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    [values] = Map.values(map)
    assert values == ["foo", "bar", "foo", "baz", "bar"]
  end

  test "floats", %{conn: conn} do
    columns = [
      Adbc.Column.f32([1, 2.5, :nan, :infinity, :neg_infinity, nil],
        name: "f32_col",
        nullable: true
      ),
      Adbc.Column.f64([10, 20.5, :nan, :infinity, :neg_infinity, nil],
        name: "f64_col",
        nullable: true
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "floats")

    {:ok, result} = Connection.query(conn, "SELECT * FROM floats")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["f32_col"] == [1.0, 2.5, :nan, :infinity, :neg_infinity, nil]
    assert map["f64_col"] == [10.0, 20.5, :nan, :infinity, :neg_infinity, nil]
  end

  test "integers", %{conn: conn} do
    columns = [
      Adbc.Column.s8([1, -1, nil], name: "s8_col", nullable: true),
      Adbc.Column.s16([100, -100, nil], name: "s16_col", nullable: true),
      Adbc.Column.s32([1000, -1000, nil], name: "s32_col", nullable: true),
      Adbc.Column.s64([10000, -10000, nil], name: "s64_col", nullable: true)
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "integers")

    {:ok, result} = Connection.query(conn, "SELECT * FROM integers")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["s8_col"] == [1, -1, nil]
    assert map["s16_col"] == [100, -100, nil]
    assert map["s32_col"] == [1000, -1000, nil]
    assert map["s64_col"] == [10000, -10000, nil]
  end

  test "strings and binary", %{conn: conn} do
    columns = [
      Adbc.Column.string(["hello", "world", nil], name: "str_col", nullable: true),
      Adbc.Column.binary([<<1, 2, 3>>, <<4, 5>>, nil], name: "bin_col", nullable: true)
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "strings")

    {:ok, result} = Connection.query(conn, "SELECT * FROM strings")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["str_col"] == ["hello", "world", nil]
    assert map["bin_col"] == [<<1, 2, 3>>, <<4, 5>>, nil]
  end

  test "temporal types with mixed struct and integer values", %{conn: conn} do
    # Each temporal type accepts both Elixir structs and raw integers.
    # We insert one struct value, one equivalent integer value, and nil,
    # then assert both decode to the same Elixir struct.

    # date32: days since Unix epoch
    epoch_days = Date.diff(~D[2024-01-15], ~D[1970-01-01])

    # timestamp: microseconds since Unix epoch
    epoch_us =
      DateTime.to_unix(DateTime.new!(~D[2024-01-15], ~T[10:30:00], "Etc/UTC"), :microsecond)

    # time: microseconds since midnight
    time_us = (10 * 3600 + 30 * 60) * 1_000_000

    columns = [
      Adbc.Column.date32([~D[2024-01-15], epoch_days, nil],
        name: "date_col",
        nullable: true
      ),
      Adbc.Column.timestamp([~N[2024-01-15 10:30:00], epoch_us, nil],
        :microseconds,
        "UTC",
        name: "ts_col",
        nullable: true
      ),
      Adbc.Column.time([~T[10:30:00], time_us, nil],
        :microseconds,
        name: "time_col",
        nullable: true
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "temporal")

    {:ok, result} = Connection.query(conn, "SELECT * FROM temporal")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["date_col"] == [~D[2024-01-15], ~D[2024-01-15], nil]

    assert map["ts_col"] == [
             ~N[2024-01-15 10:30:00.000000],
             ~N[2024-01-15 10:30:00.000000],
             nil
           ]

    assert map["time_col"] == [~T[10:30:00.000000], ~T[10:30:00.000000], nil]
  end

  test "booleans", %{conn: conn} do
    columns = [
      Adbc.Column.boolean([true, false, nil], name: "bool_col", nullable: true)
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "booleans")

    {:ok, result} = Connection.query(conn, "SELECT * FROM booleans")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["bool_col"] == [true, false, nil]
  end

  test "duration", %{conn: conn} do
    columns = [
      Adbc.Column.duration([1_000_000, -500_000, nil], :microseconds,
        name: "dur_col",
        nullable: true
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "durations")

    {:ok, result} = Connection.query(conn, "SELECT * FROM durations")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    # DuckDB converts durations to month_day_nano intervals (microseconds → nanoseconds)
    assert map["dur_col"] == [{0, 0, 1_000_000_000}, {0, 0, -500_000_000}, nil]
  end

  test "interval", %{conn: conn} do
    # interval month_day_nano: {months, days, nanoseconds}
    columns = [
      Adbc.Column.interval([{14, 3, 1_000_000_000}, {0, 0, 0}, nil], :month_day_nano,
        name: "iv_col",
        nullable: true
      )
    ]

    assert {:ok, _} = Connection.bulk_insert(conn, columns, table: "intervals")

    {:ok, result} = Connection.query(conn, "SELECT * FROM intervals")
    map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

    assert map["iv_col"] == [{14, 3, 1_000_000_000}, {0, 0, 0}, nil]
  end
end

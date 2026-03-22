defmodule Adbc.PostgresTest do
  use ExUnit.Case, async: true

  alias Adbc.Connection

  @moduletag :postgresql

  setup do
    db =
      start_supervised!(
        {Adbc.Database, driver: :postgresql, uri: "postgres://postgres:postgres@localhost"}
      )

    conn = start_supervised!({Connection, database: db})

    %{db: db, conn: conn}
  end

  test "runs queries", %{conn: conn} do
    assert {:ok, results} = Connection.query(conn, "SELECT 123 as num")

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "num",
                   type: :s32,
                   nullable: true,
                   metadata: nil
                 },
                 data: [[123]]
               }
             ]
           } = Adbc.Result.materialize(results)
  end

  test "list of strings", %{db: _, conn: conn} do
    ids = ["1", "2", "3"]

    assert {:ok, result} =
             Adbc.Connection.query(
               conn,
               "SELECT $1",
               [Adbc.Column.list([ids], Adbc.Field.new(:string))]
             )

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   type:
                     {:list,
                      %Adbc.Field{name: "item", type: :string, nullable: true, metadata: nil}},
                   metadata: nil,
                   nullable: true
                 },
                 data: [[["1", "2", "3"]]]
               }
             ]
           } = result |> Adbc.Result.materialize()
  end

  test "list of ints", %{conn: conn} do
    assert {:ok, results} = Connection.query(conn, "SELECT ARRAY[1, 2, 3, null, 5] as num")

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "num",
                   type:
                     {:list, %Adbc.Field{name: "item", type: :s32, nullable: true, metadata: nil}},
                   nullable: true,
                   metadata: nil
                 },
                 data: [[[1, 2, 3, nil, 5]]]
               }
             ]
           } = Adbc.Result.materialize(results)
  end

  test "nested lists", %{conn: conn} do
    assert {:ok, results} =
             Connection.query(
               conn,
               "SELECT ARRAY[ARRAY[1, 2, 3, null, 5], ARRAY[6, null, 7, null, 9]] as num"
             )

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "num",
                   type:
                     {:list, %Adbc.Field{name: "item", type: :s32, nullable: true, metadata: nil}},
                   nullable: true,
                   metadata: nil
                 },
                 data: [[[1, 2, 3, nil, 5, 6, nil, 7, nil, 9]]]
               }
             ]
           } = Adbc.Result.materialize(results)
  end

  test "temporal types", %{conn: conn} do
    query = """
    select
      '2023-03-01T10:23:45'::timestamp as datetime,
      '2023-03-01T10:23:45.123456'::timestamp as datetime_usec,
      '2023-03-01T10:23:45 PST'::timestamptz as datetime_tz_8601,
      '2023-03-01T10:23:45+02'::timestamptz as datetime_tz_offset,
      '2023-03-01'::date as date,
      '10:23:45'::time as time,
      '10:23:45.123456'::time as time_usec
    """

    assert {:ok, results} = Connection.query(conn, query)

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "datetime",
                   type: {:timestamp, :microseconds, nil},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = datetime_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "datetime_usec",
                   type: {:timestamp, :microseconds, nil},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = datetime_usec_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "datetime_tz_8601",
                   type: {:timestamp, :microseconds, "UTC"},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = datetime_tz_8601_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "datetime_tz_offset",
                   type: {:timestamp, :microseconds, "UTC"},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = datetime_tz_offset_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "date",
                   type: :date32,
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = date_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "time",
                   type: {:time64, :microseconds},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = time_col,
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "time_usec",
                   type: {:time64, :microseconds},
                   nullable: true,
                   metadata: nil
                 },
                 data: [{_, _, _}]
               } = time_usec_col
             ]
           } = Adbc.Result.materialize(results)

    assert Adbc.Column.to_list(datetime_col) == [~N[2023-03-01 10:23:45.000000]]
    assert Adbc.Column.to_list(datetime_usec_col) == [~N[2023-03-01 10:23:45.123456]]
    assert Adbc.Column.to_list(datetime_tz_8601_col) == [~N[2023-03-01 18:23:45.000000]]
    assert Adbc.Column.to_list(datetime_tz_offset_col) == [~N[2023-03-01 08:23:45.000000]]
    assert Adbc.Column.to_list(date_col) == [~D[2023-03-01]]
    assert Adbc.Column.to_list(time_col) == [~T[10:23:45.000000]]
    assert Adbc.Column.to_list(time_usec_col) == [~T[10:23:45.123456]]
  end

  test "floats (inf/-inf/nan)", %{db: _, conn: conn} do
    assert {:ok, results} =
             Adbc.Connection.query(
               conn,
               "SELECT ARRAY['infinity'::NUMERIC, '-infinity'::NUMERIC, 4.2::NUMERIC, 'nan'::NUMERIC];"
             )

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "array",
                   nullable: true,
                   metadata: nil,
                   type:
                     {:list,
                      %Adbc.Field{
                        name: "item",
                        type: :string,
                        nullable: true,
                        metadata: %{"ADBC:postgresql:typname" => "numeric"}
                      }}
                 },
                 data: [[["inf", "-inf", "4.2", "nan"]]]
               }
             ]
           } = Adbc.Result.materialize(results)
  end

  test "large arrow chunks", %{conn: conn} do
    query = """
    SELECT * FROM generate_series('2000-03-01 00:00'::timestamp, '2100-03-04 12:00'::timestamp, '15 minutes')
    """

    assert results =
             %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "generate_series",
                     type: {:timestamp, :microseconds, nil},
                     metadata: nil,
                     nullable: true
                   }
                 }
               ]
             } = Connection.query!(conn, query)

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "generate_series",
                   type: {:timestamp, :microseconds, nil},
                   nullable: true,
                   metadata: nil
                 },
                 data: generate_series
               } = col
             ]
           } = Adbc.Result.materialize(results)

    assert length(generate_series) > 1
    assert length(Adbc.Column.to_list(col)) == 3_506_641
  end

  test "query with parameters", %{db: _, conn: conn} do
    assert {:ok, result} =
             Adbc.Connection.query(
               conn,
               "SELECT $1 as x",
               [Adbc.Column.s32([1, 2, 3])]
             )

    result = result |> Adbc.Result.materialize()

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "x",
                   type: :s32,
                   metadata: nil,
                   nullable: true
                 }
               }
             ]
           } = result

    assert Adbc.Result.to_map(result) == %{"x" => [1, 2, 3]}
  end

  test "query with parameters, operator in", %{db: _, conn: conn} do
    values = [1, 2, 3]
    not_in_values = 4

    for v <- values do
      assert {:ok, result} =
               Adbc.Connection.query(
                 conn,
                 "SELECT ($2 = ANY($1))::int",
                 [Adbc.Column.list([values], Adbc.Field.new(:s32)), Adbc.Column.s32([v])]
               )

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "int4",
                     type: :s32,
                     metadata: nil,
                     nullable: true
                   },
                   data: [[1]]
                 }
               ]
             } = result |> Adbc.Result.materialize()
    end

    refute Enum.member?(values, not_in_values)

    assert {:ok, result} =
             Adbc.Connection.query(
               conn,
               "SELECT ($2 = ANY($1))::int",
               [
                 Adbc.Column.list([values], Adbc.Field.new(:s32)),
                 Adbc.Column.s32([not_in_values])
               ]
             )

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 field: %Adbc.Field{
                   name: "int4",
                   type: :s32,
                   metadata: nil,
                   nullable: true
                 },
                 data: [[0]]
               }
             ]
           } = result |> Adbc.Result.materialize()
  end

  test "top-level parameter values should have the same length/rows", %{db: _, conn: conn} do
    values = [1, 2, 3]
    not_in_values = 4

    assert_raise ArgumentError,
                 "Expected struct child 2 to have length >= 3 but found child with length 1",
                 fn ->
                   Adbc.Connection.query!(
                     conn,
                     "SELECT ($2 = ANY($1))::int",
                     [Adbc.Column.s32(values), Adbc.Column.s32([not_in_values])]
                   )
                 end
  end
end

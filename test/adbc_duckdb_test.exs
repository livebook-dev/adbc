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
                 name: "struct_pack(col1 := 1, col2 := 2)",
                 type:
                   {:struct,
                    [
                      %Adbc.Column{
                        name: "col1",
                        type: :s32,
                        nullable: true,
                        metadata: nil,
                        data: nil,
                        length: nil,
                        offset: nil
                      },
                      %Adbc.Column{
                        name: "col2",
                        type: :s32,
                        nullable: true,
                        metadata: nil,
                        data: nil,
                        length: nil,
                        offset: nil
                      }
                    ]}
               }
             ],
             num_rows: 0
           } = Adbc.Connection.query!(conn, "SELECT struct_pack(col1 := 1, col2 := 2)")
  end

  @tag :unix
  test "decimal128", %{conn: conn} do
    d1 = Decimal.new("1.2345678912345678912345678912345678912")
    d2 = Decimal.new("-1.2345678912345678912345678912345678912")
    d5 = Decimal.new("9876543210987654321098765432109876543.2")
    d6 = Decimal.new("-9876543210987654321098765432109876543.2")
    d7 = Decimal.new("1E-37")

    assert {:ok,
            results = %Adbc.Result{
              data: [
                %Adbc.Column{
                  name: "d1",
                  type: {:decimal, 128, 38, 37},
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d2",
                  type: {:decimal, 128, 38, 37},
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d3",
                  type: :f64,
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d4",
                  type: :f64,
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d5",
                  type: {:decimal, 128, 38, 1},
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d6",
                  type: {:decimal, 128, 38, 1},
                  metadata: nil,
                  nullable: true
                },
                %Adbc.Column{
                  name: "d7",
                  type: {:decimal, 128, 38, 37},
                  metadata: nil,
                  nullable: true
                }
              ]
            }} =
             Connection.query(
               conn,
               """
               SELECT
               1.2345678912345678912345678912345678912 as d1,
               -1.2345678912345678912345678912345678912 as d2,
               1.23456789123456789123456789123456789123 as d3,
               -1.23456789123456789123456789123456789123 as d4,
               9876543210987654321098765432109876543.2 as d5,
               -9876543210987654321098765432109876543.2 as d6,
               0.0000000000000000000000000000000000001 as d7,
               """
             )

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 name: "d1",
                 type: {:decimal, 128, 38, 37},
                 nullable: true,
                 metadata: nil,
                 data: [^d1]
               },
               %Adbc.Column{
                 name: "d2",
                 type: {:decimal, 128, 38, 37},
                 nullable: true,
                 metadata: nil,
                 data: [^d2]
               },
               %Adbc.Column{
                 name: "d3",
                 type: :f64,
                 nullable: true,
                 metadata: nil,
                 data: [1.234567891234568]
               },
               %Adbc.Column{
                 name: "d4",
                 type: :f64,
                 nullable: true,
                 metadata: nil,
                 data: [-1.234567891234568]
               },
               %Adbc.Column{
                 name: "d5",
                 type: {:decimal, 128, 38, 1},
                 nullable: true,
                 metadata: nil,
                 data: [^d5]
               },
               %Adbc.Column{
                 name: "d6",
                 type: {:decimal, 128, 38, 1},
                 nullable: true,
                 metadata: nil,
                 data: [^d6]
               },
               %Adbc.Column{
                 name: "d7",
                 type: {:decimal, 128, 38, 37},
                 nullable: true,
                 metadata: nil,
                 data: [^d7]
               }
             ]
           } = Adbc.Result.materialize(results)
  end

  @tag :unix
  test "arrays", %{conn: conn} do
    # Create a table with array column containing empty arrays
    {:ok, _} =
      Connection.query(conn, """
        CREATE TABLE test_arrays (
          number INTEGER,
          array_of_text TEXT[]
        )
      """)

    # # Insert data with empty arrays
    {:ok, _} =
      Connection.query(conn, """
        INSERT INTO test_arrays VALUES
        (1, LIST_VALUE()),
        (2, '["hello", "world"]'),
        (4, '["single"]')
      """)

    assert results =
             %Adbc.Result{
               num_rows: 0,
               data: [
                 %Adbc.Column{
                   name: "number",
                   type: :s32,
                   nullable: true,
                   metadata: nil
                 },
                 %Adbc.Column{
                   name: "array_of_text",
                   type:
                     {:list,
                      %Adbc.Column{
                        name: "item",
                        type: :string,
                        nullable: true,
                        metadata: nil
                      }},
                   nullable: true,
                   metadata: nil
                 }
               ]
             } = Connection.query!(conn, "SELECT * FROM test_arrays ORDER BY number")

    assert %Adbc.Result{
             data: [
               %Adbc.Column{
                 name: "number",
                 type: :s32,
                 nullable: true,
                 metadata: nil,
                 data: [1, 2, 4]
               },
               %Adbc.Column{
                 name: "array_of_text",
                 type: :list,
                 nullable: true,
                 metadata: nil,
                 data: [
                   %Adbc.Column{
                     name: "item",
                     type: :string,
                     nullable: true,
                     metadata: nil,
                     data: []
                   },
                   %Adbc.Column{
                     name: "item",
                     type: :string,
                     nullable: true,
                     metadata: nil,
                     data: ["hello", "world"]
                   },
                   %Adbc.Column{
                     name: "item",
                     type: :string,
                     nullable: true,
                     metadata: nil,
                     data: ["single"]
                   }
                 ]
               }
             ]
           } = Adbc.Result.materialize(results)
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
end

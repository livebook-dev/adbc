defmodule Adbc.ResultTest do
  use ExUnit.Case, async: true
  alias Adbc.Result

  # Just some imaginary data and context so it's easier to understand this test
  # measurements: [1, 2, 3, 4, 5, 6]
  # data points: [
  #   [1],    # 2024-05-31 12:00:00 - 2024-05-31 12:15:00
  #   [2, 3], # 2024-05-31 12:15:00 - 2024-05-31 12:30:00
  #   [3, 4], # 2024-05-31 12:30:00 - 2024-05-31 12:45:00
  #   [4],    # 2024-05-31 12:45:00 - 2024-05-31 13:00:00
  #   [5, 6], # 2024-05-31 13:00:00 - 2024-05-31 13:15:00
  #   [6]     # 2024-05-31 13:15:00 - 2024-05-31 13:30:00
  # ]
  defp result do
    %Adbc.Result{
      data: [
        %Adbc.Column{
          name: "start_time",
          type: {:timestamp, :seconds, "UTC"},
          nullable: true,
          metadata: nil,
          data: [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]]
        },
        %Adbc.Column{
          name: "end_time",
          type: {:timestamp, :seconds, "UTC"},
          nullable: true,
          metadata: nil,
          data: [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]]
        },
        %Adbc.Column{
          name: "time_series",
          type: :list,
          nullable: true,
          data: [
            %Adbc.Column{
              name: "item",
              type: :list_view,
              nullable: true,
              data: %{
                validity: [true, true, true, true],
                offsets: [0, 1, 2, 3],
                sizes: [1, 2, 2, 1],
                values: %Adbc.Column{
                  name: "variable_sliding_window",
                  type: :int32,
                  nullable: false,
                  data: [1, 2, 3, 4]
                }
              }
            },
            %Adbc.Column{
              name: "item",
              type: :list_view,
              nullable: true,
              data: %{
                validity: [true, true, true, true],
                offsets: [0, 1, 2, 3],
                sizes: [2, 1, 2, 1],
                values: %Adbc.Column{
                  name: "variable_sliding_window",
                  type: :int32,
                  nullable: false,
                  data: [3, 4, 5, 6]
                }
              }
            }
          ]
        }
      ]
    }
  end

  test "implements table reader" do
    assert result() |> Table.to_rows() |> Enum.to_list() == [
             %{
               "end_time" => ~N[2024-05-31 13:00:00],
               "start_time" => ~N[2024-05-31 12:00:00],
               "time_series" => [[1], [2, 3], [3, 4], [4]]
             },
             %{
               "end_time" => ~N[2024-05-31 13:30:00],
               "start_time" => ~N[2024-05-31 12:30:00],
               "time_series" => [[3, 4], [4], [5, 6], [6]]
             }
           ]
  end

  test "to_map with list views" do
    assert %{
             "start_time" => [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]],
             "end_time" => [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]],
             "time_series" => [[[1], [2, 3], [3, 4], [4]], [[3, 4], [4], [5, 6], [6]]]
           } == Result.to_map(result())
  end

  describe "from_py" do
    test "with invalid object" do
      assert_raise ArgumentError, fn ->
        {py_list, %{}} = Pythonx.eval("[]", %{})

        Result.from_py(py_list)
      end
    end

    test "with object implementing arrow stream" do
      {py_table, %{}} =
        Pythonx.eval(
          """
          import pyarrow
          n_legs = pyarrow.array([2, 4, 5, 100])
          animals = pyarrow.array(["Flamingo", "Horse", "Brittle stars", "Centipede"])
          names = ["n_legs", "animals"]
          pyarrow.Table.from_arrays([n_legs, animals], names=names)
          """,
          %{}
        )

      {:ok, result} = Result.from_py(py_table)

      assert %{
               "n_legs" => [2, 4, 5, 100],
               "animals" => ["Flamingo", "Horse", "Brittle stars", "Centipede"]
             } == Result.to_map(result)
    end

    # Note: an integration text for view types, since those types are
    # not emitted by duckdb/postgres, so we test it via Python.
    test "with utf8_view (vu) and binary_view (vz) columns" do
      {py_table, %{}} =
        Pythonx.eval(
          """
          import pyarrow
          # string_view: mix of short (<=12 bytes, stored inline) and long strings
          strings = pyarrow.array(["hi", None, "Brittle stars", "Centipede"], type=pyarrow.string_view())
          # binary_view: same layout, raw bytes
          blobs = pyarrow.array([b"ab", b"cd", None, b"a longer blob!!"], type=pyarrow.binary_view())
          pyarrow.Table.from_arrays([strings, blobs], names=["strings", "blobs"])
          """,
          %{}
        )

      {:ok, result} = Result.from_py(py_table)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{name: "strings", type: :string_view},
                 %Adbc.Column{name: "blobs", type: :binary_view}
               ]
             } = result

      assert %{
               "strings" => ["hi", nil, "Brittle stars", "Centipede"],
               "blobs" => ["ab", "cd", nil, "a longer blob!!"]
             } == Result.to_map(result)
    end
  end
end

defmodule Adbc.ResultTest do
  use ExUnit.Case, async: true
  alias Adbc.Result

  @invalid_data File.read!(Path.join(__DIR__, "invalid.arrows"))
  @valid_schema_only File.read!(Path.join(__DIR__, "schema-valid.arrows"))

  # File.write!("iris.ipc_stream", Explorer.DataFrame.dump_ipc_stream!(Explorer.Datasets.iris()))
  @iris_ipc_stream File.read!(Path.join(__DIR__, "iris/iris.ipc_stream"))

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
        [
          Adbc.Column.timestamp(
            [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]],
            :seconds,
            "UTC",
            name: "start_time"
          ),
          Adbc.Column.timestamp(
            [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]],
            :seconds,
            "UTC",
            name: "end_time"
          ),
          Adbc.Column.list(
            [Adbc.Column.s32([1, 2, 3, 4]), Adbc.Column.s32([3, 4, 5, 6])],
            Adbc.Field.new(:s32),
            name: "time_series"
          )
        ]
      ]
    }
  end

  test "implements table reader" do
    assert result() |> Table.to_rows() |> Enum.to_list() == [
             %{
               "end_time" => ~N[2024-05-31 13:00:00],
               "start_time" => ~N[2024-05-31 12:00:00],
               "time_series" => [1, 2, 3, 4]
             },
             %{
               "end_time" => ~N[2024-05-31 13:30:00],
               "start_time" => ~N[2024-05-31 12:30:00],
               "time_series" => [3, 4, 5, 6]
             }
           ]
  end

  test "to_columns" do
    assert %{
             "start_time" => [%Adbc.Column{field: %Adbc.Field{name: "start_time"}}],
             "end_time" => [%Adbc.Column{field: %Adbc.Field{name: "end_time"}}],
             "time_series" => [%Adbc.Column{field: %Adbc.Field{name: "time_series"}}]
           } = Result.to_columns(result())
  end

  test "to_map with list views" do
    assert %{
             "start_time" => [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]],
             "end_time" => [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]],
             "time_series" => [[1, 2, 3, 4], [3, 4, 5, 6]]
           } == Result.to_map(result())
  end

  describe "from_ipc_stream" do
    test "returns empty Adbc.Result when im-memory IPC contains only schema" do
      assert {:ok, %Adbc.Result{data: [], num_rows: nil}} =
               Result.from_ipc_stream(@valid_schema_only)
    end

    test "returns Adbc.Error when loading invalid in-memory ipc data" do
      assert {:error, error} = Result.from_ipc_stream(@invalid_data)

      if Adbc.ipc_endianness() == :little do
        assert Exception.message(error) ==
                 "Expected 0xFFFFFFFF at start of message but found 0xFFFFFF00"
      else
        assert Exception.message(error) ==
                 "Expected >= 16777219 bytes of remaining data but found 8 bytes in buffer"
      end
    end

    test "loads ipc stream from in-memory data" do
      assert {:ok,
              %Adbc.Result{
                num_rows: nil,
                data: [
                  [
                    %Adbc.Column{
                      field: %Adbc.Field{name: "sepal_length", type: :f64}
                    },
                    %Adbc.Column{
                      field: %Adbc.Field{name: "sepal_width", type: :f64}
                    },
                    %Adbc.Column{
                      field: %Adbc.Field{name: "petal_length", type: :f64}
                    },
                    %Adbc.Column{
                      field: %Adbc.Field{name: "petal_width", type: :f64}
                    },
                    %Adbc.Column{
                      field: %Adbc.Field{name: "species", type: :large_string}
                    }
                  ] = data
                ]
              }} = Result.from_ipc_stream(@iris_ipc_stream)

      for column <- data do
        expected =
          __DIR__
          |> Path.join("iris/#{column.field.name}.bin")
          |> File.read!()
          |> :erlang.binary_to_term()

        assert expected == Adbc.Column.to_list(column)
      end
    end
  end

  describe "to_ipc_stream" do
    test "dumps stream as in-memory IPC format data" do
      {:ok, stream} = Adbc.StreamResult.from_ipc_stream(@iris_ipc_stream)
      assert is_binary(Adbc.StreamResult.to_ipc_stream(stream))
    end

    test "raises when stream is consumed twice" do
      {:ok, stream} = Adbc.StreamResult.from_ipc_stream(@iris_ipc_stream)
      assert is_binary(Adbc.StreamResult.to_ipc_stream(stream))

      assert_raise ArgumentError, "stream has already been consumed", fn ->
        Adbc.StreamResult.to_ipc_stream(stream)
      end
    end
  end
end

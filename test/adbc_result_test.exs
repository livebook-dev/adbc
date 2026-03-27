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
        Adbc.Column.timestamp(
          [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]],
          :seconds,
          "UTC",
          name: "start_time",
          nullable: true
        ),
        Adbc.Column.timestamp(
          [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]],
          :seconds,
          "UTC",
          name: "end_time",
          nullable: true
        ),
        Adbc.Column.list(
          [Adbc.Column.s32([1, 2, 3, 4]), Adbc.Column.s32([3, 4, 5, 6])],
          Adbc.Field.new(:s32, nullable: true),
          name: "time_series", nullable: true
        )
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
              results = %Adbc.Result{
                num_rows: nil,
                data: [
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "sepal_length",
                      type: :f64,
                      metadata: nil,
                      nullable: true
                    }
                  },
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "sepal_width",
                      type: :f64,
                      metadata: nil,
                      nullable: true
                    }
                  },
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "petal_length",
                      type: :f64,
                      metadata: nil,
                      nullable: true
                    }
                  },
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "petal_width",
                      type: :f64,
                      metadata: nil,
                      nullable: true
                    }
                  },
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "species",
                      type: :large_string,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ]
              }} = Result.from_ipc_stream(@iris_ipc_stream)

      assert %Adbc.Result{
               num_rows: nil,
               data:
                 [
                   %Adbc.Column{
                     field: %Adbc.Field{name: "sepal_length", type: :f64, nullable: true}
                   },
                   %Adbc.Column{
                     field: %Adbc.Field{name: "sepal_width", type: :f64, nullable: true}
                   },
                   %Adbc.Column{
                     field: %Adbc.Field{name: "petal_length", type: :f64, nullable: true}
                   },
                   %Adbc.Column{
                     field: %Adbc.Field{name: "petal_width", type: :f64, nullable: true}
                   },
                   %Adbc.Column{
                     field: %Adbc.Field{name: "species", type: :large_string, nullable: true}
                   }
                 ] = data
             } = Adbc.Result.materialize(results)

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
    test "dumps columns as in-memory IPC format data" do
      result = %Adbc.Result{
        data: [Adbc.Column.s64([1, 2, 3]), Adbc.Column.f32([1.1, 2.2, 3.3])],
        num_rows: 3
      }

      assert is_binary(Result.to_ipc_stream(result))
    end
  end

  describe "columns_to_arrow_array_stream" do
    test "stream yields one batch then ends" do
      columns = [Adbc.Column.s64([10, 20, 30], name: "x")]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)

      # First call returns a list of columns (one struct batch)
      assert {:ok, [%Adbc.Column{field: %Adbc.Field{name: "x"}}]} =
               Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)

      # Second call signals end of stream
      assert :end_of_series = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)

      # Third call also signals end (idempotent)
      assert :end_of_series = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)
    end

    test "stream data round-trips through IPC" do
      columns = [
        Adbc.Column.s32([1, nil, 3], name: "ints", nullable: true),
        Adbc.Column.string(["a", "b", nil], name: "strs", nullable: true),
        Adbc.Column.boolean([true, nil, false], name: "bools", nullable: true)
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)
      {:ok, ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      {:ok, result} = Result.from_ipc_stream(ipc)
      map = Result.to_map(Result.materialize(result))

      assert map["ints"] == [1, nil, 3]
      assert map["strs"] == ["a", "b", nil]
      assert map["bools"] == [true, nil, false]
    end

    test "stream with nested list columns produces valid IPC" do
      columns = [
        Adbc.Column.list(
          [Adbc.Column.s32([1, 2, 3]), Adbc.Column.s32([4, 5])],
          Adbc.Field.new(:s32),
          name: "lists",
          nullable: true
        )
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)
      {:ok, ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      {:ok, result} = Result.from_ipc_stream(ipc)
      result = Result.materialize(result)
      assert Adbc.Column.to_list(hd(result.data)) == [[1, 2, 3], [4, 5]]
    end

    test "rejects unmaterialized columns" do
      bad_columns = [%Adbc.Column{field: %Adbc.Field{name: "x", type: :s64}, data: make_ref()}]

      assert {:error, msg} = Adbc.Nif.adbc_columns_to_arrow_array_stream(bad_columns)
      assert msg =~ "materialize"
    end

    test "rejects non-list argument" do
      assert_raise ArgumentError, fn ->
        Adbc.Nif.adbc_columns_to_arrow_array_stream("not a list")
      end
    end

    test "multiple typed columns through IPC round-trip" do
      columns = [
        Adbc.Column.s64([100, 200], name: "id"),
        Adbc.Column.string(["Alice", "Bob"], name: "name", nullable: true),
        Adbc.Column.boolean([true, false], name: "active", nullable: true)
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)
      {:ok, ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      {:ok, result} = Result.from_ipc_stream(ipc)
      map = Result.to_map(Result.materialize(result))

      assert map["id"] == [100, 200]
      assert map["name"] == ["Alice", "Bob"]
      assert map["active"] == [true, false]
    end

    test "timestamp columns through IPC round-trip" do
      columns = [
        Adbc.Column.timestamp(
          [~N[2024-01-01 00:00:00], ~N[2024-06-15 12:30:00]],
          :seconds,
          "UTC",
          name: "ts",
          nullable: true
        )
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)
      {:ok, ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      {:ok, result} = Result.from_ipc_stream(ipc)
      map = Result.to_map(Result.materialize(result))

      assert map["ts"] == [~N[2024-01-01 00:00:00], ~N[2024-06-15 12:30:00]]
    end

    test "dictionary columns can be created as stream" do
      columns = [
        Adbc.Column.dictionary(
          Adbc.Column.s32([0, 1, 0, 2], nullable: true),
          Adbc.Column.string(["foo", "bar", "baz"]),
          name: "dict",
          nullable: true
        )
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)

      # Stream yields one batch with the dictionary column
      assert {:ok, batch} = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)
      assert [%Adbc.Column{field: %Adbc.Field{type: {:dictionary, _, _}}}] = batch

      assert :end_of_series = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)
    end

    test "empty column list produces a valid stream" do
      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream([])
      # Empty columns produce a single empty batch, then end
      assert {:ok, []} = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)
      assert :end_of_series = Adbc.Nif.adbc_arrow_array_stream_next(stream_ref)
    end
  end

  describe "StreamResult.to_ipc_stream" do
    test "rejects already-released stream" do
      columns = [Adbc.Column.s64([1], name: "x")]
      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)

      # Consume the stream
      {:ok, _ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)

      # Second consumption should still work (stream is drained but valid)
      # — it produces a schema-only IPC (empty table)
      {:ok, ipc2} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      assert is_binary(ipc2)
    end

    test "multi-column IPC round-trip preserves all data" do
      columns = [
        Adbc.Column.s64([10, 20, 30], name: "id"),
        Adbc.Column.string(["a", "b", "c"], name: "label"),
        Adbc.Column.f64([1.1, 2.2, 3.3], name: "score")
      ]

      {:ok, stream_ref} = Adbc.Nif.adbc_columns_to_arrow_array_stream(columns)
      {:ok, ipc} = Adbc.Nif.adbc_arrow_array_stream_to_ipc(stream_ref)
      {:ok, result} = Result.from_ipc_stream(ipc)
      map = Result.to_map(Result.materialize(result))

      assert map["id"] == [10, 20, 30]
      assert map["label"] == ["a", "b", "c"]

      for {actual, expected} <- Enum.zip(map["score"], [1.1, 2.2, 3.3]) do
        assert_in_delta actual, expected, 1.0e-9
      end
    end
  end
end

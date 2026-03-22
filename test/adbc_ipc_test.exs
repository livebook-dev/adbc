defmodule Adbc.IPC.Test do
  use ExUnit.Case

  alias Adbc.IPC

  @invalid_data File.read!(Path.join(__DIR__, "invalid.arrows"))
  @valid_schema_only File.read!(Path.join(__DIR__, "schema-valid.arrows"))

  # File.write!("iris.ipc_stream", Explorer.DataFrame.dump_ipc_stream!(Explorer.Datasets.iris()))
  @iris_ipc_stream File.read!(Path.join(__DIR__, "iris/iris.ipc_stream"))

  describe "load" do
    test "it returns empty Adbc.Result when im-memory IPC contains only schema" do
      assert {:ok, %Adbc.Result{data: [], num_rows: nil}} = IPC.load_stream(@valid_schema_only)
    end

    test "it returns Adbc.Error when loading invalid in-memory ipc data" do
      assert {:error, error} = IPC.load_stream(@invalid_data)

      if IPC.endianness() == :little do
        assert Exception.message(error) ==
                 "Expected 0xFFFFFFFF at start of message but found 0xFFFFFF00"
      else
        assert Exception.message(error) ==
                 "Expected >= 16777219 bytes of remaining data but found 8 bytes in buffer"
      end
    end

    test "it can load ipc stream from in-memory data" do
      assert {:ok,
              results = %Adbc.Result{
                num_rows: nil,
                data: [
                  %Adbc.Column{field: %Adbc.Field{name: "sepal_length", type: :f64, metadata: nil, nullable: true}},
                  %Adbc.Column{field: %Adbc.Field{name: "sepal_width", type: :f64, metadata: nil, nullable: true}},
                  %Adbc.Column{field: %Adbc.Field{name: "petal_length", type: :f64, metadata: nil, nullable: true}},
                  %Adbc.Column{field: %Adbc.Field{name: "petal_width", type: :f64, metadata: nil, nullable: true}},
                  %Adbc.Column{
                    field: %Adbc.Field{
                      name: "species",
                      type: :large_string,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ]
              }} = IPC.load_stream(@iris_ipc_stream)

      assert %Adbc.Result{
               num_rows: nil,
               data:
                 [
                   %Adbc.Column{field: %Adbc.Field{name: "sepal_length", type: :f64, metadata: nil, nullable: true}},
                   %Adbc.Column{field: %Adbc.Field{name: "sepal_width", type: :f64, metadata: nil, nullable: true}},
                   %Adbc.Column{field: %Adbc.Field{name: "petal_length", type: :f64, metadata: nil, nullable: true}},
                   %Adbc.Column{field: %Adbc.Field{name: "petal_width", type: :f64, metadata: nil, nullable: true}},
                   %Adbc.Column{
                     field: %Adbc.Field{
                       name: "species",
                       type: :large_string,
                       metadata: nil,
                       nullable: true
                     }
                   }
                 ] = data
             } = Adbc.Result.materialize(results)

      for column <- data do
        expected =
          __DIR__
          |> Path.join("iris/#{column.field.name}.bin")
          |> File.read!()
          |> :erlang.binary_to_term()

        assert expected == column.data
      end
    end
  end

  describe "dump" do
    test "it can dump columns as in-memory IPC format data" do
      assert {:ok, _data} =
               IPC.dump_stream([Adbc.Column.s64([1, 2, 3]), Adbc.Column.f32([1.1, 2.2, 3.3])])
    end
  end
end

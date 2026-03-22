defmodule Adbc.PythonxTest do
  use ExUnit.Case, async: true
  alias Adbc.Result

  defp eval!(code) do
    {py_table, %{}} = Pythonx.eval(code, %{})
    {:ok, result} = Result.from_py(py_table)
    Result.materialize(result)
  end

  describe "from_py" do
    test "with invalid object" do
      assert_raise ArgumentError, fn ->
        {py_list, %{}} = Pythonx.eval("[]", %{})
        Result.from_py!(py_list)
      end
    end

    test "with simple columns" do
      result =
        eval!("""
        import pyarrow
        n_legs = pyarrow.array([2, 4, 5, 100])
        animals = pyarrow.array(["Flamingo", "Horse", "Brittle stars", "Centipede"])
        names = ["n_legs", "animals"]
        pyarrow.Table.from_arrays([n_legs, animals], names=names)
        """)

      assert %{
               "n_legs" => [2, 4, 5, 100],
               "animals" => ["Flamingo", "Horse", "Brittle stars", "Centipede"]
             } == Result.to_map(result)
    end
  end

  describe "string_view and binary_view" do
    test "materializes utf8_view and binary_view columns" do
      result =
        eval!("""
        import pyarrow
        strings = pyarrow.array(["hi", None, "Brittle stars", "Centipede"], type=pyarrow.string_view())
        blobs = pyarrow.array([b"ab", b"cd", None, b"a longer blob!!"], type=pyarrow.binary_view())
        pyarrow.Table.from_arrays([strings, blobs], names=["strings", "blobs"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{field: %{name: "strings", type: :string_view}},
                 %Adbc.Column{field: %{name: "blobs", type: :binary_view}}
               ]
             } = result

      assert %{
               "strings" => ["hi", nil, "Brittle stars", "Centipede"],
               "blobs" => ["ab", "cd", nil, "a longer blob!!"]
             } == Result.to_map(result)
    end
  end

  describe "list" do
    test "materializes list column" do
      result =
        eval!("""
        import pyarrow
        data = pyarrow.array([[1, 2, 3], [4, 5], None, [6]], type=pyarrow.list_(pyarrow.int32()))
        pyarrow.Table.from_arrays([data], names=["lists"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "lists",
                     type: {:list, %Adbc.Field{name: "item", type: :s32}}
                   },
                   data: data
                 }
               ]
             } = result

      assert data == [[1, 2, 3], [4, 5], nil, [6]]
    end
  end

  describe "dictionary" do
    test "materializes dictionary column" do
      result =
        eval!("""
        import pyarrow
        indices = pyarrow.array([0, 1, 0, 2, 1])
        dictionary = pyarrow.array(["foo", "bar", "baz"])
        data = pyarrow.DictionaryArray.from_arrays(indices, dictionary)
        pyarrow.Table.from_arrays([data], names=["dict"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "dict",
                     type: {:dictionary, %Adbc.Field{type: key_type}, %Adbc.Field{type: :string}}
                   },
                   data: %{key: key_data, value: value_data}
                 }
               ]
             } = result

      assert key_type in [:s8, :s16, :s32, :s64]
      assert key_data == [0, 1, 0, 2, 1]
      assert value_data == ["foo", "bar", "baz"]

      assert Adbc.Column.to_list(hd(result.data)) == ["foo", "bar", "foo", "baz", "bar"]
    end

    test "materializes dictionary with nulls" do
      result =
        eval!("""
        import pyarrow
        indices = pyarrow.array([0, None, 1, 2, None])
        dictionary = pyarrow.array(["foo", "bar", "baz"])
        data = pyarrow.DictionaryArray.from_arrays(indices, dictionary)
        pyarrow.Table.from_arrays([data], names=["dict"])
        """)

      assert Adbc.Column.to_list(hd(result.data)) == ["foo", nil, "bar", "baz", nil]
    end
  end

  describe "struct" do
    test "materializes struct column" do
      result =
        eval!("""
        import pyarrow
        data = pyarrow.array(
          [{"x": 1, "y": "a"}, {"x": 2, "y": "b"}, None],
          type=pyarrow.struct([("x", pyarrow.int32()), ("y", pyarrow.string())])
        )
        pyarrow.Table.from_arrays([data], names=["structs"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "structs",
                     type:
                       {:struct,
                        [
                          %Adbc.Field{name: "x", type: :s32},
                          %Adbc.Field{name: "y", type: :string}
                        ]}
                   }
                 }
               ]
             } = result

      # Note: pyarrow represents null structs as structs with all-null fields,
      # but integer fields get 0 instead of nil when the struct row is null
      assert Adbc.Column.to_list(hd(result.data)) == [
               %{"x" => 1, "y" => "a"},
               %{"x" => 2, "y" => "b"},
               %{"x" => 0, "y" => nil}
             ]
    end
  end

  describe "run_end_encoded" do
    test "materializes run-end encoded column" do
      result =
        eval!("""
        import pyarrow
        data = pyarrow.RunEndEncodedArray.from_arrays(
          pyarrow.array([3, 5, 7], type=pyarrow.int32()),
          pyarrow.array(["a", "b", "c"])
        )
        pyarrow.Table.from_arrays([data], names=["ree"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "ree",
                     type:
                       {:run_end_encoded, %Adbc.Field{name: "run_ends", type: :s32},
                        %Adbc.Field{name: "values", type: :string}}
                   },
                   data: %{run_ends: run_ends, values: values, length: length, offset: offset}
                 }
               ]
             } = result

      assert run_ends == [3, 5, 7]
      assert values == ["a", "b", "c"]
      assert length == 7
      assert offset == 0

      assert Adbc.Column.to_list(hd(result.data)) == ["a", "a", "a", "b", "b", "c", "c"]
    end
  end

  describe "list_view" do
    test "materializes list_view column" do
      result =
        eval!("""
        import pyarrow
        values = pyarrow.array([10, 20, 30, 40, 50], type=pyarrow.int32())
        offsets = pyarrow.array([0, 2, 1], type=pyarrow.int32())
        sizes = pyarrow.array([2, 3, 2], type=pyarrow.int32())
        lv_type = pyarrow.list_view(pyarrow.field("item", pyarrow.int32(), nullable=False))
        data = pyarrow.ListViewArray.from_arrays(offsets, sizes, values, type=lv_type)
        pyarrow.Table.from_arrays([data], names=["lv"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "lv",
                     type: {:list_view, %Adbc.Field{name: "item", type: :s32}}
                   },
                   data: %{
                     validity: validity,
                     offsets: offsets,
                     sizes: sizes,
                     values: values
                   }
                 }
               ]
             } = result

      assert is_list(validity)
      assert offsets == [0, 2, 1]
      assert sizes == [2, 3, 2]
      assert values == [10, 20, 30, 40, 50]

      assert Adbc.Column.to_list(hd(result.data)) == [[10, 20], [30, 40, 50], [20, 30]]
    end
  end
end

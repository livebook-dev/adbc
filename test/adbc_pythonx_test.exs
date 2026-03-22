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
                   }
                 } = col
               ]
             } = result

      assert Adbc.Column.to_list(col) == [[1, 2, 3], [4, 5], nil, [6]]
    end

    test "materializes large list column" do
      result =
        eval!("""
        import pyarrow
        data = pyarrow.array([[1, 2], None, [3, 4, 5]], type=pyarrow.large_list(pyarrow.int32()))
        pyarrow.Table.from_arrays([data], names=["lists"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "lists",
                     type: {:large_list, %Adbc.Field{name: "item", type: :s32}}
                   }
                 } = col
               ]
             } = result

      assert Adbc.Column.to_list(col) == [[1, 2], nil, [3, 4, 5]]
    end

    test "materializes fixed size list column" do
      result =
        eval!("""
        import pyarrow
        data = pyarrow.array([[1, 2, 3], [4, 5, 6], None, [7, 8, 9]], type=pyarrow.list_(pyarrow.int32(), 3))
        pyarrow.Table.from_arrays([data], names=["lists"])
        """)

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %Adbc.Field{
                     name: "lists",
                     type: {:fixed_size_list, %Adbc.Field{name: "item", type: :s32}, 3}
                   }
                 } = col
               ]
             } = result

      assert Adbc.Column.to_list(col) == [[1, 2, 3], [4, 5, 6], nil, [7, 8, 9]]
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
                   }
                 }
               ]
             } = result

      assert key_type in [:s8, :s16, :s32, :s64]
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

    test "materializes dictionary with struct values" do
      result =
        eval!("""
        import pyarrow
        struct_type = pyarrow.struct([
          pyarrow.field("x", pyarrow.int32()),
          pyarrow.field("y", pyarrow.utf8())
        ])
        dictionary = pyarrow.array([
          {"x": 1, "y": "a"},
          {"x": 2, "y": "b"},
          {"x": 3, "y": "c"}
        ], type=struct_type)
        indices = pyarrow.array([0, 2, 1, 0])
        data = pyarrow.DictionaryArray.from_arrays(indices, dictionary)
        pyarrow.Table.from_arrays([data], names=["dict"])
        """)

      assert Adbc.Column.to_list(hd(result.data)) == [
               %{"x" => 1, "y" => "a"},
               %{"x" => 3, "y" => "c"},
               %{"x" => 2, "y" => "b"},
               %{"x" => 1, "y" => "a"}
             ]
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
                   data: [%{offset: 0, length: 7, values: ["a", "b", "c"], run_ends: [3, 5, 7]}]
                 }
               ]
             } = result

      assert Adbc.Column.to_list(hd(result.data)) == ["a", "a", "a", "b", "b", "c", "c"]
    end

    test "materializes run-end encoded column with dictionary values" do
      result =
        eval!("""
        import pyarrow
        dict_type = pyarrow.dictionary(pyarrow.int32(), pyarrow.utf8())
        data = pyarrow.RunEndEncodedArray.from_arrays(
          pyarrow.array([3, 5, 7], type=pyarrow.int32()),
          pyarrow.array(["foo", "bar", "baz"], type=dict_type)
        )
        pyarrow.Table.from_arrays([data], names=["ree"])
        """)

      assert Adbc.Column.to_list(hd(result.data)) ==
               ["foo", "foo", "foo", "bar", "bar", "baz", "baz"]
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
                   data: [
                     %{
                       values: [10, 20, 30, 40, 50],
                       offsets: [0, 2, 1],
                       sizes: [2, 3, 2],
                       validity: [true, true, true]
                     }
                   ]
                 }
               ]
             } = result

      assert Adbc.Column.to_list(hd(result.data)) == [[10, 20], [30, 40, 50], [20, 30]]
    end

    test "materializes list_view column with dictionary inner type" do
      result =
        eval!("""
        import pyarrow
        dict_type = pyarrow.dictionary(pyarrow.int32(), pyarrow.utf8())
        values = pyarrow.array(["foo", "bar", "baz", "foo", "bar"], type=dict_type)
        offsets = pyarrow.array([0, 2, 1], type=pyarrow.int32())
        sizes = pyarrow.array([2, 3, 2], type=pyarrow.int32())
        lv_type = pyarrow.list_view(pyarrow.field("item", dict_type, nullable=False))
        data = pyarrow.ListViewArray.from_arrays(offsets, sizes, values, type=lv_type)
        pyarrow.Table.from_arrays([data], names=["lv"])
        """)

      assert Adbc.Column.to_list(hd(result.data)) ==
               [["foo", "bar"], ["baz", "foo", "bar"], ["bar", "baz"]]
    end
  end
end

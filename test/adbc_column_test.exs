defmodule Adbc.ColumnTest do
  use ExUnit.Case, async: true
  doctest Adbc.Column

  defp to_decimals(data) do
    Enum.map(data, fn
      nil -> nil
      n -> Decimal.new(n)
    end)
  end

  describe "new/2" do
    test "empty list defaults to string" do
      col = Adbc.Column.new([])
      assert col.field.type == :string
      assert Adbc.Column.to_list(col) == []
    end

    test "booleans" do
      col = Adbc.Column.new([true, false, true])
      assert col.field.type == :boolean
      assert Adbc.Column.to_list(col) == [true, false, true]
    end

    test "integers infer as s64" do
      col = Adbc.Column.new([1, 2, 3])
      assert col.field.type == :s64
    end

    test "floats infer as f64" do
      col = Adbc.Column.new([1.0, 2.5, 3.0])
      assert col.field.type == :f64
    end

    test "integers promoted to f64 when mixed with floats" do
      col = Adbc.Column.new([1, 2.5, 3])
      assert col.field.type == :f64
      assert Adbc.Column.to_list(col) == [1.0, 2.5, 3.0]
    end

    test "nan, infinity, neg_infinity infer as f64" do
      col = Adbc.Column.new([:nan, :infinity, :neg_infinity])
      assert col.field.type == :f64
    end

    test "integers promoted to f64 when mixed with nan" do
      col = Adbc.Column.new([1, :nan, 3])
      assert col.field.type == :f64
    end

    test "nil sets nullable" do
      col = Adbc.Column.new([1, nil, 3])
      assert col.field.type == :s64
      assert Adbc.Column.to_list(col) == [1, nil, 3]
    end

    test "only nils defaults to string" do
      col = Adbc.Column.new([nil, nil])
      assert col.field.type == :string
    end

    test "strings" do
      col = Adbc.Column.new(["hello", "world"])
      assert col.field.type == :string
    end

    test "dates infer as date32" do
      col = Adbc.Column.new([~D[2024-01-01], ~D[2024-12-31]])
      assert col.field.type == :date32
    end

    test "dates mixed with integers" do
      col = Adbc.Column.new([100, ~D[2024-01-01], nil])
      assert col.field.type == :date32
    end

    test "times infer as time64 microseconds" do
      col = Adbc.Column.new([~T[12:00:00], ~T[13:30:00]])
      assert col.field.type == {:time64, :microseconds}
    end

    test "times mixed with integers" do
      col = Adbc.Column.new([1000, ~T[12:00:00]])
      assert col.field.type == {:time64, :microseconds}
    end

    test "naive datetimes infer as timestamp microseconds UTC" do
      col = Adbc.Column.new([~N[2024-01-01 12:00:00], ~N[2024-12-31 23:59:59]])
      assert col.field.type == {:timestamp, :microseconds, "UTC"}
    end

    test "naive datetimes mixed with integers" do
      col = Adbc.Column.new([1000, ~N[2024-01-01 12:00:00], nil])
      assert col.field.type == {:timestamp, :microseconds, "UTC"}
    end

    test "accepts name option" do
      col = Adbc.Column.new([1, 2, 3], name: "my_col")
      assert col.field.name == "my_col"
    end

    test "raises on mixed incompatible types" do
      assert_raise ArgumentError, ~r/mixed types/, fn ->
        Adbc.Column.new([true, 1])
      end

      assert_raise ArgumentError, ~r/mixed types/, fn ->
        Adbc.Column.new(["hello", 1])
      end

      assert_raise ArgumentError, ~r/mixed types/, fn ->
        Adbc.Column.new([~D[2024-01-01], 1.0])
      end

      assert_raise ArgumentError, ~r/mixed types/, fn ->
        Adbc.Column.new([true, "hello"])
      end
    end

    test "raises on unsupported values" do
      assert_raise ArgumentError, ~r"cannot infer type for value in column", fn ->
        Adbc.Column.new([{:tuple, 1}])
      end
    end

    test "unsupported types raise" do
      assert_raise ArgumentError, ~r"cannot infer type", fn ->
        Adbc.Column.new([Decimal.new("1.23")])
      end

      assert_raise ArgumentError, ~r"cannot infer type", fn ->
        Adbc.Column.new([[1, 2]])
      end
    end
  end

  describe "fixed_size_binary" do
    test "round-trips non-nullable" do
      col = Adbc.Column.fixed_size_binary([<<1, 2>>, <<3, 4>>, <<5, 6>>], 2)
      assert col.field.type == {:fixed_size_binary, 2}
      assert Adbc.Column.to_list(col) == [<<1, 2>>, <<3, 4>>, <<5, 6>>]
    end

    test "round-trips nullable" do
      col = Adbc.Column.fixed_size_binary([<<1, 2>>, nil, <<5, 6>>], 2)
      assert col.field.type == {:fixed_size_binary, 2}
      assert Adbc.Column.to_list(col) == [<<1, 2>>, nil, <<5, 6>>]
    end

    test "single byte elements" do
      col = Adbc.Column.fixed_size_binary([<<0xFF>>, <<0x00>>, <<0xAB>>], 1)
      assert Adbc.Column.to_list(col) == [<<0xFF>>, <<0x00>>, <<0xAB>>]
    end
  end

  describe "decimals" do
    test "integers" do
      value = 42
      precision = 19
      scale = 10
      decimal = Decimal.new(value)

      col = Adbc.Column.decimal128([decimal, value], precision, scale)
      assert col.field.type == {:decimal128, precision, scale}

      [d1, d2] = Adbc.Column.to_list(col)
      assert Decimal.equal?(d1, Decimal.new(1, value * Integer.pow(10, scale), -scale))
      assert Decimal.equal?(d2, Decimal.new(1, value * Integer.pow(10, scale), -scale))

      col = Adbc.Column.decimal256([decimal, value], precision, scale)
      assert col.field.type == {:decimal256, precision, scale}

      [d1, d2] = Adbc.Column.to_list(col)
      assert Decimal.equal?(d1, Decimal.new(1, value * Integer.pow(10, scale), -scale))
      assert Decimal.equal?(d2, Decimal.new(1, value * Integer.pow(10, scale), -scale))
    end

    test "floats" do
      value = 12345
      precision = 5
      scale = 10
      exp = -3
      actual_value = value * :math.pow(10, exp)
      decimal = Decimal.new(1, value, exp)

      col = Adbc.Column.decimal128([decimal], precision, scale)
      [d] = Adbc.Column.to_list(col)
      assert actual_value == Decimal.to_float(d)

      col = Adbc.Column.decimal256([decimal], precision, scale)
      [d] = Adbc.Column.to_list(col)
      assert actual_value == Decimal.to_float(d)
    end

    test "nils at various positions for decimal128" do
      precision = 19
      scale = 0

      # nil at position 1 (within a group of 8)
      data = [1, nil, 3, 4, 5, 6, 7, 8]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # nil at last position of a group of 8
      data = [1, 2, 3, 4, 5, 6, 7, nil]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # all nils in a group of 8
      data = [nil, nil, nil, nil, nil, nil, nil, nil]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # nil crossing the 8-element boundary
      data = [1, 2, 3, 4, 5, 6, 7, 8, nil, 10]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # multiple nils across boundary
      data = [nil, 2, 3, 4, 5, 6, 7, nil, nil, 10, 11, 12, 13, 14, 15, nil]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # partial group (less than 8) with nil
      data = [1, nil, 3]
      col = Adbc.Column.decimal128(data, precision, scale)
      assert Adbc.Column.to_list(col) == to_decimals(data)
    end

    test "raise if precision value is insufficient" do
      value = 54321
      precision = 4
      scale = 1
      decimal = Decimal.new(value)

      assert_raise ArgumentError,
                   "`54321` cannot be fitted into a decimal128 with the specified precision 4",
                   fn ->
                     Adbc.Column.decimal128([decimal], precision, scale)
                   end

      assert_raise ArgumentError,
                   "`54321` cannot be fitted into a decimal128 with the specified precision 4",
                   fn ->
                     Adbc.Column.decimal128([value], precision, scale)
                   end

      assert_raise ArgumentError,
                   "`54321` cannot be fitted into a decimal256 with the specified precision 4",
                   fn ->
                     Adbc.Column.decimal256([decimal], precision, scale)
                   end

      assert_raise ArgumentError,
                   "`54321` cannot be fitted into a decimal256 with the specified precision 4",
                   fn ->
                     Adbc.Column.decimal256([value], precision, scale)
                   end

      precision = 5

      col = Adbc.Column.decimal128([decimal, value], precision, scale)
      assert length(Adbc.Column.to_list(col)) == 2

      col = Adbc.Column.decimal256([decimal, value], precision, scale)
      assert length(Adbc.Column.to_list(col)) == 2
    end

    test "raise if scale value is insufficient" do
      value = 54321
      precision = 5
      scale = 1

      exp = -2
      decimal = Decimal.new(1, value, exp)

      assert_raise ArgumentError,
                   "`543.21` with exponent `-2` cannot be represented as a valid decimal128 number with scale value `1`",
                   fn ->
                     Adbc.Column.decimal128([decimal], precision, scale)
                   end

      assert_raise ArgumentError,
                   "`543.21` with exponent `-2` cannot be represented as a valid decimal256 number with scale value `1`",
                   fn ->
                     Adbc.Column.decimal256([decimal], precision, scale)
                   end

      scale = 2

      col = Adbc.Column.decimal128([decimal], precision, scale)
      assert length(Adbc.Column.to_list(col)) == 1

      col = Adbc.Column.decimal256([decimal], precision, scale)
      assert length(Adbc.Column.to_list(col)) == 1
    end

    test "raise on Inf, -Inf and NaN" do
      assert_raise ArgumentError,
                   "`Infinity` cannot be represented as a valid decimal128 number",
                   fn ->
                     Adbc.Column.decimal128([Decimal.new("inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`Infinity` cannot be represented as a valid decimal128 number",
                   fn ->
                     Adbc.Column.decimal128([Decimal.new("1"), Decimal.new("inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`-Infinity` cannot be represented as a valid decimal128 number",
                   fn ->
                     Adbc.Column.decimal128([Decimal.new("-inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`-Infinity` cannot be represented as a valid decimal128 number",
                   fn ->
                     Adbc.Column.decimal128([Decimal.new("1"), Decimal.new("-inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`NaN` cannot be represented as a valid decimal128 number",
                   fn ->
                     Adbc.Column.decimal128([Decimal.new("NaN")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`Infinity` cannot be represented as a valid decimal256 number",
                   fn ->
                     Adbc.Column.decimal256([Decimal.new("inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`Infinity` cannot be represented as a valid decimal256 number",
                   fn ->
                     Adbc.Column.decimal256([Decimal.new("1"), Decimal.new("inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`-Infinity` cannot be represented as a valid decimal256 number",
                   fn ->
                     Adbc.Column.decimal256([Decimal.new("-inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`-Infinity` cannot be represented as a valid decimal256 number",
                   fn ->
                     Adbc.Column.decimal256([Decimal.new("1"), Decimal.new("-inf")], 19, 10)
                   end

      assert_raise ArgumentError,
                   "`NaN` cannot be represented as a valid decimal256 number",
                   fn ->
                     Adbc.Column.decimal256([Decimal.new("NaN")], 19, 10)
                   end
    end
  end

  describe "has_validity?/1" do
    test "integer column" do
      refute Adbc.Column.has_validity?(Adbc.Column.s32([1, 2, 3]))
      assert Adbc.Column.has_validity?(Adbc.Column.s32([1, nil, 3]))
    end

    test "string column" do
      refute Adbc.Column.has_validity?(Adbc.Column.string(["a", "b"]))
      assert Adbc.Column.has_validity?(Adbc.Column.string(["a", nil, "b"]))
    end

    test "list column" do
      refute Adbc.Column.has_validity?(
               Adbc.Column.list([Adbc.Column.s32([1, 2])], Adbc.Field.new(:s32))
             )

      assert Adbc.Column.has_validity?(
               Adbc.Column.list([Adbc.Column.s32([1, 2]), nil], Adbc.Field.new(:s32))
             )
    end

    test "dictionary column" do
      refute Adbc.Column.has_validity?(
               Adbc.Column.dictionary(Adbc.Column.s32([0, 1]), Adbc.Column.string(["a", "b"]))
             )

      assert Adbc.Column.has_validity?(
               Adbc.Column.dictionary(
                 Adbc.Column.s32([0, nil, 1]),
                 Adbc.Column.string(["a", "b"])
               )
             )

      assert Adbc.Column.has_validity?(
               Adbc.Column.dictionary(
                 Adbc.Column.s32([0, 1]),
                 Adbc.Column.string(["a", nil])
               )
             )
    end

    test "raises for unmaterialized column" do
      assert_raise ArgumentError, "column has not been materialized", fn ->
        {:ok, result} =
          Adbc.Result.from_ipc_stream(File.read!(Path.join("test", "iris/iris.ipc_stream")))

        [col | _] = hd(result.data)
        Adbc.Column.has_validity?(col)
      end
    end
  end

  describe "to_binary/1" do
    test "integer column" do
      assert Adbc.Column.to_binary(Adbc.Column.s32([1, 2, 3])) ==
               <<1::signed-little-32, 2::signed-little-32, 3::signed-little-32>>
    end

    test "float column" do
      assert Adbc.Column.to_binary(Adbc.Column.f64([1.0, 2.0])) ==
               <<1.0::float-little-64, 2.0::float-little-64>>
    end

    test "dictionary column returns key binary" do
      assert Adbc.Column.to_binary(
               Adbc.Column.dictionary(Adbc.Column.s32([0, 1, 0]), Adbc.Column.string(["a", "b"]))
             ) == <<0::signed-little-32, 1::signed-little-32, 0::signed-little-32>>
    end

    test "raises for boolean column" do
      assert_raise ArgumentError, ~r/cannot convert/, fn ->
        Adbc.Column.to_binary(Adbc.Column.boolean([true, false]))
      end
    end

    test "raises for string column" do
      assert_raise ArgumentError, ~r/cannot convert/, fn ->
        Adbc.Column.to_binary(Adbc.Column.string(["a", "b"]))
      end
    end

    test "raises for unmaterialized column" do
      assert_raise ArgumentError, "column has not been materialized", fn ->
        {:ok, result} =
          Adbc.Result.from_ipc_stream(File.read!(Path.join("test", "iris/iris.ipc_stream")))

        [col | _] = hd(result.data)
        Adbc.Column.to_binary(col)
      end
    end
  end
end

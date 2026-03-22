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
      assert %Adbc.Column{field: %{type: :string, nullable: false}, data: [[]]} =
               Adbc.Column.new([])
    end

    test "booleans" do
      col = Adbc.Column.new([true, false, true])
      assert col.field.type == :boolean
      assert col.field.nullable == false
      assert col.data == [[true, false, true]]
    end

    test "integers infer as s64" do
      col = Adbc.Column.new([1, 2, 3])
      assert col.field.type == :s64
      assert col.field.nullable == false
    end

    test "floats infer as f64" do
      col = Adbc.Column.new([1.0, 2.5, 3.0])
      assert col.field.type == :f64
      assert col.field.nullable == false
    end

    test "integers promoted to f64 when mixed with floats" do
      col = Adbc.Column.new([1, 2.5, 3])
      assert col.field.type == :f64
      assert col.field.nullable == false
      assert col.data == [[1, 2.5, 3]]
    end

    test "nan, infinity, neg_infinity infer as f64" do
      col = Adbc.Column.new([:nan, :infinity, :neg_infinity])
      assert col.field.type == :f64
      assert col.field.nullable == false
    end

    test "integers promoted to f64 when mixed with nan" do
      col = Adbc.Column.new([1, :nan, 3])
      assert col.field.type == :f64
    end

    test "nil sets nullable" do
      col = Adbc.Column.new([1, nil, 3])
      assert col.field.type == :s64
      assert col.field.nullable == true
      assert Adbc.Column.to_list(col) == [1, nil, 3]
    end

    test "only nils defaults to string" do
      col = Adbc.Column.new([nil, nil])
      assert col.field.type == :string
      assert col.field.nullable == true
    end

    test "strings" do
      col = Adbc.Column.new(["hello", "world"])
      assert col.field.type == :string
      assert col.field.nullable == false
    end

    test "dates infer as date32" do
      col = Adbc.Column.new([~D[2024-01-01], ~D[2024-12-31]])
      assert col.field.type == :date32
      assert col.field.nullable == false
    end

    test "dates mixed with integers" do
      col = Adbc.Column.new([100, ~D[2024-01-01], nil])
      assert col.field.type == :date32
      assert col.field.nullable == true
    end

    test "times infer as time64 microseconds" do
      col = Adbc.Column.new([~T[12:00:00], ~T[13:30:00]])
      assert col.field.type == {:time64, :microseconds}
      assert col.field.nullable == false
    end

    test "times mixed with integers" do
      col = Adbc.Column.new([1000, ~T[12:00:00]])
      assert col.field.type == {:time64, :microseconds}
    end

    test "naive datetimes infer as timestamp microseconds UTC" do
      col = Adbc.Column.new([~N[2024-01-01 12:00:00], ~N[2024-12-31 23:59:59]])
      assert col.field.type == {:timestamp, :microseconds, "UTC"}
      assert col.field.nullable == false
    end

    test "naive datetimes mixed with integers" do
      col = Adbc.Column.new([1000, ~N[2024-01-01 12:00:00], nil])
      assert col.field.type == {:timestamp, :microseconds, "UTC"}
      assert col.field.nullable == true
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

    test "explicit type skips inference and detects nullable" do
      col = Adbc.Column.new([1, 2, 3], type: :u32)
      assert col.field.type == :u32
      assert col.field.nullable == false

      col = Adbc.Column.new([1, nil, 3], type: :s16)
      assert col.field.type == :s16
      assert col.field.nullable == true
    end

    test "explicit type works for types that cannot be inferred" do
      col = Adbc.Column.new([100, 200], type: :u64)
      assert col.field.type == :u64

      col = Adbc.Column.new([1.0, 2.0], type: :f32)
      assert col.field.type == :f32

      col = Adbc.Column.new([1000, 2000], type: {:duration, :microseconds})
      assert col.field.type == {:duration, :microseconds}
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

  describe "decimals" do
    test "integers" do
      value = 42
      precision = 19
      scale = 10
      decimal = Decimal.new(value)

      col = Adbc.Column.decimal128([decimal, value], precision, scale)
      assert col.field.type == {:decimal128, precision, scale}
      assert col.field.nullable == false

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
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # nil at last position of a group of 8
      data = [1, 2, 3, 4, 5, 6, 7, nil]
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # all nils in a group of 8
      data = [nil, nil, nil, nil, nil, nil, nil, nil]
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # nil crossing the 8-element boundary
      data = [1, 2, 3, 4, 5, 6, 7, 8, nil, 10]
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # multiple nils across boundary
      data = [nil, 2, 3, 4, 5, 6, 7, nil, nil, 10, 11, 12, 13, 14, 15, nil]
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
      assert Adbc.Column.to_list(col) == to_decimals(data)

      # partial group (less than 8) with nil
      data = [1, nil, 3]
      col = Adbc.Column.decimal128(data, precision, scale, nullable: true)
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
end

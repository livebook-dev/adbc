defmodule Adbc.Column do
  @moduledoc """
  Represents columns in the table.

  It contains the column's field definition and data.
  The field (an `Adbc.Field`) describes the column's name, type,
  nullability, and metadata. The data field is opaque and must
  not be access directly, use functions such as `to_list/1`
  to get a list of values of the column's data type.

  You can create new columns using `new/2`, which will infer
  a base type if none is given, and detect if the columns are
  nullable or not.

  The other functions in this module, such as `s8/2`, `boolean/2`,
  etc, are meant to be low-level functions which expect correct
  data to be given. For example, they won't automatically
  detect nullable, nor validate it, you must explicitly provide
  said value as argument.
  """
  import Bitwise

  @enforce_keys [:field]
  defstruct [:field, :data, :size]

  @type t :: %Adbc.Column{
          field: Adbc.Field.t(),
          data: term(),
          size: non_neg_integer() | nil
        }

  # Value-range types used in constructor specs
  @type s8 :: -128..127
  @type u8 :: 0..255
  @type s16 :: -32768..32767
  @type u16 :: 0..65535
  @type s32 :: -2_147_483_648..2_147_483_647
  @type u32 :: 0..4_294_967_295
  @type s64 :: -9_223_372_036_854_775_808..9_223_372_036_854_775_807
  @type u64 :: 0..18_446_744_073_709_551_615
  @type precision128 :: 1..38
  @type precision256 :: 1..76
  @type interval_month :: s32()
  @type interval_day_xime :: {s32(), s32()}
  @type interval_month_day_nano :: {s32(), s32(), s64()}

  @doc """
  Creates a column by inferring the type from the data.

  This is a higher-level API that traverses the data element by element,
  inferring the most appropriate type. Nullable is automatically set to
  `true` if any `nil` values are found.

  ## Type inference rules

    * `true` / `false` → `:boolean`
    * integers → `:s64`
    * floats, `:nan`, `:infinity`, `:neg_infinity` → `:f64`
      (integers in the same column are promoted to `:f64`)
    * binaries → `:string`
    * `%Date{}` → `:date32` (integers also supported)
    * `%Time{}` → `{:time64, :microseconds}` (integers representing microseconds also supported)
    * `%NaiveDateTime{}` → `{:timestamp, :microseconds, "UTC"}` (integers representing microseconds also supported)
    * lists → `:list` (each element is a plain Elixir list or `nil`;
      inner type is recursively inferred)

  If `nil` values are present, then the column is appropriately marked as nullable.
  If there are no values, the default type of `:string` is assumed.

  If a `:type` is given, the type inference is skipped and only
  nullable detection is performed. This is useful for types that
  cannot be inferred, such as unsigned integers, smaller integer
  sizes, decimal, duration, interval, and composite types.

  ## Options

    * `:name` - The name of the column
    * `:type` - Explicitly set the column type, skipping type inference

  ## Examples

      iex> col = Adbc.Column.new([1, 2, 3], name: "ids")
      iex> col.field
      %Adbc.Field{name: "ids", type: :s64, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

      iex> col = Adbc.Column.new([1, nil, 3.0])
      iex> col.field
      %Adbc.Field{name: nil, type: :f64, nullable: true, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, nil, 3.0]

      iex> col = Adbc.Column.new([1, 2, 3], type: :u32)
      iex> col.field
      %Adbc.Field{name: nil, type: :u32, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec new(list(), Keyword.t()) :: t()
  def new(data, opts \\ []) when is_list(data) and is_list(opts) do
    {type, nullable} =
      case opts[:type] do
        nil -> infer_type(data, nil, false)
        type -> {type, Enum.member?(data, nil)}
      end

    %Adbc.Column{
      field: %Adbc.Field{
        name: opts[:name],
        type: type,
        nullable: nullable,
        metadata: nil
      },
      data: [encode_data(type, data)],
      size: length(data)
    }
  end

  @integer_types %{s8: 8, s16: 16, s32: 32, s64: 64, u8: 8, u16: 16, u32: 32, u64: 64}

  defp encode_data(type, data) when is_map_key(@integer_types, type) do
    encode_signed(data, Map.fetch!(@integer_types, type), &encode_integer/1)
  end

  defp encode_data(:date32, data), do: encode_date32(data)
  defp encode_data(:date64, data), do: encode_date64(data)
  defp encode_data({:time32, unit}, data), do: encode_time(data, unit, 32)
  defp encode_data({:time64, unit}, data), do: encode_time(data, unit, 64)
  defp encode_data({:timestamp, unit, _timezone}, data), do: encode_timestamp(data, unit)

  defp encode_data({:duration, _unit}, data),
    do: encode_signed(data, 64, &encode_integer/1)

  defp encode_data({:interval, unit}, data), do: encode_interval(data, unit)
  defp encode_data(_type, data), do: data

  @float_atoms [:nan, :infinity, :neg_infinity]

  defp infer_type([], nil, nullable), do: {:string, nullable}
  defp infer_type([], type, nullable), do: {type, nullable}

  defp infer_type([nil | rest], type, _nullable) do
    infer_type(rest, type, true)
  end

  defp infer_type([value | rest], type, nullable) when is_boolean(value) do
    case type do
      nil ->
        infer_type(rest, :boolean, nullable)

      :boolean ->
        infer_type(rest, :boolean, nullable)

      _ ->
        raise ArgumentError,
              "mixed types in column: got boolean but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type, nullable) when is_integer(value) do
    case type do
      nil ->
        infer_type(rest, :s64, nullable)

      :s64 ->
        infer_type(rest, :s64, nullable)

      :f64 ->
        infer_type(rest, :f64, nullable)

      :date32 ->
        infer_type(rest, :date32, nullable)

      {:time64, _} = t ->
        infer_type(rest, t, nullable)

      {:timestamp, _, _} = t ->
        infer_type(rest, t, nullable)

      _ ->
        raise ArgumentError,
              "mixed types in column: got integer but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type, nullable) when is_float(value) or value in @float_atoms do
    case type do
      nil ->
        infer_type(rest, :f64, nullable)

      :s64 ->
        infer_type(rest, :f64, nullable)

      :f64 ->
        infer_type(rest, :f64, nullable)

      _ ->
        raise ArgumentError,
              "mixed types in column: got float but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type, nullable) when is_binary(value) do
    case type do
      nil ->
        infer_type(rest, :string, nullable)

      :string ->
        infer_type(rest, :string, nullable)

      _ ->
        raise ArgumentError,
              "mixed types in column: got string but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%Date{} | rest], type, nullable) do
    case type do
      nil ->
        infer_type(rest, :date32, nullable)

      :date32 ->
        infer_type(rest, :date32, nullable)

      :s64 ->
        infer_type(rest, :date32, nullable)

      _ ->
        raise ArgumentError, "mixed types in column: got Date but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%Time{} | rest], type, nullable) do
    case type do
      nil ->
        infer_type(rest, {:time64, :microseconds}, nullable)

      {:time64, _} = t ->
        infer_type(rest, t, nullable)

      :s64 ->
        infer_type(rest, {:time64, :microseconds}, nullable)

      _ ->
        raise ArgumentError, "mixed types in column: got Time but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%NaiveDateTime{} | rest], type, nullable) do
    case type do
      nil ->
        infer_type(rest, {:timestamp, :microseconds, "UTC"}, nullable)

      {:timestamp, _, _} = t ->
        infer_type(rest, t, nullable)

      :s64 ->
        infer_type(rest, {:timestamp, :microseconds, "UTC"}, nullable)

      _ ->
        raise ArgumentError,
              "mixed types in column: got NaiveDateTime but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | _rest], _type, _nullable) do
    raise ArgumentError, "cannot infer type for value in column: #{inspect(value)}"
  end

  @doc type: :column_builder
  @doc """
  A column that contains booleans.

  ## Arguments

  * `data`: A list of booleans
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.boolean([true, false, true])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :boolean, nullable: false, metadata: nil},
        data: [[true, false, true]],
        size: 3
      }

  """
  @spec boolean([boolean()], Keyword.t()) :: t()
  def boolean(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:boolean, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains unsigned 8-bit integers.

  ## Arguments

  * `data`: A list of unsigned 8-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u8([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u8, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u8([u8() | nil], Keyword.t()) :: t()
  def u8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u8, opts),
      data: [encode_data(:u8, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains unsigned 16-bit integers.

  ## Arguments

  * `data`: A list of unsigned 16-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u16([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u16, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u16([u16() | nil], Keyword.t()) :: t()
  def u16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u16, opts),
      data: [encode_data(:u16, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains un32-bit signed integers.

  ## Arguments

  * `data`: A list of un32-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u32([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u32, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u32([u32() | nil], Keyword.t()) :: t()
  def u32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u32, opts),
      data: [encode_data(:u32, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains un64-bit signed integers.

  ## Arguments

  * `data`: A list of un64-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u64([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u64, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u64([u64() | nil], Keyword.t()) :: t()
  def u64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u64, opts),
      data: [encode_data(:u64, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains signed 8-bit integers.

  ## Arguments

  * `data`: A list of signed 8-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s8([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s8, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s8([s8() | nil], Keyword.t()) :: t()
  def s8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s8, opts),
      data: [encode_data(:s8, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains signed 16-bit integers.

  ## Arguments

  * `data`: A list of signed 16-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s16([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s16, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s16([s16() | nil], Keyword.t()) :: t()
  def s16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s16, opts),
      data: [encode_data(:s16, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains 32-bit signed integers.

  ## Arguments

  * `data`: A list of 32-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s32([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s32, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s32([s32() | nil], Keyword.t()) :: t()
  def s32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s32, opts),
      data: [encode_data(:s32, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains 64-bit signed integers.

  ## Arguments

  * `data`: A list of 64-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s64([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s64, nullable: false, metadata: nil}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s64([s64() | nil], Keyword.t()) :: t()
  def s64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s64, opts),
      data: [encode_data(:s64, data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains 16-bit half-precision floats.

  ## Arguments

  * `data`: A list of float values (will be converted to 16-bit floats in C). Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.f16([1.0, 2.0, 3.0])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :f16, nullable: false, metadata: nil},
        data: [[1.0, 2.0, 3.0]],
        size: 3
      }

  """
  @spec f16([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f16, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains 32-bit single-precision floats.

  ## Arguments

  * `data`: A list of 32-bit single-precision float values. Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.f32([1.0, 2.0, 3.0])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :f32, nullable: false, metadata: nil},
        data: [[1.0, 2.0, 3.0]],
        size: 3
      }

  """
  @spec f32([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f32, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains 64-bit double-precision floats.

  ## Arguments

  * `data`: A list of 64-bit double-precision float values. Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.f64([1.0, 2.0, 3.0])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :f64, nullable: false, metadata: nil},
        data: [[1.0, 2.0, 3.0]],
        size: 3
      }

  """
  @spec f64([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f64, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains 128-bit decimals.

  ## Arguments

  * `data`: a list, each element can be either
    * a `Decimal.t()`
    * an `integer()`
  * `precision`: The precision of the decimal values; precision should be between 1 and 38
  * `scale`: The scale of the decimal values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec decimal128([Decimal.t() | integer() | nil], precision128(), integer(), Keyword.t()) ::
          t()
  def decimal128(data, precision, scale, opts \\ [])
      when is_integer(precision) and precision >= 1 and precision <= 38 do
    %Adbc.Column{
      field: Adbc.Field.new({:decimal128, precision, scale}, opts),
      data: [encode_decimal(data, 128, precision, scale)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains 256-bit decimals.

  ## Arguments

  * `data`: a list, each element can be either
    * a `Decimal.t()`
    * an `integer()`
  * `precision`: The precision of the decimal values; precision should be between 1 and 76
  * `scale`: The scale of the decimal values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec decimal256([Decimal.t() | integer() | nil], precision256(), integer(), Keyword.t()) ::
          t()
  def decimal256(data, precision, scale, opts \\ [])
      when is_integer(precision) and precision >= 1 and precision <= 76 do
    %Adbc.Column{
      field: Adbc.Field.new({:decimal256, precision, scale}, opts),
      data: [encode_decimal(data, 256, precision, scale)],
      size: length(data)
    }
  end

  defp coef_length(0), do: 1
  defp coef_length(coef), do: coef_length(coef, 0)

  defp coef_length(0, length), do: length
  defp coef_length(coef, length), do: coef_length(Kernel.div(coef, 10), length + 1)

  defp encode_decimal(data, bitwidth, precision, scale) do
    encode_signed(data, bitwidth, fn
      integer when is_integer(integer) ->
        if coef_length(integer) > precision do
          raise ArgumentError,
                "`#{Integer.to_string(integer)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"
        end

        integer * Integer.pow(10, scale)

      %Decimal{exp: exp} = decimal when -exp > scale ->
        raise ArgumentError,
              "`#{Decimal.to_string(decimal)}` with exponent `#{exp}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number with scale value `#{scale}`"

      %Decimal{exp: exp} = decimal ->
        cond do
          Decimal.inf?(decimal) or Decimal.nan?(decimal) ->
            raise ArgumentError,
                  "`#{Decimal.to_string(decimal)}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number"

          coef_length(decimal.coef) > precision ->
            raise ArgumentError,
                  "`#{Decimal.to_string(decimal)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"

          true ->
            decimal.coef * decimal.sign * Integer.pow(10, exp + scale)
        end
    end)
  end

  @doc type: :column_builder
  @doc """
  A column that contains UTF-8 encoded strings.

  ## Arguments

  * `data`: A list of UTF-8 encoded string values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.string(["a", "ab", "abc"])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :string, nullable: false, metadata: nil},
        data: [["a", "ab", "abc"]],
        size: 3
      }

  """
  @spec string([String.t() | nil], Keyword.t()) :: t()
  def string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:string, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains UTF-8 encoded large strings.

  Similar to `string/2`, but for strings larger than 2GB.

  ## Arguments

  * `data`: A list of UTF-8 encoded string values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.large_string(["a", "ab", "abc"])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :large_string, nullable: false, metadata: nil},
        data: [["a", "ab", "abc"]],
        size: 3
      }

  """
  @spec large_string([String.t() | nil], Keyword.t()) :: t()
  def large_string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:large_string, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains binary values.

  ## Arguments

  * `data`: A list of binary values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.binary([<<0>>, <<1>>, <<2>>])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :binary, nullable: false, metadata: nil},
        data: [[<<0>>, <<1>>, <<2>>]],
        size: 3
      }

  """
  @spec binary([iodata() | nil], Keyword.t()) :: t()
  def binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:binary, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains large binary values.

  Similar to `binary/2`, but for binary values larger than 2GB.

  ## Arguments

  * `data`: A list of binary values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.large_binary([<<0>>, <<1>>, <<2>>])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :large_binary, nullable: false, metadata: nil},
        data: [[<<0>>, <<1>>, <<2>>]],
        size: 3
      }

  """
  @spec large_binary([iodata() | nil], Keyword.t()) :: t()
  def large_binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:large_binary, opts), data: [data], size: length(data)}
  end

  @doc type: :column_builder
  @doc """
  A column that contains fixed size binaries.

  Similar to `binary/2`, but each binary value has the same fixed size in bytes.

  ## Arguments

  * `data`: A list of binary values
  * `nbytes`: The fixed size of the binary values in bytes
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata

  ## Examples

      iex> Adbc.Column.fixed_size_binary([<<0>>, <<1>>, <<2>>], 1)
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: {:fixed_size_binary, 1}, nullable: false, metadata: nil},
        data: [[<<0>>, <<1>>, <<2>>]],
        size: 3
      }

  """
  @spec fixed_size_binary([iodata() | nil], non_neg_integer(), Keyword.t()) :: t()
  def fixed_size_binary(data, nbytes, opts \\ [])
      when is_list(data) and is_integer(nbytes) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new({:fixed_size_binary, nbytes}, opts),
      data: [data],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains date represented as 32-bit signed integers in UTC.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    * a `Date.t()`
    * a 32-bit signed integer representing the number of days since the Unix epoch.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec date32([Date.t() | s32() | nil], Keyword.t()) :: t()
  def date32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:date32, opts),
      data: [encode_date32(data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains date represented as 64-bit signed integers in UTC.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    * a `Date.t()`
    * a 64-bit signed integer representing the number of milliseconds since the Unix epoch.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec date64([Date.t() | s64() | nil], Keyword.t()) :: t()
  def date64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:date64, opts),
      data: [encode_date64(data)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains time represented as signed integers in UTC.

  ## Arguments

  * `data`:
    * a list of `Time.t()` value
    * a list of integer values representing the time in the specified unit

      Note that when using `:seconds` or `:milliseconds` as the unit,
      the time value is limited to the range of 32-bit signed integers.

      For `:microseconds` and `:nanoseconds`, the time value is limited
      to the range of 64-bit signed integers.

  * `unit`: specify the unit of the time value, one of the following:
    * `:seconds`
    * `:milliseconds`
    * `:microseconds`
    * `:nanoseconds`

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec time([Time.t() | s64() | nil], Adbc.Field.time_unit(), Keyword.t()) :: t()
  def time(data, unit, opts \\ [])

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:seconds, :milliseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:time32, unit}, opts),
      data: [encode_time(data, unit, 32)],
      size: length(data)
    }
  end

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:microseconds, :nanoseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:time64, unit}, opts),
      data: [encode_time(data, unit, 64)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains timestamps represented as signed integers in the given timezone.

  ## Arguments

  * `data`:
    * a list of `NaiveDateTime.t()` value
    * a list of 64-bit signed integer values representing the time in the specified unit

  * `unit`: specify the unit of the time value, one of the following:
    * `:seconds`
    * `:milliseconds`
    * `:microseconds`
    * `:nanoseconds`

  * `timezone`: the timezone of the timestamp

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec timestamp(
          [NaiveDateTime.t() | s64() | nil],
          Adbc.Field.time_unit(),
          String.t(),
          Keyword.t()
        ) ::
          t()
  def timestamp(data, unit, timezone, opts \\ [])
      when is_list(data) and is_binary(timezone) and is_list(opts) and
             unit in [:seconds, :milliseconds, :microseconds, :nanoseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:timestamp, unit, timezone}, opts),
      data: [encode_timestamp(data, unit)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains durations represented as 64-bit signed integers.

  ## Arguments

  * `data`: a list of integer values representing the time in the specified unit

  * `unit`: specify the unit of the time value, one of the following:
    * `:seconds`
    * `:milliseconds`
    * `:microseconds`
    * `:nanoseconds`

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec duration([s64() | nil], Adbc.Field.time_unit(), Keyword.t()) :: t()
  def duration(data, unit, opts \\ [])
      when is_list(data) and is_list(opts) and
             unit in [:seconds, :milliseconds, :microseconds, :nanoseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:duration, unit}, opts),
      data: [encode_signed(data, 64, &encode_integer/1)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that contains durations represented as signed integers.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    - if `unit` is `:month`:
      * a 32-bit signed integer representing the number of months.

    - if `unit` is `:day_time`:
      * a 2-tuple, both the number of days and the number of milliseconds are in 32-bit signed integers.

    - if `unit` is `:month_day_nano`:
      * a 3-tuple, the number of months, days, and nanoseconds;
        the number of months and days are in 32-bit signed integers,
        and the number of nanoseconds is in 64-bit signed integers

  * `unit`: specify the unit of the time value, one of the following:
    * `:month`
    * `:day_time`
    * `:month_day_nano`

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec interval(
          [interval_month() | interval_day_xime() | interval_month_day_nano() | nil],
          Adbc.Field.interval_unit(),
          Keyword.t()
        ) ::
          t()
  def interval(data, interval_unit, opts \\ [])
      when is_list(data) and is_list(opts) and
             interval_unit in [:month, :day_time, :month_day_nano] do
    %Adbc.Column{
      field: Adbc.Field.new({:interval, interval_unit}, opts),
      data: [encode_interval(data, interval_unit)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  A column that each row is a list of some type or nil.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec list([t() | nil], Adbc.Field.t(), Keyword.t()) :: t()
  def list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:list, inner_field}, opts),
      data: [encode_list(data, 32)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  Similar to `list/3`, but for large lists.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec large_list([t() | nil], Adbc.Field.t(), Keyword.t()) :: t()
  def large_list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:large_list, inner_field}, opts),
      data: [encode_list(data, 64)],
      size: length(data)
    }
  end

  @doc type: :column_builder
  @doc """
  Similar to `list/3`, but the length of the list is the same.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `fixed_size`: The fixed size of the list.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec fixed_size_list(list(), Adbc.Field.t(), s32(), Keyword.t()) :: t()
  def fixed_size_list(data, %Adbc.Field{} = inner_field, fixed_size, opts \\ [])
      when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:fixed_size_list, inner_field, fixed_size}, opts),
      data: [data]
    }
  end

  @doc type: :column_builder
  @doc """
  Construct an array using dictionary encoding.

  Dictionary encoding is a data representation technique to represent values by integers
  referencing a dictionary usually consisting of unique values. It can be effective when
  you have data with many repeated values.

  Any array can be dictionary-encoded. The dictionary is stored as an optional property
  of an array. When a field is dictionary encoded, the values are represented by an array
  of non-negative integers representing the index of the value in the dictionary. The memory
  layout for a dictionary-encoded array is the same as that of a primitive integer layout.
  The dictionary is handled as a separate columnar array with its own respective layout.

  As an example, you could have the following data:

  ```elixir
  Adbc.Column.string(["foo", "bar", "foo", "bar", nil, "baz"], nullable: true)
  ```

  In dictionary-encoded form, this could appear as:

  ```elixir
  Adbc.Column.dictionary(
    Adbc.Column.string(["foo", "bar", "baz"], nullable: true),
    Adbc.Column.s32([0, 1, 0, 1, nil, 2], nullable: true)
  )
  ```

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    - `nil`
    - `Adbc.Column`

    Note that each `Adbc.Column` in the list should have the same type.

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec dictionary(t(), t(), Keyword.t()) :: t()
  def dictionary(
        %Adbc.Column{field: %{type: index_type}} = key,
        %Adbc.Column{} = value,
        opts \\ []
      )
      when index_type in [:s8, :u8, :s16, :u16, :s32, :u32, :s64, :u64] do
    %Adbc.Column{
      field: Adbc.Field.new({:dictionary, key.field, value.field}, opts),
      # Each chunk in the dictionary is a single array and you cannot
      # have keys across chunks, so in here we assume the chunks are independent
      data: Enum.zip_with(key.data, value.data, fn k, v -> %{key: k, value: v} end),
      size: key.size
    }
  end

  @doc """
  Converts a column's data from reference type to regular Elixir terms.

  The `size` field is `nil` for unmaterialized columns and is set to the
  number of elements after materialization (or when built from Elixir).
  You can use `size` to check whether a column has been materialized.
  """
  @spec materialize(t()) :: t()
  def materialize(%Adbc.Column{size: size} = column) when is_integer(size), do: column

  def materialize(%Adbc.Column{field: field, data: data_ref} = column) do
    case Adbc.Nif.adbc_column_materialize(data_ref) do
      {:ok, {data, size}} ->
        %{column | data: data, size: size}

      {:error, reason} ->
        raise ArgumentError, "could not materialize column #{inspect(field.name)}: #{reason}"
    end
  end

  @doc """
  Converts a column's data to a plain Elixir list.

  For primitive columns, returns the data as-is. For composite
  types (dictionary, list, struct, list_view, run_end_encoded),
  expands the data into its logical representation.

  ## Examples

      iex> Adbc.Column.s32([1, 2, 3]) |> Adbc.Column.to_list()
      [1, 2, 3]

      iex> col = Adbc.Column.dictionary(
      ...>   Adbc.Column.s32([0, 1, 0, 2]),
      ...>   Adbc.Column.string(["a", "b", "c"])
      ...> )
      iex> Adbc.Column.to_list(col)
      ["a", "b", "a", "c"]

  """
  @spec to_list(t()) :: [term()]
  def to_list(%Adbc.Column{
        field: %{type: {:dictionary, key_field, value_field}},
        data: batches
      }) do
    Enum.flat_map(batches, fn %{key: key_data, value: value_data} ->
      value_list = to_list(%Adbc.Column{field: value_field, data: [value_data]})

      to_list(%Adbc.Column{field: key_field, data: [key_data]})
      |> Enum.map(fn
        index when is_integer(index) -> Enum.at(value_list, index)
        nil -> nil
      end)
    end)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:run_end_encoded, run_ends_field, values_field}},
        data: batches
      }) do
    Enum.flat_map(batches, fn batch ->
      values = to_list(%Adbc.Column{field: values_field, data: [batch.values]})
      run_ends = to_list(%Adbc.Column{field: run_ends_field, data: [batch.run_ends], size: 0})
      expand_runs(run_ends, values, batch.offset, batch.offset + batch.length)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {type, inner_field}}, data: batches})
      when type in [:list_view, :large_list_view] do
    Enum.flat_map(batches, fn batch ->
      values = to_list(%Adbc.Column{field: inner_field, data: [batch.values]})

      Enum.zip_with([batch.offsets, batch.sizes, batch.validity], fn
        [offset, size, true] -> Enum.slice(values, offset, size)
        [_offset, _size, false] -> nil
      end)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:struct, fields}}, data: batches}) do
    Enum.flat_map(batches, fn batch ->
      columns =
        Enum.zip_with(fields, batch, fn field, col_data ->
          %Adbc.Column{field: field, data: [col_data], size: 0}
        end)

      %Adbc.Result{data: columns, num_rows: nil}
      |> Table.to_rows()
      |> Enum.to_list()
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:list, inner_field}}, data: batches}) do
    Enum.flat_map(batches, fn %{} = batch ->
      values = to_list(%Adbc.Column{field: inner_field, data: batch.values})
      <<first::signed-integer-little-32, rest::binary>> = batch.offsets
      decode_list_32(rest, batch.validity, batch.offset, values, first, 0)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:large_list, inner_field}}, data: batches}) do
    Enum.flat_map(batches, fn %{} = batch ->
      values = to_list(%Adbc.Column{field: inner_field, data: batch.values})
      <<first::signed-integer-little-64, rest::binary>> = batch.offsets
      decode_list_64(rest, batch.validity, batch.offset, values, first, 0)
    end)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:fixed_size_list, inner_field, fixed_size}},
        data: batches
      }) do
    Enum.flat_map(batches, fn %{} = batch ->
      values = to_list(%Adbc.Column{field: inner_field, data: batch.values})
      decode_fixed_size_list(values, batch.validity, batch.offset, fixed_size, 0)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: :date32}, data: batches}) do
    decoder = &days_to_date/1

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_32(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: :date64}, data: batches}) do
    decoder = &milliseconds_to_date/1

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_64(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:time32, unit}}, data: batches}) do
    decoder = &int_to_time(&1, unit)

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_32(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:time64, unit}}, data: batches}) do
    decoder = &int_to_time(&1, unit)

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_64(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:timestamp, unit, _timezone}}, data: batches}) do
    decoder = &int_to_naive_datetime(&1, unit)

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_64(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:duration, _unit}}, data: batches}) do
    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_64(binary, bitmap, bit_offset, &Function.identity/1)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:interval, :month}}, data: batches}) do
    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_32(binary, bitmap, bit_offset, &Function.identity/1)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:interval, :day_time}}, data: batches}) do
    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_interval_day_time(binary, bitmap, bit_offset)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:interval, :month_day_nano}}, data: batches}) do
    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_interval_month_day_nano(binary, bitmap, bit_offset)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:decimal128, _, scale}}, data: batches}) do
    decoder = &coef_to_decimal(&1, scale)

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_128(binary, bitmap, bit_offset, decoder)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:decimal256, _, scale}}, data: batches}) do
    decoder = &coef_to_decimal(&1, scale)

    Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
      decode_signed_256(binary, bitmap, bit_offset, decoder)
    end)
  end

  for {type, decode_fun} <- [
        s8: :decode_signed_8,
        s16: :decode_signed_16,
        s32: :decode_signed_32,
        s64: :decode_signed_64,
        u8: :decode_unsigned_8,
        u16: :decode_unsigned_16,
        u32: :decode_unsigned_32,
        u64: :decode_unsigned_64
      ] do
    def to_list(%Adbc.Column{field: %{type: unquote(type)}, data: batches}) do
      Enum.flat_map(batches, fn {binary, bitmap, bit_offset} ->
        unquote(decode_fun)(binary, bitmap, bit_offset, &Function.identity/1)
      end)
    end
  end

  def to_list(%Adbc.Column{data: batches}) do
    Enum.concat(batches)
  end

  defp encode_list(data, offset_size) do
    encode_list(data, [], <<0::size(offset_size)>>, <<>>, 0, 0, offset_size)
  end

  defp encode_list([], child_batches, offsets, bitmap, pending, _offset, _offset_size) do
    # This is effectively a single batch. While values is a single array
    # in Arrow, we keep it as a list so we concat buffers in C
    {_data, bitmap, bit_offset} = bitmap_finish(<<>>, bitmap, pending)
    %{offsets: offsets, validity: bitmap, values: Enum.reverse(child_batches), offset: bit_offset}
  end

  defp encode_list([nil | rest], batches, offsets, bitmap, pending, offset, offset_size) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    offsets = <<offsets::binary, offset::signed-integer-little-size(offset_size)>>
    encode_list(rest, batches, offsets, bitmap, pending, offset, offset_size)
  end

  defp encode_list(
         [%Adbc.Column{data: data, size: size} | rest],
         batches,
         offsets,
         bitmap,
         pending,
         offset,
         offset_size
       ) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    new_offset = offset + size
    batches = Enum.reverse(data, batches)
    offsets = <<offsets::binary, new_offset::signed-integer-little-size(offset_size)>>
    encode_list(rest, batches, offsets, bitmap, pending, new_offset, offset_size)
  end

  @epoch_days Date.to_gregorian_days(~D[1970-01-01])
  defp days_to_date(days), do: Date.from_gregorian_days(days + @epoch_days)
  defp milliseconds_to_date(ms), do: Date.from_gregorian_days(div(ms, 86_400_000) + @epoch_days)

  defp encode_date32(data) do
    encode_signed(data, 32, fn
      %Date{} = date -> Date.to_gregorian_days(date) - @epoch_days
      integer when is_integer(integer) -> integer
    end)
  end

  defp encode_date64(data) do
    encode_signed(data, 64, fn
      %Date{} = date -> (Date.to_gregorian_days(date) - @epoch_days) * 86_400_000
      integer when is_integer(integer) -> integer
    end)
  end

  @time_unit_multiplier %{
    seconds: 1,
    milliseconds: 1_000,
    microseconds: 1_000_000,
    nanoseconds: 1_000_000_000
  }

  defp encode_time(data, unit, bitwidth) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)

    encode_signed(data, bitwidth, fn
      %Time{} = time ->
        {seconds, microseconds} = Time.to_seconds_after_midnight(time)
        seconds * multiplier + microseconds * div(multiplier, 1_000_000)

      integer when is_integer(integer) ->
        integer
    end)
  end

  defp int_to_time(val, unit) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)
    total_us = div(val * 1_000_000, multiplier)
    seconds = div(total_us, 1_000_000)
    microseconds = rem(total_us, 1_000_000)
    Time.add(~T[00:00:00], seconds * 1_000_000 + microseconds, :microsecond)
  end

  @epoch_seconds :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  defp encode_timestamp(data, unit) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)

    encode_signed(data, 64, fn
      %NaiveDateTime{} = ndt ->
        {gregorian_seconds, microseconds} = NaiveDateTime.to_gregorian_seconds(ndt)
        unix_seconds = gregorian_seconds - @epoch_seconds
        unix_seconds * multiplier + microseconds * div(multiplier, 1_000_000)

      integer when is_integer(integer) ->
        integer
    end)
  end

  defp encode_integer(integer) when is_integer(integer), do: integer

  defp encode_interval(data, :month) do
    encode_signed(data, 32, &encode_integer/1)
  end

  defp encode_interval(data, :day_time) do
    encode_interval_day_time(data, <<>>, <<>>, 0)
  end

  defp encode_interval(data, :month_day_nano) do
    encode_interval_month_day_nano(data, <<>>, <<>>, 0)
  end

  @unit_precision %{seconds: 0, milliseconds: 3, microseconds: 6, nanoseconds: 6}

  defp int_to_naive_datetime(val, unit) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)
    precision = Map.fetch!(@unit_precision, unit)
    total_us = div(val * 1_000_000, multiplier)
    unix_seconds = div(total_us, 1_000_000)
    microseconds = rem(total_us, 1_000_000)
    gregorian_seconds = unix_seconds + @epoch_seconds
    NaiveDateTime.from_gregorian_seconds(gregorian_seconds, {microseconds, precision})
  end

  defp coef_to_decimal(coef, scale) when coef < 0, do: Decimal.new(-1, -coef, -scale)
  defp coef_to_decimal(coef, scale), do: Decimal.new(1, coef, -scale)

  defp expand_runs([run_end | run_ends], [_ | values], pos, stop)
       when run_end <= pos do
    expand_runs(run_ends, values, pos, stop)
  end

  defp expand_runs([run_end | run_ends], [value | values], pos, stop) do
    duplicate_runs(value, min(run_end, stop) - pos, run_ends, values, min(run_end, stop), stop)
  end

  defp expand_runs(_, _, _, _), do: []

  defp duplicate_runs(_value, 0, run_ends, values, pos, stop) do
    expand_runs(run_ends, values, pos, stop)
  end

  defp duplicate_runs(value, n, run_ends, values, pos, stop) do
    [value | duplicate_runs(value, n - 1, run_ends, values, pos, stop)]
  end

  ## Bit encoding

  # Single-pass encoding of a data list into {binary, bitmap | nil, offset}.
  # `encoder` converts each non-nil element to an integer.
  # `pending` tracks bitmap state:
  #   - integer N: postponed valid bits, no partial byte in progress
  #   - {byte, bits}: partial byte being built LSB-first, bits is 1-7
  # `bitmap` is passed explicitly for Erlang binary append optimization.

  defp encode_signed(list, size, encoder) do
    encode_signed(list, <<>>, <<>>, 0, size, encoder)
  end

  defp encode_signed([], data, bitmap, pending, _size, _encoder) do
    bitmap_finish(data, bitmap, pending)
  end

  defp encode_signed([nil | rest], data, bitmap, pending, size, encoder) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_signed(rest, <<data::binary, 0::size(size)>>, bitmap, pending, size, encoder)
  end

  defp encode_signed([value | rest], data, bitmap, pending, size, encoder) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, encoder.(value)::signed-integer-little-size(size)>>
    encode_signed(rest, data, bitmap, pending, size, encoder)
  end

  ## Interval encoding (custom multi-field binary, avoids big integer arithmetic)

  defp encode_interval_day_time([], data, bitmap, pending) do
    bitmap_finish(data, bitmap, pending)
  end

  defp encode_interval_day_time([nil | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_interval_day_time(rest, <<data::binary, 0::64>>, bitmap, pending)
  end

  defp encode_interval_day_time([{days, ms} | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, days::signed-integer-little-32, ms::signed-integer-little-32>>
    encode_interval_day_time(rest, data, bitmap, pending)
  end

  defp encode_interval_month_day_nano([], data, bitmap, pending) do
    bitmap_finish(data, bitmap, pending)
  end

  defp encode_interval_month_day_nano([nil | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_interval_month_day_nano(rest, <<data::binary, 0::128>>, bitmap, pending)
  end

  defp encode_interval_month_day_nano([{months, days, ns} | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)

    data =
      <<data::binary, months::signed-integer-little-32, days::signed-integer-little-32,
        ns::signed-integer-little-64>>

    encode_interval_month_day_nano(rest, data, bitmap, pending)
  end

  defp bitmap_finish(data, bitmap, pending) when is_integer(pending) and byte_size(bitmap) == 0 do
    {data, nil, 0}
  end

  defp bitmap_finish(data, bitmap, pending) when is_integer(pending) do
    {bitmap, rem_bits} = bitmap_flush_valid(bitmap, pending)
    bitmap = if rem_bits > 0, do: <<bitmap::binary, (1 <<< rem_bits) - 1>>, else: bitmap
    {data, bitmap, 0}
  end

  defp bitmap_finish(data, bitmap, {byte, _bits}) do
    {data, <<bitmap::binary, byte>>, 0}
  end

  @compile {:inline,
            bitmap_put_bit: 4, bitmap_flush_valid: 2, bitmap_mark_valid: 2, bitmap_mark_null: 2}
  defp bitmap_mark_valid(bitmap, pending) when is_integer(pending), do: {bitmap, pending + 1}
  defp bitmap_mark_valid(bitmap, {byte, bits}), do: bitmap_put_bit(bitmap, byte, bits, 1)

  defp bitmap_mark_null(bitmap, pending) when is_integer(pending) do
    {bitmap, rem_bits} = bitmap_flush_valid(bitmap, pending)
    bitmap_put_bit(bitmap, (1 <<< rem_bits) - 1, rem_bits, 0)
  end

  defp bitmap_mark_null(bitmap, {byte, bits}), do: bitmap_put_bit(bitmap, byte, bits, 0)

  defp bitmap_put_bit(bitmap, byte, 7, bit) do
    {<<bitmap::binary, byte ||| bit <<< 7>>, 0}
  end

  defp bitmap_put_bit(bitmap, byte, bits, bit) do
    {bitmap, {byte ||| bit <<< bits, bits + 1}}
  end

  defp bitmap_flush_valid(bitmap, pending) do
    full_size = div(pending, 8) * 8
    {<<bitmap::binary, -1::size(full_size)>>, rem(pending, 8)}
  end

  ## Decoding

  defp decode_fixed_size_list([], _validity, _bit_offset, _fixed_size, _index) do
    []
  end

  defp decode_fixed_size_list(values, validity, bit_offset, fixed_size, index) do
    {chunk, rest} = Enum.split(values, fixed_size)
    element = if bitmap_valid?(validity, index, bit_offset), do: chunk
    [element | decode_fixed_size_list(rest, validity, bit_offset, fixed_size, index + 1)]
  end

  defp decode_interval_day_time(binary, validity, offset) do
    decode_interval_day_time(binary, validity, offset, 0)
  end

  defp decode_interval_day_time(
         <<days::signed-integer-little-32, ms::signed-integer-little-32, rest::binary>>,
         validity,
         offset,
         index
       ) do
    value = if bitmap_valid?(validity, index, offset), do: {days, ms}
    [value | decode_interval_day_time(rest, validity, offset, index + 1)]
  end

  defp decode_interval_day_time(<<>>, _validity, _offset, _index), do: []

  defp decode_interval_month_day_nano(binary, validity, offset) do
    decode_interval_month_day_nano(binary, validity, offset, 0)
  end

  defp decode_interval_month_day_nano(
         <<months::signed-integer-little-32, days::signed-integer-little-32,
           ns::signed-integer-little-64, rest::binary>>,
         validity,
         offset,
         index
       ) do
    value = if bitmap_valid?(validity, index, offset), do: {months, days, ns}
    [value | decode_interval_month_day_nano(rest, validity, offset, index + 1)]
  end

  defp decode_interval_month_day_nano(<<>>, _validity, _offset, _index), do: []

  for {name, specifier} <- [
        decode_list_32: quote(do: signed - integer - little - 32),
        decode_list_64: quote(do: signed - integer - little - 64)
      ] do
    defp unquote(name)(<<>>, _validity, _bit_offset, _values, _prev, _index) do
      []
    end

    defp unquote(name)(
           <<next::unquote(specifier), rest::binary>>,
           validity,
           bit_offset,
           values,
           prev,
           index
         ) do
      {chunk, values} = Enum.split(values, next - prev)
      element = if bitmap_valid?(validity, index, bit_offset), do: chunk
      [element | unquote(name)(rest, validity, bit_offset, values, next, index + 1)]
    end
  end

  for {name, specifier} <- [
        decode_signed_8: quote(do: signed - integer - little - 8),
        decode_signed_16: quote(do: signed - integer - little - 16),
        decode_signed_32: quote(do: signed - integer - little - 32),
        decode_signed_64: quote(do: signed - integer - little - 64),
        decode_signed_128: quote(do: signed - integer - little - 128),
        decode_signed_256: quote(do: signed - integer - little - 256),
        decode_unsigned_8: quote(do: unsigned - integer - little - 8),
        decode_unsigned_16: quote(do: unsigned - integer - little - 16),
        decode_unsigned_32: quote(do: unsigned - integer - little - 32),
        decode_unsigned_64: quote(do: unsigned - integer - little - 64)
      ] do
    defp unquote(name)(binary, validity, offset, decoder) do
      unquote(name)(binary, validity, offset, 0, decoder)
    end

    defp unquote(name)(
           <<int::unquote(specifier), rest::binary>>,
           validity,
           offset,
           index,
           decoder
         ) do
      value = if bitmap_valid?(validity, index, offset), do: decoder.(int)
      [value | unquote(name)(rest, validity, offset, index + 1, decoder)]
    end

    defp unquote(name)(<<>>, _validity, _offset, _index, _decoder), do: []
  end

  @compile {:inline, bitmap_valid?: 3}
  defp bitmap_valid?(nil, _index, _bit_offset), do: true

  defp bitmap_valid?(validity, index, bit_offset) do
    bit_pos = index + bit_offset
    byte = :binary.at(validity, div(bit_pos, 8))
    (byte &&& 1 <<< rem(bit_pos, 8)) != 0
  end
end

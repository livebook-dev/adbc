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
  @enforce_keys [:field]
  defstruct [:field, :data]

  @type t :: %Adbc.Column{
          field: Adbc.Field.t(),
          data: term()
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

      iex> Adbc.Column.new([1, 2, 3], name: "ids")
      %Adbc.Column{
        field: %Adbc.Field{name: "ids", type: :s64, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

      iex> Adbc.Column.new([1, nil, 3.0])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :f64, nullable: true, metadata: nil},
        data: [[1, nil, 3.0]]
      }

      iex> Adbc.Column.new([1, 2, 3], type: :u32)
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :u32, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

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
      data: [data]
    }
  end

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
        data: [[true, false, true]]
      }

  """
  @spec boolean([boolean()], Keyword.t()) :: t()
  def boolean(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:boolean, opts), data: [data]}
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

      iex> Adbc.Column.u8([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :u8, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec u8([u8() | nil], Keyword.t()) :: t()
  def u8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:u8, opts), data: [data]}
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

      iex> Adbc.Column.u16([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :u16, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec u16([u16() | nil], Keyword.t()) :: t()
  def u16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:u16, opts), data: [data]}
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

      iex> Adbc.Column.u32([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :u32, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec u32([u32() | nil], Keyword.t()) :: t()
  def u32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:u32, opts), data: [data]}
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

      iex> Adbc.Column.u32([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :u32, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec u64([u64() | nil], Keyword.t()) :: t()
  def u64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:u64, opts), data: [data]}
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

      iex> Adbc.Column.s8([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :s8, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec s8([s8() | nil], Keyword.t()) :: t()
  def s8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:s8, opts), data: [data]}
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

      iex> Adbc.Column.s16([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :s16, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec s16([s16() | nil], Keyword.t()) :: t()
  def s16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:s16, opts), data: [data]}
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

      iex> Adbc.Column.s32([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :s32, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec s32([s32() | nil], Keyword.t()) :: t()
  def s32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:s32, opts), data: [data]}
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

      iex> Adbc.Column.s64([1, 2, 3])
      %Adbc.Column{
        field: %Adbc.Field{name: nil, type: :s64, nullable: false, metadata: nil},
        data: [[1, 2, 3]]
      }

  """
  @spec s64([s64() | nil], Keyword.t()) :: t()
  def s64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:s64, opts), data: [data]}
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
        data: [[1.0, 2.0, 3.0]]
      }

  """
  @spec f16([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f16, opts), data: [data]}
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
        data: [[1.0, 2.0, 3.0]]
      }

  """
  @spec f32([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f32, opts), data: [data]}
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
        data: [[1.0, 2.0, 3.0]]
      }

  """
  @spec f64([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:f64, opts), data: [data]}
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
    bitwidth = 128

    %Adbc.Column{
      field: Adbc.Field.new({:decimal, bitwidth, precision, scale}, opts),
      data: [preprocess_decimal(data, bitwidth, precision, scale)]
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
    bitwidth = 256

    %Adbc.Column{
      field: Adbc.Field.new({:decimal, bitwidth, precision, scale}, opts),
      data: [preprocess_decimal(data, bitwidth, precision, scale)]
    }
  end

  defp coef_length(0), do: 1
  defp coef_length(coef), do: coef_length(coef, 0)

  defp coef_length(0, length), do: length
  defp coef_length(coef, length), do: coef_length(Kernel.div(coef, 10), length + 1)

  defp preprocess_decimal([], _bitwidth, _precision, _scale), do: []

  defp preprocess_decimal([nil | rest], bitwidth, precision, scale) do
    [nil | preprocess_decimal(rest, bitwidth, precision, scale)]
  end

  defp preprocess_decimal([integer | rest], bitwidth, precision, scale)
       when is_integer(integer) do
    if coef_length(integer) > precision do
      raise ArgumentError,
            "`#{Integer.to_string(integer)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"
    else
      coef = integer * Integer.pow(10, scale)

      [
        <<coef::signed-integer-little-size(bitwidth)>>
        | preprocess_decimal(rest, bitwidth, precision, scale)
      ]
    end
  end

  defp preprocess_decimal(
         [%Decimal{exp: exp} = decimal | _rest],
         bitwidth,
         _precision,
         scale
       )
       when -exp > scale do
    raise ArgumentError,
          "`#{Decimal.to_string(decimal)}` with exponent `#{exp}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number with scale value `#{scale}`"
  end

  defp preprocess_decimal([%Decimal{exp: exp} = decimal | rest], bitwidth, precision, scale)
       when -exp <= scale do
    cond do
      Decimal.inf?(decimal) or Decimal.nan?(decimal) ->
        raise ArgumentError,
              "`#{Decimal.to_string(decimal)}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number"

      coef_length(decimal.coef) > precision ->
        raise ArgumentError,
              "`#{Decimal.to_string(decimal)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"

      true ->
        coef = decimal.coef * decimal.sign * Integer.pow(10, exp + scale)

        [
          <<coef::signed-integer-little-size(bitwidth)>>
          | preprocess_decimal(rest, bitwidth, precision, scale)
        ]
    end
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
        data: [["a", "ab", "abc"]]
      }

  """
  @spec string([String.t() | nil], Keyword.t()) :: t()
  def string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:string, opts), data: [data]}
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
        data: [["a", "ab", "abc"]]
      }

  """
  @spec large_string([String.t() | nil], Keyword.t()) :: t()
  def large_string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:large_string, opts), data: [data]}
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
        data: [[<<0>>, <<1>>, <<2>>]]
      }

  """
  @spec binary([iodata() | nil], Keyword.t()) :: t()
  def binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:binary, opts), data: [data]}
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
        data: [[<<0>>, <<1>>, <<2>>]]
      }

  """
  @spec large_binary([iodata() | nil], Keyword.t()) :: t()
  def large_binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new(:large_binary, opts), data: [data]}
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
        data: [[<<0>>, <<1>>, <<2>>]]
      }

  """
  @spec fixed_size_binary([iodata() | nil], non_neg_integer(), Keyword.t()) :: t()
  def fixed_size_binary(data, nbytes, opts \\ [])
      when is_list(data) and is_integer(nbytes) and is_list(opts) do
    %Adbc.Column{field: Adbc.Field.new({:fixed_size_binary, nbytes}, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new(:date32, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new(:date64, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new({:time32, unit}, opts), data: [data]}
  end

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:microseconds, :nanoseconds] do
    %Adbc.Column{field: Adbc.Field.new({:time64, unit}, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new({:timestamp, unit, timezone}, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new({:duration, unit}, opts), data: [data]}
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
    %Adbc.Column{field: Adbc.Field.new({:interval, interval_unit}, opts), data: [data]}
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
  @spec list(list(), Adbc.Field.t(), Keyword.t()) :: t()
  def list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{field: Adbc.Field.new({:list, inner_field}, opts), data: [data]}
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
  @spec large_list(list(), Adbc.Field.t(), Keyword.t()) :: t()
  def large_list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{field: Adbc.Field.new({:large_list, inner_field}, opts), data: [data]}
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
      data: Enum.zip_with(key.data, value.data, fn k, v -> %{key: k, value: v} end)
    }
  end

  @doc """
  `materialize/1` converts a column's data from reference type to regular Elixir terms.
  """
  @spec materialize(t()) :: t()
  def materialize(%Adbc.Column{field: field, data: data_ref} = column)
      when is_list(data_ref) do
    if Enum.all?(data_ref, &is_reference/1) do
      case Adbc.Nif.adbc_column_materialize(data_ref) do
        {:ok, data} ->
          %{column | data: data}

        {:error, reason} ->
          raise ArgumentError, "could not materialize column #{inspect(field.name)}: #{reason}"
      end
    else
      column
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
        field: %{type: {:run_end_encoded, _run_ends_field, values_field}},
        data: batches
      }) do
    Enum.flat_map(batches, fn batch ->
      values = to_list(%Adbc.Column{field: values_field, data: [batch.values]})
      expand_runs(batch.run_ends, values, batch.offset, batch.offset + batch.length)
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

  def to_list(%Adbc.Column{field: %{type: {:decimal, bits, _, scale}}, data: batches}) do
    Enum.flat_map(batches, fn batch ->
      Enum.map(batch, fn
        <<coef::signed-integer-size(bits)-little>> ->
          if coef < 0 do
            Decimal.new(-1, -coef, -scale)
          else
            Decimal.new(1, coef, -scale)
          end

        nil ->
          nil
      end)
    end)
  end

  def to_list(%Adbc.Column{field: %{type: {:struct, fields}}, data: batches}) do
    Enum.flat_map(batches, fn batch ->
      columns =
        Enum.zip_with(fields, batch, fn field, col_data ->
          %Adbc.Column{field: field, data: [col_data]}
        end)

      %Adbc.Result{data: columns, num_rows: nil}
      |> Table.to_rows()
      |> Enum.to_list()
    end)
  end

  def to_list(%Adbc.Column{data: batches}) do
    Enum.concat(batches)
  end

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
end

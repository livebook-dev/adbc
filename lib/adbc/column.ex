defmodule Adbc.Column do
  @moduledoc """
  Represents columns in the table.

  It contains the column's field definition and data.
  The field (an `Adbc.Field`) describes the column's name, type,
  and metadata. The data field is opaque and must not be accessed
  directly, use functions such as `to_list/1` to get a list of
  values of the column's data type.

  You can create new columns using constructors such as `s8/2`,
  `boolean/2`, etc. `new/2` is available as a convenience that
  infers the type for you.
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

  @time_unit_multiplier %{
    seconds: 1,
    milliseconds: 1_000,
    microseconds: 1_000_000,
    nanoseconds: 1_000_000_000
  }

  @unit_precision %{seconds: 0, milliseconds: 3, microseconds: 6, nanoseconds: 6}
  @epoch_days Date.to_gregorian_days(~D[1970-01-01])
  @epoch_seconds :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  @deprecated "Adbc.Column.materialize/1 is no longer necessary, it is a noop."
  @spec materialize(t()) :: t()
  def materialize(%Adbc.Column{} = column), do: column

  @doc """
  Creates a column by inferring the type from the data.

  This is a higher-level API that traverses the data element by element,
  inferring the most appropriate type.

  ## Type inference rules

    * `true` / `false` → `:boolean`
    * integers → `:s64`
    * floats, `:nan`, `:infinity`, `:neg_infinity` → `:f64`
      (integers in the same column are promoted to `:f64`)
    * binaries → `:string`
    * `%Date{}` → `:date32` (integers also supported)
    * `%Time{}` → `{:time64, :microseconds}` (integers representing microseconds also supported)
    * `%NaiveDateTime{}` → `{:timestamp, :microseconds, "UTC"}` (integers representing microseconds also supported)

  If there are no values, the default type of `:string` is assumed.

  ## Options

    * `:name` - The name of the column

  ## Examples

      iex> col = Adbc.Column.new([1, 2, 3], name: "ids")
      iex> col.field
      %Adbc.Field{name: "ids", type: :s64}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

      iex> col = Adbc.Column.new([1, nil, 3.0])
      iex> col.field
      %Adbc.Field{name: nil, type: :f64}
      iex> Adbc.Column.to_list(col)
      [1.0, nil, 3.0]

  """
  @spec new(list(), Keyword.t()) :: t()
  def new(data, opts \\ []) when is_list(data) and is_list(opts) do
    case infer_type(data, nil) do
      {:struct, keys} ->
        encode_struct(keys, data, opts)

      type ->
        %Adbc.Column{
          field: %Adbc.Field{
            name: opts[:name],
            type: type
          },
          data: encode_data(type, data),
          size: length(data)
        }
    end
  end

  defp encode_data(:boolean, data), do: encode_boolean(data)
  defp encode_data(:s64, data), do: encode_buffer(data, 64, &encode_integer/1)
  defp encode_data(:f64, data), do: encode_float(data, 64)
  defp encode_data(:string, data), do: encode_string(data, 32)
  defp encode_data(:date32, data), do: encode_date32(data)
  defp encode_data({:time64, unit}, data), do: encode_time(data, unit, 64)
  defp encode_data({:timestamp, unit, _timezone}, data), do: encode_timestamp(data, unit)

  @float_atoms [:nan, :infinity, :neg_infinity]

  defp infer_type([], nil), do: :string
  defp infer_type([], type), do: type

  defp infer_type([nil | rest], type), do: infer_type(rest, type)

  defp infer_type([value | rest], type) when is_boolean(value) do
    case type do
      nil ->
        infer_type(rest, :boolean)

      :boolean ->
        infer_type(rest, :boolean)

      _ ->
        raise ArgumentError,
              "mixed types in column: got boolean but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type) when is_integer(value) do
    case type do
      nil ->
        infer_type(rest, :s64)

      :s64 ->
        infer_type(rest, :s64)

      :f64 ->
        infer_type(rest, :f64)

      :date32 ->
        infer_type(rest, :date32)

      {:time64, _} = t ->
        infer_type(rest, t)

      {:timestamp, _, _} = t ->
        infer_type(rest, t)

      _ ->
        raise ArgumentError,
              "mixed types in column: got integer but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type) when is_float(value) or value in @float_atoms do
    case type do
      nil ->
        infer_type(rest, :f64)

      :s64 ->
        infer_type(rest, :f64)

      :f64 ->
        infer_type(rest, :f64)

      _ ->
        raise ArgumentError,
              "mixed types in column: got float but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | rest], type) when is_binary(value) do
    case type do
      nil ->
        infer_type(rest, :string)

      :string ->
        infer_type(rest, :string)

      _ ->
        raise ArgumentError,
              "mixed types in column: got string but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%Date{} | rest], type) do
    case type do
      nil ->
        infer_type(rest, :date32)

      :date32 ->
        infer_type(rest, :date32)

      :s64 ->
        infer_type(rest, :date32)

      _ ->
        raise ArgumentError, "mixed types in column: got Date but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%Time{} | rest], type) do
    case type do
      nil ->
        infer_type(rest, {:time64, :microseconds})

      {:time64, _} = t ->
        infer_type(rest, t)

      :s64 ->
        infer_type(rest, {:time64, :microseconds})

      _ ->
        raise ArgumentError, "mixed types in column: got Time but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%NaiveDateTime{} | rest], type) do
    case type do
      nil ->
        infer_type(rest, {:timestamp, :microseconds, "UTC"})

      {:timestamp, _, _} = t ->
        infer_type(rest, t)

      :s64 ->
        infer_type(rest, {:timestamp, :microseconds, "UTC"})

      _ ->
        raise ArgumentError,
              "mixed types in column: got NaiveDateTime but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([%{} = map | rest], type) when not is_struct(map) do
    keys = map |> Map.keys() |> Enum.map(&to_string/1)
    keys = if length(keys) >= 32, do: Enum.sort(keys), else: keys

    case type do
      nil ->
        infer_type(rest, {:struct, keys})

      {:struct, ^keys} ->
        infer_type(rest, {:struct, keys})

      {:struct, other_keys} ->
        raise ArgumentError,
              "mixed struct keys in column: got #{inspect(keys)} but previously saw #{inspect(other_keys)}"

      _ ->
        raise ArgumentError,
              "mixed types in column: got map but previously saw #{inspect(type)}"
    end
  end

  defp infer_type([value | _rest], _type) do
    raise ArgumentError, "cannot infer type for value in column: #{inspect(value)}"
  end

  @doc """
  A column that contains booleans.

  ## Arguments

  * `data`: A list of booleans
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.boolean([true, false, true])
      iex> col.field
      %Adbc.Field{name: nil, type: :boolean}
      iex> Adbc.Column.to_list(col)
      [true, false, true]

  """
  @spec boolean([boolean()], Keyword.t()) :: t()
  def boolean(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:boolean, opts),
      data: encode_boolean(data),
      size: length(data)
    }
  end

  @doc """
  A column that contains unsigned 8-bit integers.

  ## Arguments

  * `data`: A list of unsigned 8-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u8([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u8}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u8([u8() | nil], Keyword.t()) :: t()
  def u8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u8, opts),
      data: encode_buffer(data, 8, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains unsigned 16-bit integers.

  ## Arguments

  * `data`: A list of unsigned 16-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u16([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u16}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u16([u16() | nil], Keyword.t()) :: t()
  def u16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u16, opts),
      data: encode_buffer(data, 16, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains un32-bit signed integers.

  ## Arguments

  * `data`: A list of un32-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u32([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u32}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u32([u32() | nil], Keyword.t()) :: t()
  def u32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u32, opts),
      data: encode_buffer(data, 32, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains un64-bit signed integers.

  ## Arguments

  * `data`: A list of un64-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.u64([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :u64}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec u64([u64() | nil], Keyword.t()) :: t()
  def u64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:u64, opts),
      data: encode_buffer(data, 64, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains signed 8-bit integers.

  ## Arguments

  * `data`: A list of signed 8-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s8([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s8}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s8([s8() | nil], Keyword.t()) :: t()
  def s8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s8, opts),
      data: encode_buffer(data, 8, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains signed 16-bit integers.

  ## Arguments

  * `data`: A list of signed 16-bit integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s16([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s16}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s16([s16() | nil], Keyword.t()) :: t()
  def s16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s16, opts),
      data: encode_buffer(data, 16, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains 32-bit signed integers.

  ## Arguments

  * `data`: A list of 32-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s32([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s32}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s32([s32() | nil], Keyword.t()) :: t()
  def s32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s32, opts),
      data: encode_buffer(data, 32, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains 64-bit signed integers.

  ## Arguments

  * `data`: A list of 64-bit signed integer values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.s64([1, 2, 3])
      iex> col.field
      %Adbc.Field{name: nil, type: :s64}
      iex> Adbc.Column.to_list(col)
      [1, 2, 3]

  """
  @spec s64([s64() | nil], Keyword.t()) :: t()
  def s64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:s64, opts),
      data: encode_buffer(data, 64, &encode_integer/1),
      size: length(data)
    }
  end

  @doc """
  A column that contains 16-bit half-precision floats.

  ## Arguments

  * `data`: A list of float values (will be converted to 16-bit floats in C). Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.f16([1.0, 2.0, 3.0])
      iex> col.field
      %Adbc.Field{name: nil, type: :f16}
      iex> Adbc.Column.to_list(col)
      [1.0, 2.0, 3.0]

  """
  @spec f16([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:f16, opts),
      data: encode_float(data, 16),
      size: length(data)
    }
  end

  @doc """
  A column that contains 32-bit single-precision floats.

  ## Arguments

  * `data`: A list of 32-bit single-precision float values. Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.f32([1.0, 2.0, 3.0])
      iex> col.field
      %Adbc.Field{name: nil, type: :f32}
      iex> Adbc.Column.to_list(col)
      [1.0, 2.0, 3.0]

  """
  @spec f32([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:f32, opts),
      data: encode_float(data, 32),
      size: length(data)
    }
  end

  @doc """
  A column that contains 64-bit double-precision floats.

  ## Arguments

  * `data`: A list of 64-bit double-precision float values. Integer values are automatically cast to floats.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.f64([1.0, 2.0, 3.0])
      iex> col.field
      %Adbc.Field{name: nil, type: :f64}
      iex> Adbc.Column.to_list(col)
      [1.0, 2.0, 3.0]

  """
  @spec f64([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:f64, opts),
      data: encode_float(data, 64),
      size: length(data)
    }
  end

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
  * `:metadata` - A map of metadata
  """
  @spec decimal128([Decimal.t() | integer() | nil], precision128(), integer(), Keyword.t()) ::
          t()
  def decimal128(data, precision, scale, opts \\ [])
      when is_integer(precision) and precision >= 1 and precision <= 38 do
    %Adbc.Column{
      field: Adbc.Field.new({:decimal128, precision, scale}, opts),
      data: encode_decimal(data, 128, precision, scale),
      size: length(data)
    }
  end

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
  * `:metadata` - A map of metadata
  """
  @spec decimal256([Decimal.t() | integer() | nil], precision256(), integer(), Keyword.t()) ::
          t()
  def decimal256(data, precision, scale, opts \\ [])
      when is_integer(precision) and precision >= 1 and precision <= 76 do
    %Adbc.Column{
      field: Adbc.Field.new({:decimal256, precision, scale}, opts),
      data: encode_decimal(data, 256, precision, scale),
      size: length(data)
    }
  end

  defp coef_length(0), do: 1
  defp coef_length(coef), do: coef_length(coef, 0)

  defp coef_length(0, length), do: length
  defp coef_length(coef, length), do: coef_length(Kernel.div(coef, 10), length + 1)

  defp encode_decimal(data, bitwidth, precision, scale) do
    encode_buffer(data, bitwidth, fn
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

  @doc """
  A column that contains UTF-8 encoded strings.

  ## Arguments

  * `data`: A list of UTF-8 encoded string values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.string(["a", "ab", "abc"])
      iex> col.field
      %Adbc.Field{name: nil, type: :string}
      iex> Adbc.Column.to_list(col)
      ["a", "ab", "abc"]

  """
  @spec string([String.t() | nil], Keyword.t()) :: t()
  def string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:string, opts),
      data: encode_string(data, 32),
      size: length(data)
    }
  end

  @doc """
  A column that contains UTF-8 encoded large strings.

  Similar to `string/2`, but for strings larger than 2GB.

  ## Arguments

  * `data`: A list of UTF-8 encoded string values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.large_string(["a", "ab", "abc"])
      iex> col.field
      %Adbc.Field{name: nil, type: :large_string}
      iex> Adbc.Column.to_list(col)
      ["a", "ab", "abc"]

  """
  @spec large_string([String.t() | nil], Keyword.t()) :: t()
  def large_string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:large_string, opts),
      data: encode_string(data, 64),
      size: length(data)
    }
  end

  @doc """
  A column that contains binary values.

  ## Arguments

  * `data`: A list of binary values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.binary([<<0>>, <<1>>, <<2>>])
      iex> col.field
      %Adbc.Field{name: nil, type: :binary}
      iex> Adbc.Column.to_list(col)
      [<<0>>, <<1>>, <<2>>]

  """
  @spec binary([iodata() | nil], Keyword.t()) :: t()
  def binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:binary, opts),
      data: encode_string(data, 32),
      size: length(data)
    }
  end

  @doc """
  A column that contains large binary values.

  Similar to `binary/2`, but for binary values larger than 2GB.

  ## Arguments

  * `data`: A list of binary values
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.large_binary([<<0>>, <<1>>, <<2>>])
      iex> col.field
      %Adbc.Field{name: nil, type: :large_binary}
      iex> Adbc.Column.to_list(col)
      [<<0>>, <<1>>, <<2>>]

  """
  @spec large_binary([iodata() | nil], Keyword.t()) :: t()
  def large_binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:large_binary, opts),
      data: encode_string(data, 64),
      size: length(data)
    }
  end

  @doc """
  A column that contains fixed size binaries.

  Similar to `binary/2`, but each binary value has the same fixed size in bytes.

  ## Arguments

  * `data`: A list of binary values
  * `nbytes`: The fixed size of the binary values in bytes
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata

  ## Examples

      iex> col = Adbc.Column.fixed_size_binary([<<0>>, <<1>>, <<2>>], 1)
      iex> col.field
      %Adbc.Field{name: nil, type: {:fixed_size_binary, 1}}
      iex> Adbc.Column.to_list(col)
      [<<0>>, <<1>>, <<2>>]

  """
  @spec fixed_size_binary([iodata() | nil], non_neg_integer(), Keyword.t()) :: t()
  def fixed_size_binary(data, nbytes, opts \\ [])
      when is_list(data) and is_integer(nbytes) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new({:fixed_size_binary, nbytes}, opts),
      data: encode_fixed_size_binary(data, nbytes),
      size: length(data)
    }
  end

  @doc """
  A column that contains date represented as 32-bit signed integers in UTC.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    * a `Date.t()`
    * a 32-bit signed integer representing the number of days since the Unix epoch.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata
  """
  @spec date32([Date.t() | s32() | nil], Keyword.t()) :: t()
  def date32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:date32, opts),
      data: encode_date32(data),
      size: length(data)
    }
  end

  @doc """
  A column that contains date represented as 64-bit signed integers in UTC.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    * a `Date.t()`
    * a 64-bit signed integer representing the number of milliseconds since the Unix epoch.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata
  """
  @spec date64([Date.t() | s64() | nil], Keyword.t()) :: t()
  def date64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      field: Adbc.Field.new(:date64, opts),
      data: encode_date64(data),
      size: length(data)
    }
  end

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
  * `:metadata` - A map of metadata
  """
  @spec time([Time.t() | s64() | nil], Adbc.Field.time_unit(), Keyword.t()) :: t()
  def time(data, unit, opts \\ [])

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:seconds, :milliseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:time32, unit}, opts),
      data: encode_time(data, unit, 32),
      size: length(data)
    }
  end

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:microseconds, :nanoseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:time64, unit}, opts),
      data: encode_time(data, unit, 64),
      size: length(data)
    }
  end

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
      data: encode_timestamp(data, unit),
      size: length(data)
    }
  end

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
  * `:metadata` - A map of metadata
  """
  @spec duration([s64() | nil], Adbc.Field.time_unit(), Keyword.t()) :: t()
  def duration(data, unit, opts \\ [])
      when is_list(data) and is_list(opts) and
             unit in [:seconds, :milliseconds, :microseconds, :nanoseconds] do
    %Adbc.Column{
      field: Adbc.Field.new({:duration, unit}, opts),
      data: encode_buffer(data, 64, &encode_integer/1),
      size: length(data)
    }
  end

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
      data: encode_interval(data, interval_unit),
      size: length(data)
    }
  end

  @doc """
  A column that each row is a list of some type or nil.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata
  """
  @spec list([t() | nil], Adbc.Field.t(), Keyword.t()) :: t()
  def list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:list, inner_field}, opts),
      data: encode_list(data, 32),
      size: length(data)
    }
  end

  @doc """
  Similar to `list/3`, but for large lists.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata
  """
  @spec large_list([t() | nil], Adbc.Field.t(), Keyword.t()) :: t()
  def large_list(data, %Adbc.Field{} = inner_field, opts \\ []) when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:large_list, inner_field}, opts),
      data: encode_list(data, 64),
      size: length(data)
    }
  end

  @doc """
  Similar to `list/3`, but the length of the list is the same.

  ## Arguments

  * `data`: a list of lists (or `nil` for null rows)
  * `inner_field`: an `Adbc.Field` describing the type of the list elements
  * `fixed_size`: The fixed size of the list.
  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:metadata` - A map of metadata
  """
  @spec fixed_size_list(list(), Adbc.Field.t(), s32(), Keyword.t()) :: t()
  def fixed_size_list(data, %Adbc.Field{} = inner_field, fixed_size, opts \\ [])
      when is_list(data) do
    %Adbc.Column{
      field: Adbc.Field.new({:fixed_size_list, inner_field, fixed_size}, opts),
      data: data
    }
  end

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
  Adbc.Column.string(["foo", "bar", "foo", "bar", nil, "baz"])
  ```

  In dictionary-encoded form, this could appear as:

  ```elixir
  Adbc.Column.dictionary(
    Adbc.Column.string(["foo", "bar", "baz"]),
    Adbc.Column.s32([0, 1, 0, 1, nil, 2])
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
      data: %Adbc.DictionaryData{key: key.data, value: value.data},
      size: key.size
    }
  end

  defp encode_list(data, offset_size) do
    {offsets, values, bitmap, bit_offset} =
      encode_offset(data, offset_size, fn %Adbc.Column{data: data, size: size} -> {data, size} end)

    # While values is a single array in Arrow,
    # we keep it as a list so we concat buffers in C
    %Adbc.ListData{offsets: offsets, validity: bitmap, values: values, bit_offset: bit_offset}
  end

  defp encode_boolean(data) do
    encode_boolean(data, 0, <<>>, 0, 0, <<>>, 0)
  end

  defp encode_boolean([], count, data, byte, bits, bitmap, validity_pending) do
    {_data, validity, bit_offset} = bitmap_finish(<<>>, bitmap, validity_pending)
    data = if bits > 0, do: <<data::binary, byte>>, else: data
    %Adbc.BooleanData{data: data, validity: validity, bit_offset: bit_offset, size: count}
  end

  defp encode_boolean([nil | rest], count, data, byte, bits, bitmap, validity_pending) do
    {bitmap, validity_pending} = bitmap_mark_null(bitmap, validity_pending)
    {data, byte, bits} = boolean_put_bit(data, byte, bits, 0)
    encode_boolean(rest, count + 1, data, byte, bits, bitmap, validity_pending)
  end

  defp encode_boolean([bool | rest], count, data, byte, bits, bitmap, validity_pending)
       when is_boolean(bool) do
    {bitmap, validity_pending} = bitmap_mark_valid(bitmap, validity_pending)
    bit = if bool == true, do: 1, else: 0
    {data, byte, bits} = boolean_put_bit(data, byte, bits, bit)
    encode_boolean(rest, count + 1, data, byte, bits, bitmap, validity_pending)
  end

  defp boolean_put_bit(data, byte, 7, bit), do: {<<data::binary, byte ||| bit <<< 7>>, 0, 0}
  defp boolean_put_bit(data, byte, bits, bit), do: {data, byte ||| bit <<< bits, bits + 1}

  @float_nan %{16 => 0x7E00, 32 => 0x7FC00000, 64 => 0x7FF8000000000000}
  @float_infinity %{16 => 0x7C00, 32 => 0x7F800000, 64 => 0x7FF0000000000000}
  @float_neg_infinity %{16 => 0xFC00, 32 => 0xFF800000, 64 => 0xFFF0000000000000}

  defp encode_float(data, size) do
    encode_float(data, size, <<>>, <<>>, 0)
  end

  defp encode_float([], _size, data, bitmap, pending) do
    {_data, validity, bit_offset} = bitmap_finish(<<>>, bitmap, pending)
    %Adbc.BufferData{data: data, validity: validity, bit_offset: bit_offset}
  end

  defp encode_float([nil | rest], size, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_float(rest, size, <<data::binary, 0::size(size)>>, bitmap, pending)
  end

  defp encode_float([:nan | rest], size, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, Map.fetch!(@float_nan, size)::integer-native-size(size)>>
    encode_float(rest, size, data, bitmap, pending)
  end

  defp encode_float([:infinity | rest], size, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, Map.fetch!(@float_infinity, size)::integer-native-size(size)>>
    encode_float(rest, size, data, bitmap, pending)
  end

  defp encode_float([:neg_infinity | rest], size, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, Map.fetch!(@float_neg_infinity, size)::integer-native-size(size)>>
    encode_float(rest, size, data, bitmap, pending)
  end

  defp encode_float([value | rest], size, data, bitmap, pending) when is_number(value) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    encode_float(rest, size, <<data::binary, value::float-native-size(size)>>, bitmap, pending)
  end

  defp encode_fixed_size_binary(data, nbytes) do
    encode_fixed_size_binary(data, nbytes, <<>>, <<>>, 0)
  end

  defp encode_fixed_size_binary([], _nbytes, data, bitmap, pending) do
    {_data, validity, bit_offset} = bitmap_finish(<<>>, bitmap, pending)
    %Adbc.BufferData{data: data, validity: validity, bit_offset: bit_offset}
  end

  defp encode_fixed_size_binary([nil | rest], nbytes, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_fixed_size_binary(rest, nbytes, <<data::binary, 0::size(nbytes * 8)>>, bitmap, pending)
  end

  defp encode_fixed_size_binary([value | rest], nbytes, data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    binary = IO.iodata_to_binary(value)
    encode_fixed_size_binary(rest, nbytes, <<data::binary, binary::binary>>, bitmap, pending)
  end

  defp encode_string(data, offset_size) do
    {offsets, values, bitmap, bit_offset} =
      encode_offset(data, offset_size, fn value -> {value, byte_size(value)} end)

    %Adbc.BinaryData{
      offsets: offsets,
      data: IO.iodata_to_binary(values),
      validity: bitmap,
      bit_offset: bit_offset
    }
  end

  defp encode_offset(data, offset_size, encoder) do
    encode_offset(data, [], <<0::size(offset_size)>>, <<>>, 0, 0, offset_size, encoder)
  end

  defp encode_offset([], acc, offsets, bitmap, pending, _offset, _offset_size, _encoder) do
    {_data, bitmap, bit_offset} = bitmap_finish(<<>>, bitmap, pending)
    {offsets, Enum.reverse(acc), bitmap, bit_offset}
  end

  defp encode_offset([nil | rest], acc, offsets, bitmap, pending, offset, offset_size, encoder) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    offsets = <<offsets::binary, offset::signed-integer-native-size(offset_size)>>
    encode_offset(rest, acc, offsets, bitmap, pending, offset, offset_size, encoder)
  end

  defp encode_offset([value | rest], acc, offsets, bitmap, pending, offset, offset_size, encoder) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    {data, size} = encoder.(value)
    offset = offset + size
    offsets = <<offsets::binary, offset::signed-integer-native-size(offset_size)>>
    encode_offset(rest, [data | acc], offsets, bitmap, pending, offset, offset_size, encoder)
  end

  defp encode_date32(data) do
    encode_buffer(data, 32, fn
      %Date{} = date -> Date.to_gregorian_days(date) - @epoch_days
      integer when is_integer(integer) -> integer
    end)
  end

  defp encode_date64(data) do
    encode_buffer(data, 64, fn
      %Date{} = date -> (Date.to_gregorian_days(date) - @epoch_days) * 86_400_000
      integer when is_integer(integer) -> integer
    end)
  end

  defp encode_time(data, unit, bitwidth) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)

    encode_buffer(data, bitwidth, fn
      %Time{} = time ->
        {seconds, microseconds} = Time.to_seconds_after_midnight(time)
        seconds * multiplier + microseconds * div(multiplier, 1_000_000)

      integer when is_integer(integer) ->
        integer
    end)
  end

  defp encode_timestamp(data, unit) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)

    encode_buffer(data, 64, fn
      %NaiveDateTime{} = ndt ->
        {gregorian_seconds, microseconds} = NaiveDateTime.to_gregorian_seconds(ndt)
        unix_seconds = gregorian_seconds - @epoch_seconds
        unix_seconds * multiplier + microseconds * div(multiplier, 1_000_000)

      integer when is_integer(integer) ->
        integer
    end)
  end

  defp encode_struct(keys, data, opts) do
    {per_key_values, validity, bit_offset} =
      Enum.reduce(data, {Map.new(keys, fn k -> {k, []} end), <<>>, 0}, fn
        nil, {cols, bitmap, pending} ->
          cols = Map.new(cols, fn {k, vs} -> {k, [nil | vs]} end)
          {bitmap, pending} = bitmap_mark_null(bitmap, pending)
          {cols, bitmap, pending}

        %{} = row, {cols, bitmap, pending} ->
          cols = Map.new(cols, fn {k, vs} -> {k, [Map.get(row, k) | vs]} end)
          {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
          {cols, bitmap, pending}
      end)

    {_data, validity, bit_offset} = bitmap_finish(<<>>, validity, bit_offset)

    children =
      Enum.map(keys, fn key ->
        values = per_key_values |> Map.fetch!(key) |> Enum.reverse()
        new(values, name: key)
      end)

    child_fields = Enum.map(children, & &1.field)
    child_data = Enum.map(children, & &1.data)

    %Adbc.Column{
      field: %Adbc.Field{
        name: opts[:name],
        type: {:struct, child_fields}
      },
      data: %Adbc.StructData{validity: validity, bit_offset: bit_offset, values: child_data},
      size: length(data)
    }
  end

  defp encode_integer(integer) when is_integer(integer), do: integer

  defp encode_interval(data, :month) do
    encode_buffer(data, 32, &encode_integer/1)
  end

  defp encode_interval(data, :day_time) do
    encode_interval_day_time(data, <<>>, <<>>, 0)
  end

  defp encode_interval(data, :month_day_nano) do
    encode_interval_month_day_nano(data, <<>>, <<>>, 0)
  end

  ## Bit encoding

  # Single-pass encoding of a data list into {binary, bitmap | nil, offset}.
  # `encoder` converts each non-nil element to an integer.
  # `pending` tracks bitmap state:
  #   - integer N: postponed valid bits, no partial byte in progress
  #   - {byte, bits}: partial byte being built LSB-first, bits is 1-7
  # `bitmap` is passed explicitly for Erlang binary append optimization.

  defp encode_buffer(list, size, encoder) do
    encode_buffer(list, <<>>, <<>>, 0, size, encoder)
  end

  defp encode_buffer([], data, bitmap, pending, _size, _encoder) do
    {data, validity, bit_offset} = bitmap_finish(data, bitmap, pending)
    %Adbc.BufferData{data: data, validity: validity, bit_offset: bit_offset}
  end

  defp encode_buffer([nil | rest], data, bitmap, pending, size, encoder) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_buffer(rest, <<data::binary, 0::size(size)>>, bitmap, pending, size, encoder)
  end

  defp encode_buffer([value | rest], data, bitmap, pending, size, encoder) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, encoder.(value)::signed-integer-native-size(size)>>
    encode_buffer(rest, data, bitmap, pending, size, encoder)
  end

  ## Interval encoding (custom multi-field binary, avoids big integer arithmetic)

  defp encode_interval_day_time([], data, bitmap, pending) do
    {data, validity, bit_offset} = bitmap_finish(data, bitmap, pending)
    %Adbc.BufferData{data: data, validity: validity, bit_offset: bit_offset}
  end

  defp encode_interval_day_time([nil | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_interval_day_time(rest, <<data::binary, 0::64>>, bitmap, pending)
  end

  defp encode_interval_day_time([{days, ms} | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)
    data = <<data::binary, days::signed-integer-native-32, ms::signed-integer-native-32>>
    encode_interval_day_time(rest, data, bitmap, pending)
  end

  defp encode_interval_month_day_nano([], data, bitmap, pending) do
    {data, validity, bit_offset} = bitmap_finish(data, bitmap, pending)
    %Adbc.BufferData{data: data, validity: validity, bit_offset: bit_offset}
  end

  defp encode_interval_month_day_nano([nil | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_null(bitmap, pending)
    encode_interval_month_day_nano(rest, <<data::binary, 0::128>>, bitmap, pending)
  end

  defp encode_interval_month_day_nano([{months, days, ns} | rest], data, bitmap, pending) do
    {bitmap, pending} = bitmap_mark_valid(bitmap, pending)

    data =
      <<data::binary, months::signed-integer-native-32, days::signed-integer-native-32,
        ns::signed-integer-native-64>>

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

  @doc """
  Returns whether the column contains a validity bitmap (which would
  indicate the presence of nils).

  """
  @spec has_validity?(t()) :: boolean()
  def has_validity?(%Adbc.Column{
        field: %{type: {:dictionary, key_field, value_field}},
        data: %Adbc.DictionaryData{key: key, value: value}
      }) do
    has_validity?(%Adbc.Column{field: key_field, data: key}) or
      has_validity?(%Adbc.Column{field: value_field, data: value})
  end

  def has_validity?(%Adbc.Column{data: %Adbc.RunEndEncodedData{values: %{validity: validity}}}) do
    validity != nil
  end

  def has_validity?(%Adbc.Column{data: %{validity: validity}}) do
    validity != nil
  end

  def has_validity?(%Adbc.Column{data: data}) when is_list(data) do
    nil in data
  end

  @doc """
  Returns the column's data as a raw binary.

  Supported types and their binary formats:

    * `:s8` / `:u8` / `:s16` / `:u16` / `:s32` / `:u32` / `:s64` / `:u64`
    * `:f16` / `:f32` / `:f64`
    * `:date32` - equivalent to `:s32`
    * `:date64` - equivalent to `:s64`
    * `{:time32, unit}` - equivalent to `:s32`
    * `{:time64, unit}` - equivalent to `:s64`
    * `{:timestamp, unit, tz}` - equivalent to `:s64`
    * `{:duration, unit}` - equivalent to `:s64`
    * `{:interval, :month}` - equivalent to `:s32`
    * `{:interval, :day_time}` - two `:s32` values per element (days, milliseconds)
    * `{:interval, :month_day_nano}` - `:s32` + `:s32` + `:s64` per element (months, days, nanoseconds)
    * `{:decimal128, precision, scale}` - 128-bit signed little-endian two's complement
    * `{:decimal256, precision, scale}` - 256-bit signed little-endian two's complement
    * `{:fixed_size_binary, n}` - `n` raw bytes per element
    * `{:dictionary, key_type, _}` - returns the key binary in the key's format

  Raises `ArgumentError` for other data types.
  """
  @spec to_binary(t()) :: binary()
  def to_binary(column)

  def to_binary(%Adbc.Column{data: %Adbc.BufferData{data: binary}}), do: binary

  def to_binary(%Adbc.Column{data: %Adbc.DictionaryData{key: %Adbc.BufferData{data: binary}}}),
    do: binary

  def to_binary(%Adbc.Column{field: field}) do
    raise ArgumentError,
          "cannot convert column #{inspect(field.name)} of type #{inspect(field.type)} to binary"
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
  def to_list(column)

  def to_list(%Adbc.Column{
        field: %{type: {:dictionary, key_field, value_field}},
        data: %Adbc.DictionaryData{key: key_data, value: value_data}
      }) do
    value_list = to_list(%Adbc.Column{field: value_field, data: value_data})
    decoder = &Enum.at(value_list, &1)
    %Adbc.BufferData{data: binary, validity: validity, bit_offset: bit_offset} = key_data

    case key_field.type do
      :s8 -> decode_signed_8(binary, validity, bit_offset, 0, decoder)
      :s16 -> decode_signed_16(binary, validity, bit_offset, 0, decoder)
      :s32 -> decode_signed_32(binary, validity, bit_offset, 0, decoder)
      :s64 -> decode_signed_64(binary, validity, bit_offset, 0, decoder)
      :u8 -> decode_unsigned_8(binary, validity, bit_offset, 0, decoder)
      :u16 -> decode_unsigned_16(binary, validity, bit_offset, 0, decoder)
      :u32 -> decode_unsigned_32(binary, validity, bit_offset, 0, decoder)
      :u64 -> decode_unsigned_64(binary, validity, bit_offset, 0, decoder)
    end
  end

  def to_list(%Adbc.Column{
        field: %{type: {:run_end_encoded, run_ends_field, values_field}},
        data: %Adbc.RunEndEncodedData{} = batch
      }) do
    values = to_list(%Adbc.Column{field: values_field, data: batch.values})
    run_ends = to_list(%Adbc.Column{field: run_ends_field, data: batch.run_ends})
    decode_runs(run_ends, values, batch.offset, batch.offset + batch.length)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:list_view, inner_field}},
        data: %Adbc.ListViewData{} = batch
      }) do
    values = to_list(%Adbc.Column{field: inner_field, data: batch.values})
    decode_list_view_32(batch.offsets, batch.sizes, batch.validity, batch.bit_offset, values, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:large_list_view, inner_field}},
        data: %Adbc.ListViewData{} = batch
      }) do
    values = to_list(%Adbc.Column{field: inner_field, data: batch.values})
    decode_list_view_64(batch.offsets, batch.sizes, batch.validity, batch.bit_offset, values, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:struct, fields}},
        data: %Adbc.StructData{validity: validity, bit_offset: bit_offset, values: values}
      }) do
    columns =
      Enum.zip_with(fields, values, fn field, col_data ->
        %Adbc.Column{field: field, data: col_data}
      end)

    rows = Table.to_rows(%Adbc.Result{data: [columns], num_rows: nil})

    if validity do
      rows
      |> Enum.map_reduce(0, fn value, index ->
        value = if bitmap_valid?(validity, index, bit_offset), do: value
        {value, index + 1}
      end)
      |> elem(0)
    else
      Enum.to_list(rows)
    end
  end

  def to_list(%Adbc.Column{
        field: %{type: {:map, key_field, value_field}},
        data: %Adbc.MapData{} = batch
      }) do
    keys = to_list(%Adbc.Column{field: key_field, data: batch.keys})
    values = to_list(%Adbc.Column{field: value_field, data: batch.values})
    <<first::signed-integer-native-32, rest::binary>> = batch.offsets
    decode_map_32(rest, batch.validity, batch.bit_offset, keys, values, first, 0)
  end

  def to_list(%Adbc.Column{field: %{type: {:list, inner_field}}, data: %Adbc.ListData{} = batch}) do
    values = Enum.flat_map(batch.values, &to_list(%Adbc.Column{field: inner_field, data: &1}))
    <<first::signed-integer-native-32, rest::binary>> = batch.offsets
    decode_list_32(rest, batch.validity, batch.bit_offset, values, first, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:large_list, inner_field}},
        data: %Adbc.ListData{} = batch
      }) do
    values = Enum.flat_map(batch.values, &to_list(%Adbc.Column{field: inner_field, data: &1}))
    <<first::signed-integer-native-64, rest::binary>> = batch.offsets
    decode_list_64(rest, batch.validity, batch.bit_offset, values, first, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:fixed_size_list, inner_field, fixed_size}},
        data: %Adbc.ListData{} = batch
      }) do
    values = Enum.flat_map(batch.values, &to_list(%Adbc.Column{field: inner_field, data: &1}))
    decode_fixed_size_list(values, batch.validity, batch.bit_offset, fixed_size, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: :date32},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_32(binary, bitmap, bit_offset, &days_to_date/1)
  end

  def to_list(%Adbc.Column{
        field: %{type: :date64},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_64(binary, bitmap, bit_offset, &milliseconds_to_date/1)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:time32, unit}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_32(binary, bitmap, bit_offset, &int_to_time(&1, unit))
  end

  def to_list(%Adbc.Column{
        field: %{type: {:time64, unit}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_64(binary, bitmap, bit_offset, &int_to_time(&1, unit))
  end

  def to_list(%Adbc.Column{
        field: %{type: {:timestamp, unit, _timezone}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_64(binary, bitmap, bit_offset, &int_to_naive_datetime(&1, unit))
  end

  def to_list(%Adbc.Column{
        field: %{type: {:duration, _unit}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_64(binary, bitmap, bit_offset, &Function.identity/1)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:interval, :month}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_32(binary, bitmap, bit_offset, &Function.identity/1)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:interval, :day_time}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_interval_day_time(binary, bitmap, bit_offset)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:interval, :month_day_nano}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_interval_month_day_nano(binary, bitmap, bit_offset)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:decimal128, _, scale}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_128(binary, bitmap, bit_offset, &coef_to_decimal(&1, scale))
  end

  def to_list(%Adbc.Column{
        field: %{type: {:decimal256, _, scale}},
        data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
      }) do
    decode_signed_256(binary, bitmap, bit_offset, &coef_to_decimal(&1, scale))
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
    def to_list(%Adbc.Column{
          field: %{type: unquote(type)},
          data: %Adbc.BufferData{data: binary, validity: bitmap, bit_offset: bit_offset}
        }) do
      unquote(decode_fun)(binary, bitmap, bit_offset, &Function.identity/1)
    end
  end

  def to_list(%Adbc.Column{field: %{type: :f16}, data: %Adbc.BufferData{} = buffer}) do
    decode_float_16(buffer.data, buffer.validity, buffer.bit_offset, 0)
  end

  def to_list(%Adbc.Column{field: %{type: :f32}, data: %Adbc.BufferData{} = buffer}) do
    decode_float_32(buffer.data, buffer.validity, buffer.bit_offset, 0)
  end

  def to_list(%Adbc.Column{field: %{type: :f64}, data: %Adbc.BufferData{} = buffer}) do
    decode_float_64(buffer.data, buffer.validity, buffer.bit_offset, 0)
  end

  def to_list(%Adbc.Column{
        field: %{type: {:fixed_size_binary, nbytes}},
        data: %Adbc.BufferData{} = buffer
      }) do
    decode_fixed_size_binary(buffer.data, buffer.validity, buffer.bit_offset, nbytes, 0)
  end

  def to_list(%Adbc.Column{field: %{type: :boolean}, data: %Adbc.BooleanData{} = buffer}) do
    decode_boolean(buffer.data, buffer.validity, buffer.bit_offset, buffer.size, 0)
  end

  def to_list(%Adbc.Column{field: %{type: type}, data: %Adbc.BinaryData{} = binary_data})
      when type in [:string, :binary] do
    decode_string_32(
      binary_data.offsets,
      binary_data.data,
      binary_data.validity,
      binary_data.bit_offset
    )
  end

  def to_list(%Adbc.Column{field: %{type: type}, data: %Adbc.BinaryData{} = binary_data})
      when type in [:large_string, :large_binary] do
    decode_string_64(
      binary_data.offsets,
      binary_data.data,
      binary_data.validity,
      binary_data.bit_offset
    )
  end

  def to_list(%Adbc.Column{field: %{type: type}, data: data})
      when type in [:string_view, :binary_view] do
    data
  end

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

  defp days_to_date(days), do: Date.from_gregorian_days(days + @epoch_days)
  defp milliseconds_to_date(ms), do: Date.from_gregorian_days(div(ms, 86_400_000) + @epoch_days)

  defp int_to_time(val, unit) do
    multiplier = Map.fetch!(@time_unit_multiplier, unit)
    total_us = div(val * 1_000_000, multiplier)
    seconds = div(total_us, 1_000_000)
    microseconds = rem(total_us, 1_000_000)
    Time.add(~T[00:00:00], seconds * 1_000_000 + microseconds, :microsecond)
  end

  defp decode_runs([run_end | run_ends], [_ | values], pos, stop)
       when run_end <= pos do
    decode_runs(run_ends, values, pos, stop)
  end

  defp decode_runs([run_end | run_ends], [value | values], pos, stop) do
    duplicate_runs(value, min(run_end, stop) - pos, run_ends, values, min(run_end, stop), stop)
  end

  defp decode_runs(_, _, _, _), do: []

  defp duplicate_runs(_value, 0, run_ends, values, pos, stop) do
    decode_runs(run_ends, values, pos, stop)
  end

  defp duplicate_runs(value, n, run_ends, values, pos, stop) do
    [value | duplicate_runs(value, n - 1, run_ends, values, pos, stop)]
  end

  defp decode_fixed_size_list([], _validity, _bit_offset, _fixed_size, _index) do
    []
  end

  defp decode_fixed_size_list(values, validity, bit_offset, fixed_size, index) do
    {chunk, rest} = Enum.split(values, fixed_size)
    element = if bitmap_valid?(validity, index, bit_offset), do: chunk
    [element | decode_fixed_size_list(rest, validity, bit_offset, fixed_size, index + 1)]
  end

  defp decode_fixed_size_binary(<<>>, _validity, _bit_offset, _nbytes, _index), do: []

  defp decode_fixed_size_binary(data, validity, bit_offset, nbytes, index) do
    <<chunk::binary-size(nbytes), rest::binary>> = data
    value = if bitmap_valid?(validity, index, bit_offset), do: chunk
    [value | decode_fixed_size_binary(rest, validity, bit_offset, nbytes, index + 1)]
  end

  defp decode_interval_day_time(binary, validity, offset) do
    decode_interval_day_time(binary, validity, offset, 0)
  end

  defp decode_interval_day_time(
         <<days::signed-integer-native-32, ms::signed-integer-native-32, rest::binary>>,
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
         <<months::signed-integer-native-32, days::signed-integer-native-32,
           ns::signed-integer-native-64, rest::binary>>,
         validity,
         offset,
         index
       ) do
    value = if bitmap_valid?(validity, index, offset), do: {months, days, ns}
    [value | decode_interval_month_day_nano(rest, validity, offset, index + 1)]
  end

  defp decode_interval_month_day_nano(<<>>, _validity, _offset, _index), do: []

  # Float decoding with non-finite value detection

  for {name, size, infinity, neg_infinity} <- [
        {:decode_float_16, 16, 0x7C00, 0xFC00},
        {:decode_float_32, 32, 0x7F800000, 0xFF800000},
        {:decode_float_64, 64, 0x7FF0000000000000, 0xFFF0000000000000}
      ] do
    defp unquote(name)(<<>>, _validity, _bit_offset, _index), do: []

    defp unquote(name)(
           <<n::float-native-size(unquote(size)), rest::binary>>,
           validity,
           bit_offset,
           index
         ) do
      value = if bitmap_valid?(validity, index, bit_offset), do: n
      [value | unquote(name)(rest, validity, bit_offset, index + 1)]
    end

    defp unquote(name)(
           <<unquote(infinity)::unsigned-integer-native-size(unquote(size)), rest::binary>>,
           validity,
           bit_offset,
           index
         ) do
      value = if bitmap_valid?(validity, index, bit_offset), do: :infinity
      [value | unquote(name)(rest, validity, bit_offset, index + 1)]
    end

    defp unquote(name)(
           <<unquote(neg_infinity)::unsigned-integer-native-size(unquote(size)), rest::binary>>,
           validity,
           bit_offset,
           index
         ) do
      value = if bitmap_valid?(validity, index, bit_offset), do: :neg_infinity
      [value | unquote(name)(rest, validity, bit_offset, index + 1)]
    end

    # NaN: float match above fails for NaN, so this catch-all handles it
    defp unquote(name)(
           <<_::unsigned-integer-native-size(unquote(size)), rest::binary>>,
           validity,
           bit_offset,
           index
         ) do
      value = if bitmap_valid?(validity, index, bit_offset), do: :nan
      [value | unquote(name)(rest, validity, bit_offset, index + 1)]
    end
  end

  defp decode_map_32(<<>>, _validity, _bit_offset, _keys, _values, _prev, _index), do: []

  defp decode_map_32(
         <<next::signed-integer-little-32, rest::binary>>,
         validity,
         bit_offset,
         keys,
         values,
         prev,
         index
       ) do
    size = next - prev
    {pairs, keys, values} = split_and_zip(keys, values, size, [])

    element =
      if bitmap_valid?(validity, index, bit_offset),
        do: Map.new(pairs)

    [element | decode_map_32(rest, validity, bit_offset, keys, values, next, index + 1)]
  end

  defp split_and_zip(keys, values, 0, acc), do: {acc, keys, values}

  defp split_and_zip([k | keys], [v | values], n, acc),
    do: split_and_zip(keys, values, n - 1, [{k, v} | acc])

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
        decode_list_view_32: quote(do: signed - integer - little - 32),
        decode_list_view_64: quote(do: signed - integer - little - 64)
      ] do
    defp unquote(name)(<<>>, <<>>, _validity, _bit_offset, _values, _index) do
      []
    end

    defp unquote(name)(
           <<offset::unquote(specifier), offsets_rest::binary>>,
           <<size::unquote(specifier), sizes_rest::binary>>,
           validity,
           bit_offset,
           values,
           index
         ) do
      element =
        if bitmap_valid?(validity, index, bit_offset),
          do: Enum.slice(values, offset, size)

      [element | unquote(name)(offsets_rest, sizes_rest, validity, bit_offset, values, index + 1)]
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

  for {name, offset_specifier} <- [
        decode_string_32: quote(do: signed - integer - little - 32),
        decode_string_64: quote(do: signed - integer - little - 64)
      ] do
    defp unquote(name)(offsets, data, validity, bit_offset) do
      <<first::unquote(offset_specifier), rest::binary>> = offsets
      unquote(name)(rest, data, validity, bit_offset, first, 0)
    end

    defp unquote(name)(
           <<next::unquote(offset_specifier), rest::binary>>,
           data,
           validity,
           bit_offset,
           prev,
           index
         ) do
      value =
        if bitmap_valid?(validity, index, bit_offset), do: binary_part(data, prev, next - prev)

      [value | unquote(name)(rest, data, validity, bit_offset, next, index + 1)]
    end

    defp unquote(name)(<<>>, _data, _validity, _bit_offset, _prev, _index), do: []
  end

  defp decode_boolean(_data, _validity, _bit_offset, count, index) when index >= count, do: []

  defp decode_boolean(data, validity, bit_offset, count, index) do
    value =
      if bitmap_valid?(validity, index, bit_offset) do
        bit_pos = index + bit_offset
        byte = :binary.at(data, div(bit_pos, 8))
        (byte &&& 1 <<< rem(bit_pos, 8)) != 0
      end

    [value | decode_boolean(data, validity, bit_offset, count, index + 1)]
  end

  @compile {:inline, bitmap_valid?: 3}
  defp bitmap_valid?(nil, _index, _bit_offset), do: true

  defp bitmap_valid?(validity, index, bit_offset) do
    bit_pos = index + bit_offset
    byte = :binary.at(validity, div(bit_pos, 8))
    (byte &&& 1 <<< rem(bit_pos, 8)) != 0
  end
end

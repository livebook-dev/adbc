defmodule Adbc.Column do
  @moduledoc """
  Represents columns in the table.

  It contains the column's name, type, and data.
  The data is a list of values of the column's data type.

  You can create new columns using `new/2`, which will infer
  a base type if none is given, and detect if the columns are
  nullable or not.

  The other functions in this module, such as `s8`, `boolean`,
  etc, are meant to be low-level functions which expect all
  relevant data to be given. For example, they won't automatically
  detect nullable, you must explicitly provide said value as argument.
  """
  @enforce_keys [:name, :type, :nullable]
  defstruct [:name, :type, :nullable, :metadata, :data, :length, :offset]

  @type t :: %Adbc.Column{}

  import Bitwise

  @type s8 :: -128..127
  @type u8 :: 0..255
  @type s16 :: -32768..32767
  @type u16 :: 0..65535
  @type s32 :: -2_147_483_648..2_147_483_647
  @type u32 :: 0..4_294_967_295
  @type s64 :: -9_223_372_036_854_775_808..9_223_372_036_854_775_807
  @type u64 :: 0..18_446_744_073_709_551_615
  @type signed_integer ::
          :s8
          | :s16
          | :s32
          | :s64
  @type unsigned_integer ::
          :u8
          | :u16
          | :u32
          | :u64
  @type floating ::
          :f32
          | :f64
  @type precision128 :: 1..38
  @type precision256 :: 1..76
  @type decimal128 :: {:decimal, 128, precision128(), integer()}
  @type decimal256 :: {:decimal, 256, precision256(), integer()}
  @type decimal ::
          decimal128
          | decimal256
  @type time_unit ::
          :seconds
          | :milliseconds
          | :microseconds
          | :nanoseconds
  @type time32 ::
          {:time32, :seconds}
          | {:time32, :milliseconds}
  @type time64 ::
          {:time64, :microseconds}
          | {:time64, :nanoseconds}
  @type time :: time32() | time64()
  @type timestamp ::
          {:timestamp, :seconds, String.t()}
          | {:timestamp, :milliseconds, String.t()}
          | {:timestamp, :microseconds, String.t()}
          | {:timestamp, :nanoseconds, String.t()}
  @type duration ::
          {:duration, :seconds}
          | {:duration, :milliseconds}
          | {:duration, :microseconds}
          | {:duration, :nanoseconds}
  @type interval_month :: s32()
  @type interval_day_xime :: {s32(), s32()}
  @type interval_month_day_nano :: {s32(), s32(), s64()}
  @type interval_unit ::
          :month
          | :day_time
          | :month_day_nano
  @type interval ::
          {:interval, :month}
          | {:interval, :day_time}
          | {:interval, :month_day_nano}
  @list_view_types [
    :list_view,
    :large_list_view
  ]
  @type list_view_data :: %{
          validity: [boolean()],
          offsets: [non_neg_integer()],
          sizes: [non_neg_integer()],
          values: t()
        }
  @valid_run_end_types [:s16, :s32, :s64]
  @type dictionary_data :: %{
          key: t(),
          value: t()
        }
  @type data_type ::
          :boolean
          | signed_integer
          | unsigned_integer
          | floating
          | :list
          | :large_list
          | :list_view
          | :large_list_view
          | {:fixed_size_list, s32()}
          | :binary
          | :large_binary
          | :binary_view
          | :string
          | :large_string
          | :string_view
          | decimal
          | {:fixed_size_binary, non_neg_integer()}
          | {:struct, t()}
          | :date32
          | :date64
          | time
          | timestamp
          | duration
          | interval
          | :run_end_encoded
          | :dictionary

  @spec get_metadata(t(), String.t(), String.t() | nil) :: String.t() | nil
  def get_metadata(%Adbc.Column{metadata: metadata}, key, default \\ nil)
      when is_binary(key) or is_atom(key) do
    metadata[to_string(key)] || default
  end

  @spec put_metadata(t(), String.t(), String.t()) :: t()
  def put_metadata(buffer = %Adbc.Column{metadata: metadata}, key, value)
      when (is_binary(key) or is_atom(key)) and (is_binary(value) or is_atom(value)) do
    %{buffer | metadata: Map.put(metadata, to_string(key), to_string(value))}
  end

  @spec delete_metadata(t(), String.t()) :: t()
  def delete_metadata(buffer = %Adbc.Column{metadata: metadata}, key)
      when is_binary(key) or is_atom(key) do
    %{buffer | metadata: Map.delete(metadata, to_string(key))}
  end

  @spec delete_all_metadata(t()) :: t()
  def delete_all_metadata(buffer = %Adbc.Column{}) do
    %{buffer | metadata: %{}}
  end

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
        name: "ids",
        type: :s64,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

      iex> Adbc.Column.new([1, nil, 3.0])
      %Adbc.Column{
        name: nil,
        type: :f64,
        nullable: true,
        metadata: nil,
        data: [1, nil, 3.0]
      }

      iex> Adbc.Column.new([1, 2, 3], type: :u32)
      %Adbc.Column{
        name: nil,
        type: :u32,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
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
      name: opts[:name],
      type: type,
      nullable: nullable,
      metadata: nil,
      data: data
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

  @doc type: :column_type
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
        name: nil,
        type: :boolean,
        nullable: false,
        metadata: nil,
        data: [true, false, true]
      }

  """
  @spec boolean([boolean()], Keyword.t()) :: t()
  def boolean(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :boolean,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :u8,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec u8([u8() | nil], Keyword.t()) :: t()
  def u8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :u8,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :u16,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec u16([u16() | nil], Keyword.t()) :: t()
  def u16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :u16,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :u32,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec u32([u32() | nil], Keyword.t()) :: t()
  def u32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :u32,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :u32,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec u64([u64() | nil], Keyword.t()) :: t()
  def u64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :u64,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :s8,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec s8([s8() | nil], Keyword.t()) :: t()
  def s8(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :s8,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :s16,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec s16([s16() | nil], Keyword.t()) :: t()
  def s16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :s16,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :s32,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec s32([s32() | nil], Keyword.t()) :: t()
  def s32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :s32,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :s64,
        nullable: false,
        metadata: nil,
        data: [1, 2, 3]
      }

  """
  @spec s64([s64() | nil], Keyword.t()) :: t()
  def s64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :s64,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :f16,
        nullable: false,
        metadata: nil,
        data: [1.0, 2.0, 3.0]
      }

  """
  @spec f16([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f16(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :f16,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :f32,
        nullable: false,
        metadata: nil,
        data: [1.0, 2.0, 3.0]
      }

  """
  @spec f32([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f32(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :f32,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :f64,
        nullable: false,
        metadata: nil,
        data: [1.0, 2.0, 3.0]
      }

  """
  @spec f64([integer | float | nil | :infinity | :neg_infinity | :nan], Keyword.t()) :: t()
  def f64(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :f64,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
      name: opts[:name],
      type: {:decimal, bitwidth, precision, scale},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: preprocess_decimal(bitwidth, precision, scale, data, [])
    }
  end

  @doc type: :column_type
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
      name: opts[:name],
      type: {:decimal, bitwidth, precision, scale},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: preprocess_decimal(bitwidth, precision, scale, data, [])
    }
  end

  defp coef_length(0), do: 1
  defp coef_length(coef), do: coef_length(coef, 0)

  defp coef_length(0, length), do: length
  defp coef_length(coef, length), do: coef_length(Kernel.div(coef, 10), length + 1)

  defp preprocess_decimal(_bitwidth, _precision, _scale, [], acc), do: Enum.reverse(acc)

  defp preprocess_decimal(bitwidth, precision, scale, [nil | rest], acc) do
    preprocess_decimal(bitwidth, precision, scale, rest, [nil | acc])
  end

  defp preprocess_decimal(bitwidth, precision, scale, [integer | rest], acc)
       when is_integer(integer) do
    if coef_length(integer) > precision do
      raise Adbc.Error,
            "`#{Integer.to_string(integer)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"
    else
      coef = trunc(integer * :math.pow(10, scale))
      acc = [<<coef::signed-integer-little-size(bitwidth)>> | acc]
      preprocess_decimal(bitwidth, precision, scale, rest, acc)
    end
  end

  defp preprocess_decimal(
         bitwidth,
         _precision,
         scale,
         [%Decimal{exp: exp} = decimal | _rest],
         _acc
       )
       when -exp > scale do
    raise Adbc.Error,
          "`#{Decimal.to_string(decimal)}` with exponent `#{exp}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number with scale value `#{scale}`"
  end

  defp preprocess_decimal(bitwidth, precision, scale, [%Decimal{exp: exp} = decimal | rest], acc)
       when -exp <= scale do
    if Decimal.inf?(decimal) or Decimal.nan?(decimal) do
      raise Adbc.Error,
            "`#{Decimal.to_string(decimal)}` cannot be represented as a valid decimal#{Integer.to_string(bitwidth)} number"
    else
      if coef_length(decimal.coef) > precision do
        raise Adbc.Error,
              "`#{Decimal.to_string(decimal)}` cannot be fitted into a decimal#{Integer.to_string(bitwidth)} with the specified precision #{Integer.to_string(precision)}"
      else
        coef = trunc(decimal.coef * decimal.sign * :math.pow(10, exp + scale))
        acc = [<<coef::signed-integer-little-size(bitwidth)>> | acc]
        preprocess_decimal(bitwidth, precision, scale, rest, acc)
      end
    end
  end

  @doc type: :column_type
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
        name: nil,
        type: :string,
        nullable: false,
        metadata: nil,
        data: ["a", "ab", "abc"]
      }

  """
  @spec string([String.t() | nil], Keyword.t()) :: t()
  def string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :string,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :large_string,
        nullable: false,
        metadata: nil,
        data: ["a", "ab", "abc"]
      }

  """
  @spec large_string([String.t() | nil], Keyword.t()) :: t()
  def large_string(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :large_string,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :binary,
        nullable: false,
        metadata: nil,
        data: [<<0>>, <<1>>, <<2>>]
      }

  """
  @spec binary([iodata() | nil], Keyword.t()) :: t()
  def binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :binary,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: :large_binary,
        nullable: false,
        metadata: nil,
        data: [<<0>>, <<1>>, <<2>>]
      }

  """
  @spec large_binary([iodata() | nil], Keyword.t()) :: t()
  def large_binary(data, opts \\ []) when is_list(data) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: :large_binary,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
        name: nil,
        type: {:fixed_size_binary, 1},
        nullable: false,
        metadata: nil,
        data: [<<0>>, <<1>>, <<2>>]
      }

  """
  @spec fixed_size_binary([iodata() | nil], non_neg_integer(), Keyword.t()) :: t()
  def fixed_size_binary(data, nbytes, opts \\ [])
      when is_list(data) and is_integer(nbytes) and is_list(opts) do
    %Adbc.Column{
      name: opts[:name],
      type: {:fixed_size_binary, nbytes},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
      name: opts[:name],
      type: :date32,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
      name: opts[:name],
      type: :date64,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
  @spec time([Time.t() | nil] | [s64() | nil], time_unit(), Keyword.t()) :: t()
  def time(data, unit, opts \\ [])

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:seconds, :milliseconds] do
    %Adbc.Column{
      name: opts[:name],
      type: {:time32, unit},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  def time(data, unit, opts)
      when is_list(data) and is_list(opts) and unit in [:microseconds, :nanoseconds] do
    %Adbc.Column{
      name: opts[:name],
      type: {:time64, unit},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
  @spec timestamp([NaiveDateTime.t() | nil] | [s64() | nil], time_unit(), String.t(), Keyword.t()) ::
          t()
  def timestamp(data, unit, timezone, opts \\ [])
      when is_list(data) and is_binary(timezone) and is_list(opts) and
             unit in [:seconds, :milliseconds, :microseconds, :nanoseconds] do
    %Adbc.Column{
      name: opts[:name],
      type: {:timestamp, unit, timezone},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
  @spec duration([s64() | nil], time_unit(), Keyword.t()) :: t()
  def duration(data, unit, opts \\ [])
      when is_list(data) and is_list(opts) and
             unit in [:seconds, :milliseconds, :microseconds, :nanoseconds] do
    %Adbc.Column{
      name: opts[:name],
      type: {:duration, unit},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
          interval_unit(),
          Keyword.t()
        ) ::
          t()
  def interval(data, interval_unit, opts \\ [])
      when is_list(data) and is_list(opts) and
             interval_unit in [:month, :day_time, :month_day_nano] do
    %Adbc.Column{
      name: opts[:name],
      type: {:interval, interval_unit},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
  @doc """
  A column that each row is a list of some type or nil.

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
  @spec list([t() | nil], Keyword.t()) :: t()
  def list(data, opts \\ []) when is_list(data) do
    %Adbc.Column{
      name: opts[:name],
      type: :list,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
  @doc """
  Similar to `list/2`, but for large lists.

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
  @spec large_list([t() | nil], Keyword.t()) :: t()
  def large_list(data, opts \\ []) when is_list(data) do
    %Adbc.Column{
      name: opts[:name],
      type: :large_list,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
  @doc """
  Similar to `list/2`, but the length of the list is the same.

  ## Arguments

  * `data`: a list, each element of which can be one of the following:
    - `nil`
    - `Adbc.Column`

    Note that each `Adbc.Column` in the list should have the same type and length.

  * `fixed_size`: The fixed size of the list.

  * `opts`: A keyword list of options

  ## Options

  * `:name` - The name of the column
  * `:nullable` - A boolean value indicating whether the column is nullable
  * `:metadata` - A map of metadata
  """
  @spec fixed_size_list([t() | nil], s32(), Keyword.t()) ::
          t()
  def fixed_size_list(data, fixed_size, opts \\ []) when is_list(data) do
    %Adbc.Column{
      name: opts[:name],
      type: {:fixed_size_list, fixed_size},
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: data
    }
  end

  @doc type: :column_type
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
  def dictionary(key = %Adbc.Column{type: index_type}, value = %Adbc.Column{}, opts \\ [])
      when index_type in [:s8, :u8, :s16, :u16, :s32, :u32, :s64, :u64] do
    %Adbc.Column{
      name: opts[:name],
      type: :dictionary,
      nullable: opts[:nullable] || false,
      metadata: opts[:metadata] || nil,
      data: %{key: key, value: value}
    }
  end

  @doc """
  `materialize/1` converts a column's data from reference type to regular Elixir terms.
  """
  @spec materialize(t()) ::
          t() | {:error, String.t()}
  def materialize(%Adbc.Column{data: data_ref} = self)
      when is_list(data_ref) do
    if Enum.all?(data_ref, &is_reference/1) do
      do_materialize(self)
    else
      self
    end
  end

  def materialize(%Adbc.Column{} = self) do
    self
  end

  defp do_materialize(%Adbc.Column{data: data_ref, type: type} = self) do
    with {:ok, results} <- Adbc.Nif.adbc_column_materialize(data_ref) do
      materialized = Enum.concat(results)

      type =
        case type do
          {:list, _} -> :list
          _ -> type
        end

      handle_decimal(%{self | data: materialized, type: type})
    end
  end

  defp handle_decimal(%Adbc.Column{type: {:decimal, bits, _, scale}, data: decimal_data} = column) do
    %{column | data: handle_decimal(decimal_data, bits, scale)}
  end

  defp handle_decimal(column) do
    column
  end

  defp handle_decimal(decimal_data, bits, scale) do
    Enum.map(decimal_data, fn
      <<decimal::signed-integer-size(bits)-little>> ->
        if decimal < 0 do
          Decimal.new(-1, -decimal, -scale)
        else
          Decimal.new(1, decimal, -scale)
        end

      nil ->
        nil
    end)
  end

  @doc """
  Convert a list view, run-end encoding array or a dictionary to a list.

  ## Examples

      iex> list_view = %Adbc.Column{
      ...>   name: nil,
      ...>   type: :list_view,
      ...>   nullable: true,
      ...>   metadata: nil,
      ...>   data: %{
      ...>     values: %Adbc.Column{
      ...>       name: "item",
      ...>       type: :s32,
      ...>       nullable: false,
      ...>       metadata: nil,
      ...>       data: [0, -127, 127, 50, 12, -7, 25]
      ...>     },
      ...>     validity: [true, false, true, true, true],
      ...>     offsets: [4, 7, 0, 0, 3],
      ...>     sizes: [3, 0, 4, 0, 2]
      ...>   }
      ...> }
      iex> Adbc.Column.to_list(list_view)
      [[12, -7, 25], nil, [0, -127, 127, 50], [], ~c"2\f"]
  """
  @spec to_list(t()) :: [term()]
  def to_list(%Adbc.Column{
        type: type,
        data: %{
          validity: validity,
          offsets: offsets,
          sizes: sizes,
          values: values = %Adbc.Column{}
        }
      })
      when type in @list_view_types and is_list(validity) and is_list(offsets) and is_list(sizes) do
    list =
      if values.type in @list_view_types do
        to_list(values)
      else
        values.data
      end

    Enum.zip_with([offsets, sizes, validity], fn [offset, size, valid] ->
      if valid do
        Enum.slice(list, offset, size)
      else
        nil
      end
    end)
  end

  def to_list(%Adbc.Column{
        type: :run_end_encoded,
        data: %{
          run_ends: run_ends = %Adbc.Column{type: run_end_type, data: data},
          values: values
        },
        length: length,
        offset: offset
      })
      when is_integer(offset) and offset >= 0 and is_integer(length) and length >= 1 do
    values = to_list(values)

    max_allowed_length =
      case run_end_type do
        :s16 ->
          1 <<< 16

        :s32 ->
          1 <<< 32

        :s64 ->
          1 <<< 64

        _ ->
          raise Adbc.Error,
                "Invalid run end type: #{inspect(run_end_type)}, expected one of #{inspect(@valid_run_end_types)}"
      end

    if offset + length > max_allowed_length do
      raise Adbc.Error,
            "Run end data exceeds maximum allowed length: #{length} + #{offset} > #{max_allowed_length}"
    end

    run_end_len = Enum.count(data)

    {run_end_start_index, values_start_index, encoded} =
      case Enum.drop_while(data, &(&1 < offset)) do
        [] ->
          raise Adbc.Error,
                "Last run end is #{hd(Enum.reverse(data))} but it should >= #{offset + length} (offset: #{offset}, length: #{length})"

        encoded = [run_end_start_index | _] ->
          values_start_index = run_end_len - Enum.count(encoded)

          if run_end_start_index == offset do
            {run_end_start_index, values_start_index, encoded}
          else
            {offset, values_start_index, encoded}
          end
      end

    if offset + length > hd(Enum.reverse(data)) do
      raise Adbc.Error,
            "Last run end is #{hd(Enum.reverse(run_ends.data))} but it should >= #{offset + length} (offset: #{offset}, length: #{length})"
    end

    {_, _, decoded} =
      Enum.reduce(encoded, {run_end_start_index, values_start_index, []}, fn
        run_end, {index, value_index, acc} ->
          real_end =
            if run_end > offset + length do
              offset + length
            else
              run_end
            end

          if is_map(values) do
            {run_end, value_index + 1, List.duplicate(values, real_end - index) ++ acc}
          else
            {run_end, value_index + 1,
             List.duplicate(Enum.at(values, value_index), real_end - index) ++ acc}
          end
      end)

    Enum.reverse(decoded)
  end

  def to_list(%Adbc.Column{data: %{key: key, value: value}, type: :dictionary}) do
    value = to_list(value)

    Enum.map(key.data, fn
      index when is_integer(index) ->
        Enum.at(value, index)

      nil ->
        nil
    end)
  end

  def to_list(%Adbc.Column{data: data, type: :list}), do: Enum.map(data, &to_list/1)

  def to_list(%Adbc.Column{data: data, type: :struct}) do
    struct_to_list(data)
  end

  def to_list(%Adbc.Column{data: data, type: {:struct, _columns}}) do
    struct_to_list(data)
  end

  def to_list(%Adbc.Column{data: data}), do: data

  defp struct_to_list(data) do
    %Adbc.Result{data: data, num_rows: nil}
    |> Table.to_rows()
    |> Enum.to_list()
  end
end

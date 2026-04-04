defmodule Adbc.Field do
  @moduledoc """
  Represents the schema definition of a column.

  A field describes the name, type, and metadata of a column
  without containing any data.

  Use `new/2` to create a field:

      Adbc.Field.new(:s32, name: "id")
      Adbc.Field.new({:list, Adbc.Field.new(:s32)}, name: "ids")

  """
  @enforce_keys [:type]
  defstruct [:name, :type, :metadata]

  @type signed_integer :: :s8 | :s16 | :s32 | :s64
  @type unsigned_integer :: :u8 | :u16 | :u32 | :u64
  @type floating :: :f16 | :f32 | :f64

  @type precision128 :: 1..38
  @type precision256 :: 1..76
  @type decimal128 :: {:decimal128, precision128(), integer()}
  @type decimal256 :: {:decimal256, precision256(), integer()}
  @type decimal :: decimal128 | decimal256

  @type time_unit :: :seconds | :milliseconds | :microseconds | :nanoseconds
  @type time32 :: {:time32, :seconds} | {:time32, :milliseconds}
  @type time64 :: {:time64, :microseconds} | {:time64, :nanoseconds}
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

  @type interval_unit :: :month | :day_time | :month_day_nano

  @type interval ::
          {:interval, :month}
          | {:interval, :day_time}
          | {:interval, :month_day_nano}

  @type data_type ::
          :boolean
          | signed_integer()
          | unsigned_integer()
          | floating()
          | :binary
          | :large_binary
          | :binary_view
          | :string
          | :large_string
          | :string_view
          | :date32
          | :date64
          | time()
          | timestamp()
          | duration()
          | interval()
          | decimal()
          | {:fixed_size_binary, non_neg_integer()}
          | {:list, t()}
          | {:large_list, t()}
          | {:list_view, t()}
          | {:large_list_view, t()}
          | {:fixed_size_list, t(), integer()}
          | {:struct, [t()]}
          | {:map, t(), t()}
          | {:dictionary, t(), t()}
          | {:run_end_encoded, t(), t()}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          type: data_type(),
          metadata: map() | nil
        }

  @doc """
  Creates a new field with the given type and options.

  ## Options

    * `:name` - The name of the field
    * `:metadata` - A map of metadata
  """
  @spec new(data_type(), Keyword.t()) :: t()
  def new(type, opts \\ []) do
    %Adbc.Field{
      name: opts[:name],
      type: type,
      metadata: opts[:metadata]
    }
  end
end

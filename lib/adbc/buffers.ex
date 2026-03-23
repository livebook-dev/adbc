defmodule Adbc.DictionaryData do
  @moduledoc false
  defstruct [:key, :value]
end

defmodule Adbc.RunEndEncodedData do
  @moduledoc false
  defstruct [:run_ends, :values, :length, :offset]
end

defmodule Adbc.ListViewData do
  @moduledoc false
  defstruct [:offsets, :sizes, :validity, :values, :bit_offset]
end

defmodule Adbc.ListData do
  @moduledoc false
  defstruct [:offsets, :validity, :values, :bit_offset]
end

defmodule Adbc.BufferData do
  @moduledoc false
  defstruct [:data, :validity, :bit_offset, :size]
end

defmodule Adbc.BinaryData do
  @moduledoc false
  defstruct [:offsets, :data, :validity, :bit_offset]
end

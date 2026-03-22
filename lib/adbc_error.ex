defmodule Adbc.Error do
  @derive {Inspect, only: [:message, :vendor_code]}
  defexception [:message, :vendor_code, :state]

  @type t :: %Adbc.Error{
          message: String.t(),
          vendor_code: integer() | nil,
          state: <<_::40>> | nil
        }
end

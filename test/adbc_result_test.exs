defmodule Adbc.ResultTest do
  use ExUnit.Case, async: true
  alias Adbc.Result

  # Just some imaginary data and context so it's easier to understand this test
  # measurements: [1, 2, 3, 4, 5, 6]
  # data points: [
  #   [1],    # 2024-05-31 12:00:00 - 2024-05-31 12:15:00
  #   [2, 3], # 2024-05-31 12:15:00 - 2024-05-31 12:30:00
  #   [3, 4], # 2024-05-31 12:30:00 - 2024-05-31 12:45:00
  #   [4],    # 2024-05-31 12:45:00 - 2024-05-31 13:00:00
  #   [5, 6], # 2024-05-31 13:00:00 - 2024-05-31 13:15:00
  #   [6]     # 2024-05-31 13:15:00 - 2024-05-31 13:30:00
  # ]
  defp result do
    %Adbc.Result{
      data: [
        %Adbc.Column{
          field: %Adbc.Field{
            name: "start_time",
            type: {:timestamp, :seconds, "UTC"},
            nullable: true
          },
          data: [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]]
        },
        %Adbc.Column{
          field: %Adbc.Field{
            name: "end_time",
            type: {:timestamp, :seconds, "UTC"},
            nullable: true
          },
          data: [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]]
        },
        %Adbc.Column{
          field: %Adbc.Field{
            name: "time_series",
            type:
              {:list,
               %Adbc.Field{
                 name: "item",
                 type: :s32,
                 nullable: true
               }},
            nullable: true
          },
          data: [
            [[1], [2, 3], [3, 4], [4]],
            [[3, 4], [4], [5, 6], [6]]
          ]
        }
      ]
    }
  end

  test "implements table reader" do
    assert result() |> Table.to_rows() |> Enum.to_list() == [
             %{
               "end_time" => ~N[2024-05-31 13:00:00],
               "start_time" => ~N[2024-05-31 12:00:00],
               "time_series" => [[1], [2, 3], [3, 4], [4]]
             },
             %{
               "end_time" => ~N[2024-05-31 13:30:00],
               "start_time" => ~N[2024-05-31 12:30:00],
               "time_series" => [[3, 4], [4], [5, 6], [6]]
             }
           ]
  end

  test "to_map with list views" do
    assert %{
             "start_time" => [~N[2024-05-31 12:00:00], ~N[2024-05-31 12:30:00]],
             "end_time" => [~N[2024-05-31 13:00:00], ~N[2024-05-31 13:30:00]],
             "time_series" => [[[1], [2, 3], [3, 4], [4]], [[3, 4], [4], [5, 6], [6]]]
           } == Result.to_map(result())
  end

end

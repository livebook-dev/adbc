defmodule AdbcTest do
  use ExUnit.Case, async: true
  doctest Adbc

  describe "download_driver" do
    test "multiple times" do
      assert Adbc.download_driver(:sqlite) == :ok
      assert Adbc.download_driver(:sqlite) == :ok
    end

    test "returns errors" do
      assert {:error,
              "unknown driver :unknown, expected one of :bigquery, :duckdb, :flightsql, :postgresql, " <>
                _} =
               Adbc.download_driver(:unknown)
    end
  end
end

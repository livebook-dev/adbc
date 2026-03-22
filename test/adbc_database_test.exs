defmodule Adbc.DatabaseTest do
  use ExUnit.Case, async: true
  doctest Adbc.Database
  alias Adbc.Database

  describe "start_link" do
    test "starts a process" do
      assert {:ok, _} = Database.start_link(driver: :sqlite)
    end

    test "accepts process options" do
      assert {:ok, pid} =
               Database.start_link(driver: :sqlite, process_options: [name: :who_knows_db])

      assert Process.whereis(:who_knows_db) == pid
    end

    test "accepts driver from path" do
      {:ok, path} = Adbc.Driver.so_path(:sqlite)
      assert {:ok, pid} = Database.start_link(driver: path)
      assert Process.alive?(pid)
    end

    test "errors with invalid driver" do
      assert {:error, %ArgumentError{} = error} = Database.start_link(driver: :who_knows)
      assert Exception.message(error) =~ "unknown driver :who_knows"
    end

    test "errors with invalid option" do
      assert {:error, %Adbc.Error{} = error} =
               Database.start_link(driver: :sqlite, who_knows: 123)

      assert Exception.message(error) == "[SQLite] Unknown database option who_knows=123"
    end
  end

  describe "get/set options" do
    test "get non-existed option" do
      {:ok, pid} = Database.start_link(driver: :sqlite)
      assert {:error, %Adbc.Error{} = error} = Database.get_string_option(pid, "foo")
      assert Exception.message(error) == "Unknown option"
    end

    test "set non-existed option" do
      {:ok, pid} = Database.start_link(driver: :sqlite)
      assert {:error, %Adbc.Error{} = error} = Database.set_option(pid, "foo", "bar")
      assert Exception.message(error) == "[SQLite] Unknown database option foo='bar'"
    end
  end
end

defmodule Adbc.ConnectionTest do
  use ExUnit.Case, async: true
  doctest Adbc.Connection

  alias Adbc.Connection

  setup do
    %{db: start_supervised!({Adbc.Database, driver: :sqlite, uri: ":memory:"})}
  end

  describe "start_link" do
    test "starts a process", %{db: db} do
      assert {:ok, pid} = Connection.start_link(database: db)
      assert is_pid(pid)
    end

    test "accepts process options", %{db: db} do
      assert {:ok, pid} =
               Connection.start_link(database: db, process_options: [name: :who_knows_conn])

      assert Process.whereis(:who_knows_conn) == pid
    end

    @tag :capture_log
    test "terminates when database terminates", %{db: db} do
      Process.flag(:trap_exit, true)
      assert {:ok, pid} = Connection.start_link(database: db)
      ref = Process.monitor(pid)
      Process.exit(db, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
    end

    test "errors with invalid option", %{db: db} do
      Process.flag(:trap_exit, true)

      assert {:error, %Adbc.Error{} = error} = Connection.start_link(database: db, who_knows: 123)

      assert Exception.message(error) == "[SQLite] Unknown connection option who_knows=123"
    end
  end

  describe "get_info" do
    test "get all info from a connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {
               :ok,
               results = %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "info_name",
                     type: :u32,
                     metadata: nil,
                     nullable: false
                   },
                   %Adbc.Column{
                     name: "info_value",
                     type: :dense_union,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               }
             } = Connection.get_info(conn)

      assert %Adbc.Result{
               num_rows: nil,
               data: [
                 %Adbc.Column{
                   name: "info_name",
                   type: :u32,
                   nullable: false,
                   metadata: nil,
                   data: [0, 1, 100, 101, 102]
                 },
                 %Adbc.Column{
                   name: "info_value",
                   type: :dense_union,
                   nullable: true,
                   metadata: nil,
                   data: [
                     %{"string_value" => ["SQLite"]},
                     # "3.43.2"
                     %{"string_value" => [_]},
                     %{"string_value" => ["ADBC SQLite Driver"]},
                     # "(unknown)"
                     %{"string_value" => [_]},
                     # "0.4.0"
                     %{"string_value" => [_]}
                   ]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "get some info from a connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "info_name",
                    type: :u32,
                    metadata: nil,
                    nullable: false
                  },
                  %Adbc.Column{
                    name: "info_value",
                    type: :dense_union,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.get_info(conn, [0])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "info_name",
                   type: :u32,
                   nullable: false,
                   metadata: nil,
                   data: [0]
                 },
                 %Adbc.Column{
                   name: "info_value",
                   type: :dense_union,
                   nullable: true,
                   metadata: nil,
                   data: [%{"string_value" => ["SQLite"]}]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end
  end

  describe "get_driver" do
    test "returns the driver", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert Connection.get_driver(conn) == {:ok, :sqlite}
    end

    test "returns :error for non ADBC connection" do
      assert Connection.get_driver(self()) == :error
    end

    test "returns :error for dead process" do
      assert Connection.get_driver(:not_really_a_process) == :error
    end
  end

  describe "get_objects" do
    test "get all objects from a connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                num_rows: nil,
                data: _
              }} = Connection.get_objects(conn, 0)

      assert results =
               %Adbc.Result{
                 num_rows: nil,
                 data: []
               } = Adbc.Result.materialize(results)

      assert %{} == Adbc.Result.to_map(results)
    end
  end

  describe "get_table_types" do
    test "get table types from a connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                num_rows: nil,
                data: [
                  %Adbc.Column{
                    name: "table_type",
                    type: :string,
                    metadata: nil,
                    nullable: false
                  }
                ]
              }} = Connection.get_table_types(conn)

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "table_type",
                     type: :string,
                     nullable: false,
                     metadata: nil,
                     data: ["table", "view"]
                   }
                 ]
               } = Adbc.Result.materialize(results)

      assert %{"table_type" => ["table", "view"]} = Adbc.Result.to_map(results)
    end
  end

  describe "query" do
    test "select", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  } = column
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 as num")

      # Ensure matching struct fields
      assert map_size(column) == map_size(Adbc.Column.s64([]))

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [123]
                 } = column
               ]
             } = Adbc.Result.materialize(results)

      # Ensure matching struct fields
      assert map_size(column) == map_size(Adbc.Column.s64([]))

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  },
                  %Adbc.Column{
                    name: "bool",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 as num, true as bool")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [123]
                 },
                 %Adbc.Column{
                   name: "bool",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [1]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "select with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 + ? as num", [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [579]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "select with prepared query", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:ok, ref} = Connection.prepare(conn, "SELECT 123 + ? as num")

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [579]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "select with multiple prepared queries", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:ok, ref_a} = Connection.prepare(conn, "SELECT 123 + ? as num")
      assert {:ok, ref_b} = Connection.prepare(conn, "SELECT 1000 + ? as num")

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref_a, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [579]
                 }
               ]
             } = Adbc.Result.materialize(results)

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    name: "num",
                    type: :s64,
                    metadata: nil,
                    nullable: true
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref_b, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [1456]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "fails on invalid query", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:error, %Adbc.Error{} = error} = Connection.query(conn, "NOT VALID SQL")
      assert Exception.message(error) =~ "[SQLite] Failed to prepare query"
    end
  end

  describe "query!" do
    test "select", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "num",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 as num")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [123]
                 }
               ]
             } = Adbc.Result.materialize(results)

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "num",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   },
                   %Adbc.Column{
                     name: "bool",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 as num, true as bool")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [123]
                 },
                 %Adbc.Column{name: "bool", type: :s64, nullable: true, metadata: nil, data: [1]}
               ]
             } = Adbc.Result.materialize(results)
    end

    test "select with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "num",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 + ? as num", [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [579]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "fails on invalid query", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert_raise Adbc.Error,
                   ~s([SQLite] Failed to prepare query: near "NOT": syntax error\nquery: NOT VALID SQL),
                   fn -> Connection.query!(conn, "NOT VALID SQL") end
    end
  end

  describe "query with statement options" do
    test "without parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "num",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   },
                   %Adbc.Column{
                     name: "bool",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               } =
               Connection.query!(conn, "SELECT 123 as num, true as bool", [],
                 "adbc.sqlite.query.batch_rows": 1
               )

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [123]
                 },
                 %Adbc.Column{name: "bool", type: :s64, nullable: true, metadata: nil, data: [1]}
               ]
             } = Adbc.Result.materialize(results)
    end

    test "with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     name: "num",
                     type: :s64,
                     metadata: nil,
                     nullable: true
                   }
                 ],
                 num_rows: nil
               } =
               Connection.query!(conn, "SELECT 123 + ? as num", [456],
                 "adbc.sqlite.query.batch_rows": 10
               )

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   name: "num",
                   type: :s64,
                   nullable: true,
                   metadata: nil,
                   data: [579]
                 }
               ]
             } = Adbc.Result.materialize(results)
    end

    test "invalid statement option key", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:error, %Adbc.Error{} = error} =
               Connection.query(conn, "SELECT 123 as num", [], foo: 1)

      assert Exception.message(error) == "[SQLite] Unknown statement option foo=1"
    end

    test "invalid statement option value", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:error, %Adbc.Error{} = error} =
               Connection.query(conn, "SELECT 123 as num, true as bool", [],
                 "adbc.sqlite.query.batch_rows": 0
               )

      assert Exception.message(error) ==
               "[SQLite] Invalid statement option value adbc.sqlite.query.batch_rows=0 (value is non-positive or out of range of int)"
    end
  end

  describe "prepared queries" do
    test "prepare", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:ok, ref} = Connection.prepare(conn, "SELECT 123 + ? as num")
      assert is_reference(ref)
    end
  end

  describe "query_pointer" do
    test "select", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok, :from_pointer} =
               Connection.query_pointer(conn, "SELECT 123 as num", fn stream ->
                 assert %Adbc.StreamResult{pointer: pointer} = stream
                 assert is_integer(pointer)
                 :from_pointer
               end)
    end

    test "prepared query", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      {:ok, ref} = Connection.prepare(conn, "SELECT 123 + ? as num")

      assert {:ok, :from_pointer} =
               Connection.query_pointer(conn, ref, [456], fn stream ->
                 assert %Adbc.StreamResult{pointer: pointer} = stream
                 assert is_integer(pointer)
                 :from_pointer
               end)
    end
  end

  describe "lock" do
    test "serializes access", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      for _ <- 1..10 do
        Task.async(fn -> run_anything(conn) end)
      end
      |> Task.await_many()
    end

    test "crashes releases the lock", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert_raise RuntimeError, fn ->
        Connection.query_pointer(conn, "SELECT 1", fn _ ->
          raise "oops"
        end)
      end

      run_anything(conn)
    end

    test "broken link releases the lock", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      parent = self()

      child =
        spawn(fn ->
          Connection.query_pointer(conn, "SELECT 1", fn _ ->
            send(parent, :ready)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :ready
      Process.exit(child, :kill)
      run_anything(conn)
    end

    test "commands that error do not lock", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      {:error, %Adbc.Error{}} = Connection.query(conn, "NOT VALID SQL")
      {:error, %Adbc.Error{}} = Connection.prepare(conn, "NOT VALID SQL")
      run_anything(conn)
    end

    defp run_anything(conn) do
      {:ok, %{}} = Connection.get_table_types(conn)
    end
  end

  describe "bulk_insert" do
    test "creates table and inserts data", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name"),
        Adbc.Column.s32([25, 30, 35], name: "age")
      ]

      assert {:ok, 3} = Connection.bulk_insert(conn, columns, table: "users")

      # Verify the data was inserted
      {:ok, result} = Connection.query(conn, "SELECT * FROM users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
      assert map["age"] == [25, 30, 35]
    end

    test "appends to existing table", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # First insert
      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"], name: "name")
      ]

      assert {:ok, 2} = Connection.bulk_insert(conn, columns, table: "users")

      # Append more data
      more_columns = [
        Adbc.Column.s64([3, 4], name: "id"),
        Adbc.Column.string(["Charlie", "David"], name: "name")
      ]

      assert {:ok, 2} = Connection.bulk_insert(conn, more_columns, table: "users", mode: :append)

      # Verify all data
      {:ok, result} = Connection.query(conn, "SELECT * FROM users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [1, 2, 3, 4]
      assert map["name"] == ["Alice", "Bob", "Charlie", "David"]
    end

    test "replaces existing table", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # First insert
      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"], name: "name")
      ]

      assert {:ok, 2} = Connection.bulk_insert(conn, columns, table: "users")

      # Replace with new data
      new_columns = [
        Adbc.Column.s64([10, 20], name: "id"),
        Adbc.Column.string(["Frank", "Grace"], name: "name")
      ]

      assert {:ok, 2} = Connection.bulk_insert(conn, new_columns, table: "users", mode: :replace)

      # Verify only new data exists
      {:ok, result} = Connection.query(conn, "SELECT * FROM users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [10, 20]
      assert map["name"] == ["Frank", "Grace"]
    end

    test "create_append mode creates if not exists", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"], name: "name")
      ]

      assert {:ok, 2} =
               Connection.bulk_insert(conn, columns, table: "new_users", mode: :create_append)

      # Verify data was inserted
      {:ok, result} = Connection.query(conn, "SELECT * FROM new_users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [1, 2]
      assert map["name"] == ["Alice", "Bob"]
    end

    test "create_append mode appends if exists", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # First insert
      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"], name: "name")
      ]

      assert {:ok, 2} =
               Connection.bulk_insert(conn, columns, table: "users", mode: :create_append)

      # Append using create_append
      more_columns = [
        Adbc.Column.s64([3, 4], name: "id"),
        Adbc.Column.string(["Charlie", "David"], name: "name")
      ]

      assert {:ok, 2} =
               Connection.bulk_insert(conn, more_columns, table: "users", mode: :create_append)

      # Verify all data
      {:ok, result} = Connection.query(conn, "SELECT * FROM users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [1, 2, 3, 4]
      assert map["name"] == ["Alice", "Bob", "Charlie", "David"]
    end

    test "raises error when table is not specified", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      assert_raise ArgumentError, ":table option must be specified", fn ->
        Connection.bulk_insert(conn, columns, [])
      end
    end

    test "raises error for invalid mode", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      assert_raise ArgumentError, ~r/invalid :mode option/, fn ->
        Connection.bulk_insert(conn, columns, table: "users", mode: :invalid)
      end
    end

    test "bulk_insert! returns rows affected", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id")
      ]

      assert 3 = Connection.bulk_insert!(conn, columns, table: "test_table")
    end

    test "bulk_insert! raises on error", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Create a table first
      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      Connection.bulk_insert!(conn, columns, table: "users")

      # Try to create again (should fail)
      assert_raise Adbc.Error, fn ->
        Connection.bulk_insert!(conn, columns, table: "users", mode: :create)
      end
    end

    test "temporary table", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      # Create a temporary table
      assert {:ok, 3} =
               Connection.bulk_insert(conn, columns, table: "temp_users", temporary: true)

      # Verify the data was inserted into the temp table
      {:ok, result} = Connection.query(conn, "SELECT * FROM temp_users ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end

    test "error: create mode when table already exists", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      # Create the table first
      assert {:ok, 2} =
               Connection.bulk_insert(conn, columns, table: "existing_table", mode: :create)

      # Try to create again with :create mode (should fail)
      assert {:error, %Adbc.Error{} = error} =
               Connection.bulk_insert(conn, columns, table: "existing_table", mode: :create)

      assert error.message =~ "already exists"
    end

    test "error: append mode when table doesn't exist", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      # Try to append to a non-existent table
      assert {:error, %Adbc.Error{} = error} =
               Connection.bulk_insert(conn, columns, table: "nonexistent_table", mode: :append)

      assert error.message =~ "no such table"
    end

    test "error: schema mismatch on append", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Create table with one schema
      columns1 = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      assert {:ok, 2} =
               Connection.bulk_insert(conn, columns1, table: "schema_test", mode: :create)

      # Try to append with different schema
      columns2 = [
        Adbc.Column.string(["a", "b"], name: "name")
      ]

      assert {:error, %Adbc.Error{} = error} =
               Connection.bulk_insert(conn, columns2, table: "schema_test", mode: :append)

      assert error.message =~ "has no column named"
    end

    test "error: unmaterialized columns are rejected", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Create initial data
      initial_columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      assert {:ok, 3} = Connection.bulk_insert(conn, initial_columns, table: "source_table")

      # Query the data (returns unmaterialized columns)
      {:ok, result} = Connection.query(conn, "SELECT * FROM source_table")

      # Verify data is unmaterialized (contains references)
      assert is_list(hd(result.data).data)
      assert is_reference(hd(hd(result.data).data))

      # Try to use unmaterialized columns in bulk_insert - should fail with clear ArgumentError
      assert {:error, %ArgumentError{} = error} =
               Connection.bulk_insert(conn, result.data, table: "target_table")

      error_message = Exception.message(error)
      assert error_message =~ "Cannot use unmaterialized"
      assert error_message =~ "materialize"
    end

    test "materialized columns work in bulk_insert", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Create initial data
      initial_columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      assert {:ok, 3} = Connection.bulk_insert(conn, initial_columns, table: "source_table")

      # Query and materialize the data
      {:ok, result} = Connection.query(conn, "SELECT * FROM source_table")
      materialized_result = Adbc.Result.materialize(result)

      # Materialized data should work
      assert {:ok, 3} =
               Connection.bulk_insert(conn, materialized_result.data, table: "target_table")

      # Verify the data was inserted correctly
      {:ok, verify} = Connection.query(conn, "SELECT * FROM target_table ORDER BY id")
      verify = Adbc.Result.materialize(verify)
      map = Adbc.Result.to_map(verify)

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end

    test "stream-based bulk insert raises on same connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert_raise ArgumentError,
                   "cannot use bulk_insert to transfer results over the same connection",
                   fn ->
                     Connection.query_pointer(conn, "SELECT 1, 2, 3", fn stream ->
                       Connection.bulk_insert(conn, stream, table: "dest_table")
                     end)
                   end
    end

    test "stream-based bulk insert across different connections", %{db: db} do
      source_conn = start_supervised!({Connection, database: db})
      dest_conn = start_supervised!({Connection, database: db}, id: :dest_conn)

      # Create initial data in source
      initial_columns = [
        Adbc.Column.s64([10, 20, 30], name: "id"),
        Adbc.Column.string(["X", "Y", "Z"], name: "code")
      ]

      assert {:ok, 3} =
               Connection.bulk_insert(source_conn, initial_columns, table: "source_table")

      # Transfer data from source to destination efficiently
      result =
        Connection.query_pointer(source_conn, "SELECT * FROM source_table", fn stream ->
          Connection.bulk_insert(dest_conn, stream, table: "dest_table")
        end)

      assert {:ok, {:ok, 3}} = result

      # Verify the data in destination
      {:ok, verify} = Connection.query(dest_conn, "SELECT * FROM dest_table ORDER BY id")
      verify = Adbc.Result.materialize(verify)
      map = Adbc.Result.to_map(verify)

      assert map["id"] == [10, 20, 30]
      assert map["code"] == ["X", "Y", "Z"]
    end
  end
end

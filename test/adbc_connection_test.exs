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
                     field: %{
                       name: "info_name",
                       type: :u32,
                       metadata: nil,
                       nullable: false
                     }
                   },
                   %Adbc.Column{
                     field: %{
                       name: "info_value",
                       type: :dense_union,
                       metadata: nil,
                       nullable: true
                     }
                   }
                 ],
                 num_rows: nil
               }
             } = Connection.get_info(conn)

      assert %Adbc.Result{
               num_rows: nil,
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "info_name",
                     type: :u32,
                     nullable: false,
                     metadata: nil
                   },
                 } = info_name_col,
                 %Adbc.Column{
                   field: %{
                     name: "info_value",
                     type: :dense_union,
                     nullable: true,
                     metadata: nil
                   },
                   data: [
                     [
                       %{"string_value" => ["SQLite"]},
                       # "3.43.2"
                       %{"string_value" => [_]},
                       %{"string_value" => ["ADBC SQLite Driver"]},
                       # "(unknown)"
                       %{"string_value" => [_]},
                       # "0.4.0"
                       %{"string_value" => [_]},
                       %{"int64_value" => _}
                     ]
                   ]
                 }
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(info_name_col) == [0, 1, 100, 101, 102, 103]
    end

    test "get some info from a connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "info_name",
                      type: :u32,
                      metadata: nil,
                      nullable: false
                    }
                  },
                  %Adbc.Column{
                    field: %{
                      name: "info_value",
                      type: :dense_union,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.get_info(conn, [0])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "info_name",
                     type: :u32,
                     nullable: false,
                     metadata: nil
                   },
                 } = info_name_col,
                 %Adbc.Column{
                   field: %{
                     name: "info_value",
                     type: :dense_union,
                     nullable: true,
                     metadata: nil
                   },
                   data: [[%{"string_value" => ["SQLite"]}]]
                 }
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(info_name_col) == [0]
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
                    field: %{
                      name: "table_type",
                      type: :string,
                      metadata: nil,
                      nullable: false
                    }
                  }
                ]
              }} = Connection.get_table_types(conn)

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     field: %{
                       name: "table_type",
                       type: :string,
                       nullable: false,
                       metadata: nil
                     },
                     data: [["table", "view"]]
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
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  } = column
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 as num")

      # Ensure matching struct fields
      assert map_size(column) == map_size(Adbc.Column.s64([]))

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   },
                 } = column
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(column) == [123]

      # Ensure matching struct fields
      assert map_size(column) == map_size(Adbc.Column.s64([]))

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  },
                  %Adbc.Column{
                    field: %{
                      name: "bool",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 as num, true as bool")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col,
                 %Adbc.Column{
                   field: %{
                     name: "bool",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = bool_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [123]
      assert Adbc.Column.to_list(bool_col) == [1]
    end

    test "select with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, "SELECT 123 + ? as num", [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [579]
    end

    test "select with prepared query", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:ok, ref} = Connection.prepare(conn, "SELECT 123 + ? as num")

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [579]
    end

    test "select with multiple prepared queries", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      assert {:ok, ref_a} = Connection.prepare(conn, "SELECT 123 + ? as num")
      assert {:ok, ref_b} = Connection.prepare(conn, "SELECT 1000 + ? as num")

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref_a, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [579]

      assert {:ok,
              results = %Adbc.Result{
                data: [
                  %Adbc.Column{
                    field: %{
                      name: "num",
                      type: :s64,
                      metadata: nil,
                      nullable: true
                    }
                  }
                ],
                num_rows: nil
              }} = Connection.query(conn, ref_b, [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [1456]
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
                     field: %{
                       name: "num",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 as num")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [123]

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     field: %{
                       name: "num",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
                   },
                   %Adbc.Column{
                     field: %{
                       name: "bool",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 as num, true as bool")

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col,
                 %Adbc.Column{
                   field: %{
                     name: "bool",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = bool_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [123]
      assert Adbc.Column.to_list(bool_col) == [1]
    end

    test "select with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     field: %{
                       name: "num",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
                   }
                 ],
                 num_rows: nil
               } = Connection.query!(conn, "SELECT 123 + ? as num", [456])

      assert %Adbc.Result{
               data: [
                 %Adbc.Column{
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [579]
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
                     field: %{
                       name: "num",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
                   },
                   %Adbc.Column{
                     field: %{
                       name: "bool",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
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
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col,
                 %Adbc.Column{
                   field: %{
                     name: "bool",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = bool_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [123]
      assert Adbc.Column.to_list(bool_col) == [1]
    end

    test "with parameters", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert results =
               %Adbc.Result{
                 data: [
                   %Adbc.Column{
                     field: %{
                       name: "num",
                       type: :s64,
                       metadata: nil,
                       nullable: true
                     }
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
                   field: %{
                     name: "num",
                     type: :s64,
                     nullable: true,
                     metadata: nil
                   }
                 } = num_col
               ]
             } = Adbc.Result.materialize(results)

      assert Adbc.Column.to_list(num_col) == [579]
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

  describe "py_query" do
    test "select", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok, py_table = %Pythonx.Object{}} =
               Connection.py_query(conn, "SELECT 123 as num, true as bool")

      {py_list, %{}} =
        Pythonx.eval(
          """
          py_table.to_pylist()
          """,
          %{"py_table" => py_table}
        )

      assert Pythonx.decode(py_list) == [%{"num" => 123, "bool" => 1}]
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

    test "crashes release the lock", %{db: db} do
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

    test "materialized columns", %{db: db} do
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

    test "nullable columns and nil values", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Nullable columns with nil values work fine
      columns = [
        Adbc.Column.s64([1, nil, 3], name: "id", nullable: true),
        Adbc.Column.string(["Alice", nil, "Charlie"], name: "name", nullable: true)
      ]

      assert {:ok, 3} = Connection.bulk_insert(conn, columns, table: "nullable_test")

      {:ok, result} = Connection.query(conn, "SELECT * FROM nullable_test ORDER BY id")
      result = Adbc.Result.materialize(result)
      map = Adbc.Result.to_map(result)

      assert map["id"] == [nil, 1, 3]
      assert map["name"] == [nil, "Alice", "Charlie"]

    end

    test "bulk inserts a Pythonx.Object implementing arrow stream", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      {py_table, %{}} =
        Pythonx.eval(
          """
          import pyarrow
          n_legs = pyarrow.array([2, 4, 5, 100])
          animals = pyarrow.array(["Flamingo", "Horse", "Brittle stars", "Centipede"])
          names = ["n_legs", "animals"]
          pyarrow.Table.from_arrays([n_legs, animals], names=names)
          """,
          %{}
        )

      assert {:ok, 4} = Connection.bulk_insert(conn, py_table, table: "py_animals")

      {:ok, verify} =
        Connection.query(conn, "SELECT * FROM py_animals ORDER BY n_legs")

      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()
      assert map["n_legs"] == [2, 4, 5, 100]
      assert map["animals"] == ["Flamingo", "Horse", "Brittle stars", "Centipede"]
    end

    test "bulk inserts streams across different connections", %{db: db} do
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

    test "auto-names unnamed columns", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"]),
        Adbc.Column.s32([25, 30], name: "age")
      ]

      assert {:ok, 2} = Connection.bulk_insert(conn, columns, table: "mixed")

      {:ok, result} = Connection.query(conn, "SELECT * FROM mixed ORDER BY id")
      map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

      assert map["id"] == [1, 2]
      assert map["col2"] == ["Alice", "Bob"]
      assert map["age"] == [25, 30]
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

    test "error: missing table", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      assert_raise ArgumentError, ":table option must be specified", fn ->
        Connection.bulk_insert(conn, columns, [])
      end
    end

    test "error: on invalid mode", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id")
      ]

      assert_raise ArgumentError, ~r/invalid :mode option/, fn ->
        Connection.bulk_insert(conn, columns, table: "users", mode: :invalid)
      end
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

    test "bulk inserts from IPC stream", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Build IPC stream data from columns
      result = %Adbc.Result{
        data: [
          Adbc.Column.s64([1, 2, 3], name: "id"),
          Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
        ],
        num_rows: 3
      }

      ipc_data = Adbc.Result.to_ipc_stream(result)
      {:ok, stream} = Adbc.StreamResult.from_ipc_stream(ipc_data)

      assert {:ok, 3} = Connection.bulk_insert(conn, stream, table: "ipc_users")

      {:ok, verify} = Connection.query(conn, "SELECT * FROM ipc_users ORDER BY id")
      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end

    test "error: stream-based bulk insert on same connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert_raise ArgumentError,
                   "cannot use bulk_insert to transfer results over the same connection",
                   fn ->
                     Connection.query_pointer(conn, "SELECT 1, 2, 3", fn stream ->
                       Connection.bulk_insert(conn, stream, table: "dest_table")
                     end)
                   end
    end

    test "accepts keyword list mixing columns and inferred lists", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok, 3} =
               Connection.bulk_insert(
                 conn,
                 [
                   id: [1, 2, 3],
                   name: Adbc.Column.string(["Alice", "Bob", "Charlie"])
                 ],
                 table: "users"
               )

      {:ok, result} = Connection.query(conn, "SELECT * FROM users ORDER BY id")
      map = result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end

    # Note: type coverage for bulk_insert roundtrips (integers, floats, strings,
    # binary, decimals, lists, dictionaries, timestamps, booleans) is in adbc_duckdb_test.exs
  end

  describe "ingest" do
    test "ingests into a temporary table and returns IngestResult", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2, 3], name: "id"),
        Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
      ]

      assert {:ok, %Adbc.IngestResult{} = result} = Connection.ingest(conn, columns)
      assert result.table == "adbc_ingest_0"
      assert result.num_rows == 3
      assert is_reference(result.ref)

      # Verify the data is queryable
      {:ok, query_result} =
        Connection.query(conn, "SELECT * FROM #{result.table} ORDER BY id")

      query_result = Adbc.Result.materialize(query_result)
      map = Adbc.Result.to_map(query_result)

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end

    test "increments table counter", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [Adbc.Column.s64([1], name: "id")]

      assert {:ok, result1} = Connection.ingest(conn, columns)
      assert result1.table == "adbc_ingest_0"

      assert {:ok, result2} = Connection.ingest(conn, columns)
      assert result2.table == "adbc_ingest_1"
    end

    test "drops table when result is garbage collected", %{db: db} do
      conn = start_supervised!({Connection, database: db})
      conn_pid = GenServer.whereis(conn)
      :erlang.trace(conn_pid, true, [:receive, tracer: self()])

      assert {:ok, result} =
               Connection.ingest(conn, [
                 Adbc.Column.s64([1, 2, 3], name: "id"),
                 Adbc.Column.string(["Alice", "Bob", "Charlie"], name: "name")
               ])

      # Verify the table exists
      assert {:ok, _} = Connection.query(conn, "SELECT * FROM #{result.table}")

      # Use result one last time so it is not referenced after this point
      table_name = Adbc.Helper.noop(result).table
      :erlang.garbage_collect(conn_pid)
      :erlang.garbage_collect(self())

      # Wait for the connection to receive the :delete_on_gc message
      assert_receive {:trace, ^conn_pid, :receive, {:delete_on_gc, ^table_name}}, 1000
      :erlang.trace(conn_pid, false, [:receive])

      # Ensure the delete command has been processed by making a synchronous call
      assert {:error, %Adbc.Error{} = error} =
               Connection.query(conn, "SELECT * FROM #{table_name}")

      assert error.message =~ table_name
    end

    test "stream-based ingest across different connections", %{db: db} do
      source_conn = start_supervised!({Connection, database: db})
      dest_conn = start_supervised!({Connection, database: db}, id: :ingest_dest_conn)

      # Create initial data in source
      columns = [
        Adbc.Column.s64([10, 20, 30], name: "id"),
        Adbc.Column.string(["X", "Y", "Z"], name: "code")
      ]

      Connection.bulk_insert!(source_conn, columns, table: "ingest_source")

      # Transfer data via stream-based ingest
      {:ok, result} =
        Connection.query_pointer(source_conn, "SELECT * FROM ingest_source", fn stream ->
          Connection.ingest(dest_conn, stream)
        end)

      assert {:ok, %Adbc.IngestResult{} = ingest_result} = result
      assert ingest_result.num_rows == 3
      assert ingest_result.table =~ "adbc_ingest_"

      # Verify the data in destination
      {:ok, verify} =
        Connection.query(dest_conn, "SELECT * FROM #{ingest_result.table} ORDER BY id")

      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()
      assert map["id"] == [10, 20, 30]
      assert map["code"] == ["X", "Y", "Z"]
    end

    test "IPC stream-based ingest", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      # Build IPC stream data from columns
      result = %Adbc.Result{
        data: [
          Adbc.Column.s64([10, 20, 30], name: "id"),
          Adbc.Column.string(["X", "Y", "Z"], name: "code")
        ],
        num_rows: 3
      }

      ipc_data = Adbc.Result.to_ipc_stream(result)
      {:ok, stream} = Adbc.StreamResult.from_ipc_stream(ipc_data)

      assert {:ok, %Adbc.IngestResult{} = ingest_result} = Connection.ingest(conn, stream)
      assert ingest_result.num_rows == 3

      {:ok, verify} =
        Connection.query(conn, "SELECT * FROM #{ingest_result.table} ORDER BY id")

      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()
      assert map["id"] == [10, 20, 30]
      assert map["code"] == ["X", "Y", "Z"]
    end

    test "stream-based ingest raises on same connection", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert_raise ArgumentError,
                   "cannot use ingest to transfer results over the same connection",
                   fn ->
                     Connection.query_pointer(conn, "SELECT 1, 2, 3", fn stream ->
                       Connection.ingest(conn, stream)
                     end)
                   end
    end

    test "ingests a Pythonx.Object implementing arrow stream", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      {py_table, %{}} =
        Pythonx.eval(
          """
          import pyarrow
          n_legs = pyarrow.array([2, 4, 5, 100])
          animals = pyarrow.array(["Flamingo", "Horse", "Brittle stars", "Centipede"])
          names = ["n_legs", "animals"]
          pyarrow.Table.from_arrays([n_legs, animals], names=names)
          """,
          %{}
        )

      assert {:ok, %Adbc.IngestResult{} = result} = Connection.ingest(conn, py_table)
      assert result.num_rows == 4
      assert result.table =~ "adbc_ingest_"

      {:ok, verify} =
        Connection.query(conn, "SELECT * FROM #{result.table} ORDER BY n_legs")

      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()
      assert map["n_legs"] == [2, 4, 5, 100]
      assert map["animals"] == ["Flamingo", "Horse", "Brittle stars", "Centipede"]
    end

    test "ingest! returns result or raises", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [Adbc.Column.s64([1, 2], name: "id")]

      assert %Adbc.IngestResult{} = result = Connection.ingest!(conn, columns)
      assert result.num_rows == 2
    end

    test "auto-names unnamed columns", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      columns = [
        Adbc.Column.s64([1, 2], name: "id"),
        Adbc.Column.string(["Alice", "Bob"]),
        Adbc.Column.s32([25, 30], name: "age")
      ]

      assert {:ok, %Adbc.IngestResult{} = result} = Connection.ingest(conn, columns)

      {:ok, verify} = Connection.query(conn, "SELECT * FROM #{result.table} ORDER BY id")
      map = verify |> Adbc.Result.materialize() |> Adbc.Result.to_map()

      assert map["id"] == [1, 2]
      assert map["col2"] == ["Alice", "Bob"]
      assert map["age"] == [25, 30]
    end

    test "accepts keyword list mixing columns and inferred lists", %{db: db} do
      conn = start_supervised!({Connection, database: db})

      assert {:ok, %Adbc.IngestResult{} = result} =
               Connection.ingest(conn,
                 id: [1, 2, 3],
                 name: Adbc.Column.string(["Alice", "Bob", "Charlie"])
               )

      {:ok, query_result} =
        Connection.query(conn, "SELECT * FROM #{result.table} ORDER BY id")

      map = query_result |> Adbc.Result.materialize() |> Adbc.Result.to_map()

      assert map["id"] == [1, 2, 3]
      assert map["name"] == ["Alice", "Bob", "Charlie"]
    end
  end
end

Adbc.download_driver!(:sqlite)
Adbc.download_driver!(:duckdb)

ExUnit.CaptureIO.capture_io(fn ->
  Pythonx.uv_init("""
  [project]
  name = "project"
  version = "0.0.0"
  requires-python = "==3.14.*"
  dependencies = [
    "pyarrow==23.0.0"
  ]
  """)
end)

pg_exclude =
  if System.find_executable("psql") do
    Adbc.download_driver!(:postgresql)
    []
  else
    [:postgresql]
  end

windows_exclude =
  case :os.type() do
    {:win32, _} -> [:unix]
    _ -> []
  end

ExUnit.start(exclude: pg_exclude ++ windows_exclude)

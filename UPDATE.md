## Update

### adbc and drivers

1. Update the contents in 3rd_party with latest (only root files and c/)
    from latest ADBC release: https://github.com/apache/arrow-adbc/releases/

2. Update @duckdb_version, @adbc_driver_version, and @adbc_tag in `update.exs`

3. Run elixir update.exs

### nanoarrow

To update the bundled nanoarrow, run the following command:

```bash
git clone https://github.com/apache/arrow-nanoarrow.git
cd arrow-nanoarrow
git checkout apache-arrow-nanoarrow-0.6.0
cd ..

rm -rf 3rd_party/nanoarrow
python3 arrow-nanoarrow/ci/scripts/bundle.py \
   --source-output-dir=3rd_party/nanoarrow \
   --include-output-dir=3rd_party/nanoarrow \
   --with-ipc \
   --with-flatcc
```

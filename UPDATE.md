## Update

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

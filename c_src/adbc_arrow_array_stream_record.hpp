#ifndef ADBC_ARROW_ARRAY_STREAM_RECORD_HPP
#define ADBC_ARROW_ARRAY_STREAM_RECORD_HPP
#pragma once

#include <arrow-adbc/adbc.h>
#include <erl_nif.h>

struct ArrowArrayStreamRecord {
  struct ArrowSchema schema{};
  struct ArrowArray values{};

  void destructor(ErlNifEnv *env) {
    if (schema.release)
      schema.release(&schema);
    if (values.release)
      values.release(&values);
  }
};

#endif // ADBC_ARROW_ARRAY_STREAM_RECORD_HPP

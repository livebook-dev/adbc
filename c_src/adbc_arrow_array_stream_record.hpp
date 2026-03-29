#ifndef ADBC_ARROW_ARRAY_STREAM_RECORD_HPP
#define ADBC_ARROW_ARRAY_STREAM_RECORD_HPP
#pragma once

#include <arrow-adbc/adbc.h>
#include <erl_nif.h>

struct ArrowArrayStreamRecord {
  struct ArrowSchema *schema = nullptr;
  struct ArrowArray *values = nullptr;

  /// Allocate memory for schema and values
  /// @return 0 if success, 1 if failed
  int allocate_schema_and_values() {
    this->schema = (struct ArrowSchema *)enif_alloc(sizeof(struct ArrowSchema));
    if (this->schema == nullptr) {
      return 1;
    }
    memset(this->schema, 0, sizeof(struct ArrowSchema));

    this->values = (struct ArrowArray *)enif_alloc(sizeof(struct ArrowArray));
    if (this->values == nullptr) {
      enif_free(this->schema);
      this->schema = nullptr;
      return 1;
    }
    memset(this->values, 0, sizeof(struct ArrowArray));

    return 0;
  }

  void release_schema_and_values() {
    if (this->schema) {
      if (this->schema->release) {
        this->schema->release(this->schema);
      }
      enif_free(this->schema);
      this->schema = nullptr;
    }

    if (this->values) {
      if (this->values->release) {
        this->values->release(this->values);
      }
      enif_free(this->values);
      this->values = nullptr;
    }
  }
};

#endif // ADBC_ARROW_ARRAY_STREAM_RECORD_HPP

#ifndef ADBC_ARROW_SCHEMA_HPP
#define ADBC_ARROW_SCHEMA_HPP
#pragma once

#include <arrow-adbc/adbc.h>
#include <cstdbool>
#include <cstdint>
#include <erl_nif.h>
#include <map>
#include <stdio.h>
#include <string>
#include <vector>

#include "adbc_arrow_array_stream_record.hpp"
#include "adbc_arrow_metadata.hpp"
#include "adbc_column.hpp"
#include "adbc_consts.h"
#include "nif_utils.hpp"

static int arrow_schema_to_nif_term(ErlNifEnv *env, struct ArrowSchema *schema,
                                    struct ArrowArray *array, uint64_t level,
                                    std::vector<ERL_NIF_TERM> &out_terms,
                                    ERL_NIF_TERM &value_type,
                                    ERL_NIF_TERM &metadata,
                                    ERL_NIF_TERM &error);

static int get_struct_schema(ErlNifEnv *env, struct ArrowSchema *schema,
                             struct ArrowArray *array, uint64_t level,
                             std::vector<ERL_NIF_TERM> &children,
                             std::vector<ERL_NIF_TERM> &fields,
                             ERL_NIF_TERM &error) {
  if (schema->n_children > 0 && schema->children == nullptr) {
    error = encode_error(env, "invalid ArrowSchema, schema->children == "
                              "nullptr while schema->n_children > 0");
    return 1;
  }
  children.resize(schema->n_children);
  fields.resize(schema->n_children);
  for (int64_t child_i = 0; child_i < schema->n_children; child_i++) {
    struct ArrowSchema *child_schema = schema->children[child_i];
    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM child_type;
    ERL_NIF_TERM child_metadata;
    if (arrow_schema_to_nif_term(env, child_schema, nullptr, level + 1,
                                 childrens, child_type, child_metadata,
                                 error) != 0) {
      return 1;
    }

    fields[child_i] =
        make_adbc_field(env, child_schema, child_type, child_metadata);

    if (level == 0) {
      auto record = fine::make_resource<ArrowArrayStreamRecord>();
      struct ArrowArray *child_array = array->children[child_i];
      ArrowSchemaDeepCopy(child_schema, &record->schema);
      ArrowArrayMove(child_array, &record->values);
      memset(array->children[child_i], 0, sizeof(struct ArrowArray));
      ERL_NIF_TERM data_ref = fine::encode(env, record);

      children[child_i] = make_adbc_column(env, child_schema, child_type,
                                           child_metadata, data_ref);
    } else {
      children[child_i] = fields[child_i];
    }
  }

  return 0;
}

static int get_run_end_encoded_schema(ErlNifEnv *env,
                                      struct ArrowSchema *schema,
                                      uint64_t level,
                                      ERL_NIF_TERM &run_ends_schema,
                                      ERL_NIF_TERM &error) {
  if (schema->n_children != 2) {
    return encode_error(
        env, "invalid ArrowSchema (run_end_encoded), schema->n_children != 2");
  }
  if (schema->children == nullptr) {
    return encode_error(
        env,
        "invalid ArrowArray (run_end_encoded), schema->children == nullptr");
  }
  if (strcmp("run_ends", schema->children[0]->name) != 0) {
    return encode_error(env, "invalid ArrowSchema (run_end_encoded), its "
                             "first child is not named run_ends");
  }
  if (strcmp("values", schema->children[1]->name) != 0) {
    return encode_error(env, "invalid ArrowSchema (run_end_encoded), its "
                             "second child is not named values");
  }

  std::vector<ERL_NIF_TERM> children(2);
  for (int64_t child_i = 0; child_i < 2; child_i++) {
    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM child_type;
    ERL_NIF_TERM child_metadata;
    if (arrow_schema_to_nif_term(env, schema->children[child_i], nullptr,
                                 level + 1, childrens, child_type,
                                 child_metadata, error) != 0) {
      return 1;
    }

    children[child_i] = make_adbc_field(env, schema->children[child_i],
                                        child_type, child_metadata);
  }

  // Return type as {:run_end_encoded, run_ends_field, values_field}
  run_ends_schema = enif_make_tuple3(
      env, fine::encode(env, atoms::run_end_encoded), children[0], children[1]);
  return 0;
}

static int get_map_schema(ErlNifEnv *env, struct ArrowSchema *schema,
                          uint64_t level, ERL_NIF_TERM &map_kv_schema,
                          ERL_NIF_TERM &error) {
  // From
  // https://arrow.apache.org/docs/format/CDataInterface.html#data-type-description-format-strings
  //
  //   As specified in the Arrow columnar format, the map type has a single
  //   child type named entries, itself a 2-child struct type of (key, value).
  if (schema->children == nullptr) {
    return encode_error(
        env, "invalid ArrowSchema (map), schema->children == nullptr");
  }
  if (schema->n_children != 1) {
    return encode_error(env,
                        "invalid ArrowSchema (map), schema->n_children != 1");
  }

  struct ArrowSchema *entries_schema = schema->children[0];
  if (strcmp("entries", entries_schema->name) != 0) {
    return encode_error(
        env,
        "invalid ArrowSchema (map), its single child is not named entries");
  }
  if (entries_schema->n_children != 2) {
    return encode_error(
        env, "invalid ArrowSchema (map), its entries n_children != 2");
  }

  ERL_NIF_TERM key_schema, value_schema;
  int kv = 0;
  for (int64_t child_i = 0; child_i < 2; child_i++) {
    struct ArrowSchema *entry_schema = entries_schema->children[child_i];
    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM child_type;
    ERL_NIF_TERM child_metadata;
    if (strcmp("key", entry_schema->name) == 0) {
      if (arrow_schema_to_nif_term(env, entry_schema, nullptr, level + 1,
                                   childrens, child_type, child_metadata,
                                   error) != 0) {
        return 1;
      }

      key_schema =
          make_adbc_field(env, entry_schema, child_type, child_metadata);
      kv |= 0x1;
    } else if (strcmp("value", entry_schema->name) == 0) {
      if (arrow_schema_to_nif_term(env, entry_schema, nullptr, level + 1,
                                   childrens, child_type, child_metadata,
                                   error) != 0) {
        return 1;
      }

      value_schema =
          make_adbc_field(env, entry_schema, child_type, child_metadata);
      kv |= 0x2;
    } else {
      return 1;
    }
  }

  if (kv != 3) {
    return 1;
  }

  ERL_NIF_TERM map_kv_keys[] = {fine::encode(env, atoms::key),
                                fine::encode(env, atoms::value)};
  ERL_NIF_TERM map_kv_values[] = {key_schema, value_schema};
  // only fail if there are duplicated keys
  // so we don't need to check the return value
  enif_make_map_from_arrays(env, map_kv_keys, map_kv_values, 2, &map_kv_schema);
  return 0;
}

static int get_list_element_schema(ErlNifEnv *env, struct ArrowSchema *schema,
                                   uint64_t level, ERL_NIF_TERM &element_schema,
                                   ERL_NIF_TERM &error) {
  if (schema->children == nullptr) {
    return encode_error(
        env, "invalid ArrowSchema (list), schema->children == nullptr");
  }
  if (schema->n_children != 1) {
    return encode_error(env,
                        "invalid ArrowSchema (list), schema->n_children != 1");
  }

  struct ArrowSchema *items_schema = schema->children[0];
  if (!(strcmp("item", items_schema->name) == 0 ||
        strcmp("l", items_schema->name) == 0)) {
    return encode_error(env, "invalid ArrowSchema (list), its single "
                             "child is not named 'item' or 'l'");
  }

  std::vector<ERL_NIF_TERM> childrens;
  ERL_NIF_TERM child_type;
  ERL_NIF_TERM child_metadata;
  if (arrow_schema_to_nif_term(env, items_schema, nullptr, level + 1, childrens,
                               child_type, child_metadata, error) != 0) {
    return 1;
  }

  // Always use "item" as the canonical name for list elements, regardless of
  // what the driver provides; using "item" appears to be conventional but
  // duckdb uses "l"
  element_schema =
      make_adbc_field(env, fine::encode(env, std::string_view("item")),
                      child_type, child_metadata);
  return 0;
}

static int arrow_schema_to_nif_term(ErlNifEnv *env, struct ArrowSchema *schema,
                                    struct ArrowArray *array,
                                    std::vector<ERL_NIF_TERM> &out_terms,
                                    ERL_NIF_TERM &error) {
  ERL_NIF_TERM type_term, metadata;
  int level = 0;
  return arrow_schema_to_nif_term(env, schema, array, level, out_terms,
                                  type_term, metadata, error);
}

static int arrow_schema_to_nif_term(ErlNifEnv *env, struct ArrowSchema *schema,
                                    struct ArrowArray *array, uint64_t level,
                                    std::vector<ERL_NIF_TERM> &out_terms,
                                    ERL_NIF_TERM &type_term,
                                    ERL_NIF_TERM &metadata,
                                    ERL_NIF_TERM &error) {
  static const std::map<std::string, std::vector<fine::Atom>>
      primitiveFormatMapping = {
          {"n", {atoms::nil}},
          {"b", {atoms::boolean}},
          {"c", {atoms::s8}},
          {"C", {atoms::u8}},
          {"s", {atoms::s16}},
          {"S", {atoms::u16}},
          {"i", {atoms::s32}},
          {"I", {atoms::u32}},
          {"l", {atoms::s64}},
          {"L", {atoms::u64}},
          {"e", {atoms::f16}},
          {"f", {atoms::f32}},
          {"g", {atoms::f64}},
          {"z", {atoms::binary}},
          {"Z", {atoms::large_binary}},
          {"vz", {atoms::binary_view}},
          {"u", {atoms::string}},
          {"U", {atoms::large_string}},
          {"vu", {atoms::string_view}},
          {"tdD", {atoms::date32}},
          {"tdm", {atoms::date64}},
          {"tts", {atoms::time32, atoms::seconds}},
          {"ttm", {atoms::time32, atoms::milliseconds}},
          {"ttu", {atoms::time64, atoms::microseconds}},
          {"ttn", {atoms::time64, atoms::nanoseconds}},
          {"tDs", {atoms::duration, atoms::seconds}},
          {"tDm", {atoms::duration, atoms::milliseconds}},
          {"tDu", {atoms::duration, atoms::microseconds}},
          {"tDn", {atoms::duration, atoms::nanoseconds}},
          {"tiM", {atoms::interval, atoms::month}},
          {"tiD", {atoms::interval, atoms::day_time}},
          {"tin", {atoms::interval, atoms::month_day_nano}},
      };
  if (schema == nullptr) {
    error =
        encode_error(env, "invalid ArrowSchema (nullptr) when invoking next");
    return 1;
  }
  if (level == 0 && array == nullptr) {
    error = encode_error(
        env, "invalid ArrowArray (nullptr) is nullptr at top-level entry");
    return 1;
  }

  char err_msg_buf[256] = {'\0'};
  const char *format = schema->format ? schema->format : "";
  ERL_NIF_TERM children_term{};
  size_t format_len = strlen(format);

  type_term = fine::encode(env, atoms::nil);
  std::vector<ERL_NIF_TERM> children;
  NANOARROW_RETURN_NOT_OK(
      arrow_metadata_to_nif_term(env, schema->metadata, &metadata));

  if (schema->dictionary != nullptr) {
    // NANOARROW_TYPE_DICTIONARY
    //
    // For dictionary-encoded arrays, the ArrowSchema.format string
    // encodes the index type. The dictionary value type can be read
    // from the ArrowSchema.dictionary structure.
    //
    // The same holds for ArrowArray structure: while the parent
    // structure points to the index data, the ArrowArray.dictionary
    // points to the dictionary values array.
    type_term = fine::encode(env, atoms::dictionary);

    // Get the value type from schema->dictionary
    std::vector<ERL_NIF_TERM> childrens;
    ERL_NIF_TERM value_type;
    ERL_NIF_TERM value_metadata;
    if (arrow_schema_to_nif_term(env, schema->dictionary, nullptr, level + 1,
                                 childrens, value_type, value_metadata,
                                 error) != 0) {
      return 1;
    }

    // The parent schema's format encodes the index (key) type
    // Build key field from the parent format and value field from dictionary
    // schema
    auto key_iter = primitiveFormatMapping.find(format);
    ERL_NIF_TERM key_type_term;
    if (key_iter != primitiveFormatMapping.end() &&
        key_iter->second.size() == 1) {
      key_type_term = fine::encode(env, key_iter->second[0]);
    } else {
      key_type_term = fine::encode(env, atoms::s32); // default to s32 for index
    }
    ERL_NIF_TERM key_field =
        make_adbc_field(env, fine::encode(env, std::string_view("key")),
                        key_type_term, fine::encode(env, atoms::nil));
    ERL_NIF_TERM value_field =
        make_adbc_field(env, schema->dictionary, value_type, value_metadata);

    type_term = enif_make_tuple3(env, fine::encode(env, atoms::dictionary),
                                 key_field, value_field);
    children_term = make_adbc_column(env, schema, type_term, metadata);
    return 0;
  }

  auto iter = primitiveFormatMapping.find(format);
  if (iter != primitiveFormatMapping.end()) {
    if (iter->second.size() == 1) {
      type_term = fine::encode(env, iter->second[0]);
    } else {
      std::vector<ERL_NIF_TERM> atom_terms;
      for (const auto &a : iter->second)
        atom_terms.push_back(fine::encode(env, a));
      type_term = enif_make_tuple_from_array(env, atom_terms.data(),
                                             (unsigned)atom_terms.size());
    }
    children_term = make_adbc_column(env, schema, type_term, metadata);
  }

  bool format_processed = true;
  if (format_len == 1) {
    format_processed = iter != primitiveFormatMapping.end();
  } else if (format_len == 2) {
    if (strncmp("+s", format, 2) == 0) {
      // NANOARROW_TYPE_STRUCT
      std::vector<ERL_NIF_TERM> fields;
      if (get_struct_schema(env, schema, array, level, children, fields,
                            error) != 0) {
        return 1;
      }

      // Type always uses Fields (never Columns)
      ERL_NIF_TERM fields_term = enif_make_list_from_array(
          env, fields.data(), (unsigned)fields.size());
      children_term = enif_make_list_from_array(env, children.data(),
                                                (unsigned)children.size());
      type_term =
          enif_make_tuple2(env, fine::encode(env, atoms::struct_), fields_term);
    } else if (strncmp("+r", format, 2) == 0) {
      // NANOARROW_TYPE_RUN_END_ENCODED (maybe in nanoarrow v0.6.0)
      // https://github.com/apache/arrow-nanoarrow/pull/507
      ERL_NIF_TERM run_ends_schema;
      if (get_run_end_encoded_schema(env, schema, level, run_ends_schema,
                                     error) != 0) {
        return 1;
      }

      type_term = run_ends_schema;
      children_term = make_adbc_column(env, schema, type_term, metadata);
    } else if (strncmp("+m", format, 2) == 0) {
      // NANOARROW_TYPE_MAP
      ERL_NIF_TERM map_kv_schema;
      if (get_map_schema(env, schema, level, map_kv_schema, error) != 0) {
        return 1;
      }

      type_term =
          enif_make_tuple2(env, fine::encode(env, atoms::map), map_kv_schema);
      children_term = make_adbc_column(env, schema, type_term, metadata);
    } else if (strncmp("+l", format, 2) == 0) {
      // NANOARROW_TYPE_LIST
      ERL_NIF_TERM elem_schema;
      if (get_list_element_schema(env, schema, level, elem_schema, error) !=
          0) {
        return 1;
      }

      type_term =
          enif_make_tuple2(env, fine::encode(env, atoms::list), elem_schema);
      children_term = make_adbc_column(env, schema, type_term, metadata);
    } else if (strncmp("+L", format, 2) == 0) {
      // NANOARROW_TYPE_LARGE_LIST
      ERL_NIF_TERM elem_schema;
      if (get_list_element_schema(env, schema, level, elem_schema, error) !=
          0) {
        return 1;
      }

      type_term = enif_make_tuple2(env, fine::encode(env, atoms::large_list),
                                   elem_schema);
      children_term = make_adbc_column(env, schema, type_term, metadata);
    } else if (strncmp("vu", format, 2) == 0 || strncmp("vz", format, 2) == 0) {
      // NANOARROW_TYPE_STRING_VIEW
      // NANOARROW_TYPE_BINARY_VIEW
      // type_term and children_term already set via primitiveFormatMapping
      // above
      format_processed = iter != primitiveFormatMapping.end();
    } else {
      format_processed = false;
    }
  } else if (format_len >= 3) {
    // handle all formats that start with `t` (temporal types)
    if (format[0] == 't') {
      if (format_len == 3) {
        // primitiveFormatMapping contains all temporal that have 3 characters
        format_processed = iter != primitiveFormatMapping.end();
      } else if (format_len >= 4 && format[1] == 's' && format[3] == ':') {
        // according to the arrow spec:
        //   The timezone string is appended as-is after the colon character :,
        //   without any quotes. If the timezone is empty, the colon : must
        //   still be included.
        // so the format length for timestamps must be >= 4

        // possible format strings:
        // tss: - timestamp [seconds]
        // tsm: - timestamp [milliseconds]
        // tsu: - timestamp [microseconds]
        // tsn: - timestamp [nanoseconds]
        //
        // if there're any timezone infomation
        // it should be in the format like `tsu:timezone`
        // NANOARROW_TYPE_TIMESTAMP
        ERL_NIF_TERM term_unit;
        ERL_NIF_TERM term_timezone = fine::encode(env, atoms::nil);
        switch (format[2]) {
        case 's': // seconds
          term_unit = fine::encode(env, atoms::seconds);
          break;
        case 'm': // milliseconds
          term_unit = fine::encode(env, atoms::milliseconds);
          break;
        case 'u': // microseconds
          term_unit = fine::encode(env, atoms::microseconds);
          break;
        case 'n': // nanoseconds
          term_unit = fine::encode(env, atoms::nanoseconds);
          break;
        default:
          format_processed = false;
        }

        if (format_processed) {
          if (format_len > 4 && format[3] == ':') {
            std::string timezone(&format[4]);
            term_timezone = fine::encode(env, timezone);
          }
          type_term = enif_make_tuple3(env, fine::encode(env, atoms::timestamp),
                                       term_unit, term_timezone);
          children_term = make_adbc_column(env, schema, type_term, metadata);
        }
      } else {
        format_processed = false;
      }
    } else {
      if (format_len == 3 && strncmp("+vl", format, 3) == 0) {
        // NANOARROW_TYPE_LIST(VIEW)
        ERL_NIF_TERM elem_schema;
        if (get_list_element_schema(env, schema, level, elem_schema, error) !=
            0) {
          return 1;
        }

        type_term = enif_make_tuple2(env, fine::encode(env, atoms::list_view),
                                     elem_schema);
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (format_len == 3 && strncmp("+vL", format, 3) == 0) {
        // NANOARROW_TYPE_LARGE_LIST(VIEW)
        ERL_NIF_TERM elem_schema;
        if (get_list_element_schema(env, schema, level, elem_schema, error) !=
            0) {
          return 1;
        }

        type_term = enif_make_tuple2(
            env, fine::encode(env, atoms::large_list_view), elem_schema);
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (strncmp("+w:", format, 3) == 0) {
        // NANOARROW_TYPE_FIXED_SIZE_LIST
        unsigned n_items = 0;
        for (size_t i = 3; i < format_len; i++) {
          n_items = n_items * 10 + (format[i] - '0');
        }
        ERL_NIF_TERM elem_schema;
        if (get_list_element_schema(env, schema, level, elem_schema, error) !=
            0) {
          return 1;
        }

        type_term =
            enif_make_tuple3(env, fine::encode(env, atoms::fixed_size_list),
                             elem_schema, enif_make_int64(env, n_items));
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (strncmp("w:", format, 2) == 0) {
        // NANOARROW_TYPE_FIXED_SIZE_BINARY
        size_t nbytes = 0;
        for (size_t i = 2; i < format_len; i++) {
          nbytes = nbytes * 10 + (format[i] - '0');
        }
        type_term = kAdbcColumnTypeFixedSizeBinary(nbytes);
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (format_len > 4 && (strncmp("+ud:", format, 4) == 0)) {
        // NANOARROW_TYPE_DENSE_UNION
        type_term = fine::encode(env, atoms::dense_union);
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (format_len > 4 && (strncmp("+us:", format, 4) == 0)) {
        // NANOARROW_TYPE_SPARSE_UNION
        type_term = fine::encode(env, atoms::sparse_union);
        children_term = make_adbc_column(env, schema, type_term, metadata);
      } else if (strncmp("d:", format, 2) == 0) {
        // NANOARROW_TYPE_DECIMAL128
        // NANOARROW_TYPE_DECIMAL256
        //
        // format should match `d:P,S[,N]`
        // where P is precision, S is scale, N is bits
        // N is optional and defaults to 128
        int precision = 0;
        int scale = 0;
        int bits = 0;
        int *d[3] = {&precision, &scale, &bits};
        int index = 0;
        for (size_t i = 2; i < format_len; i++) {
          if (format[i] == ',') {
            if (index < 2) {
              index++;
            } else {
              format_processed = false;
              break;
            }
            continue;
          }

          *d[index] = *d[index] * 10 + (format[i] - '0');
        }

        if (format_processed) {
          if (bits == 0)
            bits = 128;
          type_term = (bits == 128)
                          ? kAdbcColumnTypeDecimal128(precision, scale)
                          : kAdbcColumnTypeDecimal256(precision, scale);
          children_term = make_adbc_column(env, schema, type_term, metadata);
        }
      } else {
        format_processed = false;
      }
    }
  } else {
    format_processed = false;
  }

  if (!format_processed) {
    snprintf(err_msg_buf, sizeof(err_msg_buf) / sizeof(err_msg_buf[0]),
             "not yet implemented for format: `%s`", schema->format);
    error = encode_error(env, err_msg_buf);
    return 1;
    // printf("not implemented for format: `%s`\r\n", schema->format);
    // printf("length: %lld\r\n", values->length);
    // printf("null_count: %lld\r\n", values->null_count);
    // printf("offset: %lld\r\n", values->offset);
    // printf("n_buffers: %lld\r\n", values->n_buffers);
    // printf("n_children: %lld\r\n", values->n_children);
    // printf("buffers: %p\r\n", values->buffers);
  }

  out_terms.clear();
  out_terms.emplace_back(children_term);
  return 0;
}

#endif // ADBC_ARROW_ARRAY_HPP

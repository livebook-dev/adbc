#pragma once

#include <arrow-adbc/adbc.h>
#include <cinttypes>
#include <cstdbool>
#include <cstdint>
#include <erl_nif.h>
#include <stdexcept>
#include <string>
#include <vector>

#include "shared.hpp"

namespace adbc_nif {

struct ColumnResult {
  fine::Term type;
  fine::Term data;
  fine::Term metadata;
};

// Forward declaration for recursive calls.
static ColumnResult
arrow_column(ErlNifEnv *env, struct ArrowSchema *schema,
             struct ArrowArray *values, int64_t offset, int64_t count,
             fine::ResourcePtr<ArrowArrayStreamRecord> resource);

static ERL_NIF_TERM string_views_from_buffer(ErlNifEnv *env,
                                             struct ArrowArray *values,
                                             int64_t element_offset,
                                             int64_t element_count) {
  int64_t n_data_buffers = values->n_buffers - 2;
  const uint8_t *validity_bitmap = (const uint8_t *)values->buffers[0];
  const uint8_t *views_buffer = (const uint8_t *)values->buffers[1];
  const uint8_t *const *data_buffers =
      (const uint8_t *const *)(values->buffers + 2);
  if (n_data_buffers < 0) {
    throw std::invalid_argument(
        "invalid n_buffers for ArrowArray: expected at least 2, got " +
        std::to_string(n_data_buffers + 2));
  }
  std::vector<fine::Term> terms(element_count);

  for (int64_t i = element_offset; i < element_offset + element_count; i++) {
    bool is_valid = (validity_bitmap == nullptr) ||
                    (validity_bitmap[i / 8] & (1 << (i % 8)));

    if (!is_valid) {
      terms[i - element_offset] = fine::encode(env, atoms::nil);
      continue;
    }

    const uint8_t *view = views_buffer + i * 16;
    int32_t length;
    memcpy(&length, view, 4);

    if (length <= 12) {
      // Short string: data is stored inline in bytes [4..4+length)
      terms[i - element_offset] = fine::make_new_binary(
          env, reinterpret_cast<const char *>(view + 4), (size_t)length);
    } else {
      // Long string: bytes [8..12) = buf_index, bytes [12..16) = offset
      int32_t buf_index, buf_offset;
      memcpy(&buf_index, view + 8, 4);
      memcpy(&buf_offset, view + 12, 4);
      terms[i - element_offset] = fine::make_new_binary(
          env,
          reinterpret_cast<const char *>(data_buffers[buf_index] + buf_offset),
          (size_t)length);
    }
  }

  return fine::encode(env, terms);
}

// Slice a validity bitmap at the given element offset. Returns nullopt if the
// bitmap is null or null_count is 0 (all values valid).
static std::optional<fine::Term>
slice_validity_bitmap(ErlNifEnv *env, const uint8_t *bitmap, int64_t offset,
                      int64_t count, int64_t null_count,
                      fine::ResourcePtr<ArrowArrayStreamRecord> resource,
                      int &bit_offset_out) {
  bit_offset_out = (int)(offset % 8);
  if (bitmap == nullptr || null_count == 0) {
    return std::nullopt;
  } else {
    size_t bitmap_start = offset / 8;
    size_t total_bitmap_bytes = (offset + count + 7) / 8 - bitmap_start;
    return fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(bitmap + bitmap_start),
        total_bitmap_bytes);
  }
}

template <typename OffsetT>
static fine::Term
make_binary_data(ErlNifEnv *env, struct ArrowArray *values, int64_t offset,
                 int64_t count,
                 fine::ResourcePtr<ArrowArrayStreamRecord> resource) {
  if (values->n_buffers != 3) {
    throw std::invalid_argument(
        "invalid n_buffers for ArrowArray: expected 3, got " +
        std::to_string(values->n_buffers));
  }
  const OffsetT *offsets_ptr = (const OffsetT *)values->buffers[1];
  const uint8_t *data_ptr = (const uint8_t *)values->buffers[2];
  const uint8_t *validity_bitmap = (const uint8_t *)values->buffers[0];

  fine::Term offsets_term = fine::make_resource_binary(
      env, resource, reinterpret_cast<const char *>(&offsets_ptr[offset]),
      (count + 1) * sizeof(OffsetT));

  OffsetT data_start = offsets_ptr[offset];
  OffsetT data_end = offsets_ptr[offset + count];
  fine::Term data_term = fine::make_resource_binary(
      env, resource, reinterpret_cast<const char *>(data_ptr + data_start),
      data_end - data_start);

  int bit_offset;
  auto validity =
      slice_validity_bitmap(env, validity_bitmap, offset, count,
                            values->null_count, resource, bit_offset);

  auto data =
      ExAdbcBinaryData{offsets_term, data_term, validity, (uint64_t)bit_offset};
  return fine::encode(env, data);
}

static fine::Term
make_buffer_data(ErlNifEnv *env, struct ArrowArray *values, int64_t offset,
                 int64_t count, size_t element_bytes,
                 fine::ResourcePtr<ArrowArrayStreamRecord> resource) {
  if (values->n_buffers != 2) {
    throw std::invalid_argument(
        "invalid n_buffers for ArrowArray: expected 2, got " +
        std::to_string(values->n_buffers));
  }
  const uint8_t *value_buffer = (const uint8_t *)values->buffers[1];
  const uint8_t *validity_bitmap = (const uint8_t *)values->buffers[0];

  fine::Term data_binary = fine::make_resource_binary(
      env, resource,
      reinterpret_cast<const char *>(&value_buffer[element_bytes * offset]),
      element_bytes * count);

  int bit_offset;
  auto validity =
      slice_validity_bitmap(env, validity_bitmap, offset, count,
                            values->null_count, resource, bit_offset);

  auto data = ExAdbcBufferData{data_binary, validity, (uint64_t)bit_offset};
  return fine::encode(env, data);
}

static fine::Term
make_boolean_data(ErlNifEnv *env, struct ArrowArray *values, int64_t offset,
                  int64_t count,
                  fine::ResourcePtr<ArrowArrayStreamRecord> resource) {
  if (values->n_buffers != 2) {
    throw std::invalid_argument("invalid n_buffers for ArrowArray (format=b)");
  }
  const uint8_t *data_buf = (const uint8_t *)values->buffers[1];
  size_t data_start = offset / 8;
  size_t total_data_bytes = (offset + count + 7) / 8 - data_start;
  fine::Term data_term = fine::make_resource_binary(
      env, resource, reinterpret_cast<const char *>(data_buf + data_start),
      total_data_bytes);
  const uint8_t *validity_bitmap = (const uint8_t *)values->buffers[0];
  int bit_offset_val;
  auto validity =
      slice_validity_bitmap(env, validity_bitmap, offset, count,
                            values->null_count, resource, bit_offset_val);
  auto data = ExAdbcBooleanData{data_term, validity, (uint64_t)bit_offset_val,
                                (uint64_t)count};
  return fine::encode(env, data);
}

static fine::Term arrow_metadata_to_nif_term(ErlNifEnv *env,
                                             const char *metadata) {
  std::vector<ERL_NIF_TERM> metadata_keys, metadata_values;
  if (metadata == nullptr) {
    return fine::encode(env, atoms::nil);
  }

  struct ArrowMetadataReader metadata_reader{};
  struct ArrowStringView key;
  struct ArrowStringView value;
  NANOARROW_THROW_NOT_OK(ArrowMetadataReaderInit(&metadata_reader, metadata));
  while (ArrowMetadataReaderRead(&metadata_reader, &key, &value) ==
         NANOARROW_OK) {
    metadata_keys.push_back(
        fine::make_new_binary(env, key.data, (size_t)key.size_bytes));
    metadata_values.push_back(
        fine::make_new_binary(env, value.data, (size_t)value.size_bytes));
  }
  if (metadata_keys.size() > 0) {
    ERL_NIF_TERM metadata_term;
    enif_make_map_from_arrays(env, metadata_keys.data(), metadata_values.data(),
                              (unsigned)metadata_keys.size(), &metadata_term);
    return metadata_term;
  } else {
    return fine::encode(env, atoms::nil);
  }
}

// Convenience overload: processes the full array (offset=0, count=-1).
static ColumnResult
arrow_to_column(ErlNifEnv *env, struct ArrowSchema *schema,
                struct ArrowArray *values,
                fine::ResourcePtr<ArrowArrayStreamRecord> resource) {
  return arrow_column(env, schema, values, 0, -1, resource);
}

static ColumnResult arrow_dictionary_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowSchema *schema,
    struct ArrowArray *values, int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (values->dictionary == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (dictionary), values->dictionary == nullptr");
  }

  // Index type is encoded in the parent's format string.
  fine::Term idx_type;
  size_t idx_bytes;
  if (fmt == "c") {
    idx_type = fine::encode(env, atoms::s8);
    idx_bytes = 1;
  } else if (fmt == "C") {
    idx_type = fine::encode(env, atoms::u8);
    idx_bytes = 1;
  } else if (fmt == "s") {
    idx_type = fine::encode(env, atoms::s16);
    idx_bytes = 2;
  } else if (fmt == "S") {
    idx_type = fine::encode(env, atoms::u16);
    idx_bytes = 2;
  } else if (fmt == "i") {
    idx_type = fine::encode(env, atoms::s32);
    idx_bytes = 4;
  } else if (fmt == "I") {
    idx_type = fine::encode(env, atoms::u32);
    idx_bytes = 4;
  } else if (fmt == "l") {
    idx_type = fine::encode(env, atoms::s64);
    idx_bytes = 8;
  } else if (fmt == "L") {
    idx_type = fine::encode(env, atoms::u64);
    idx_bytes = 8;
  } else {
    idx_type = fine::encode(env, atoms::s32);
    idx_bytes = 4;
  }

  auto idx_data =
      make_buffer_data(env, values, offset, count, idx_bytes, resource);

  auto val_result =
      arrow_to_column(env, schema->dictionary, values->dictionary, resource);
  auto dict_name = std::string(
      schema->dictionary->name == nullptr ? "" : schema->dictionary->name);

  auto type = fine::encode(
      env,
      std::tuple(atoms::dictionary,
                 ExAdbcField{std::string("key"), idx_type,
                             fine::encode(env, atoms::nil)},
                 ExAdbcField{dict_name, val_result.type, val_result.metadata}));
  auto data =
      fine::encode(env, ExAdbcDictionaryData{idx_data, val_result.data});
  return {type, data, metadata};
}

static ColumnResult
arrow_struct_to_column(ErlNifEnv *env, struct ArrowSchema *schema,
                       struct ArrowArray *values, int64_t offset, int64_t count,
                       fine::ResourcePtr<ArrowArrayStreamRecord> resource,
                       fine::Term metadata) {
  if (schema->n_children > 0 && schema->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowSchema (struct), children == nullptr");
  }
  if (values->n_children != schema->n_children) {
    throw std::invalid_argument(
        "invalid ArrowArray (struct), n_children mismatch");
  }

  std::vector<fine::Term> fields;
  std::vector<fine::Term> child_data_terms;
  fields.reserve(schema->n_children);
  child_data_terms.reserve(schema->n_children);

  for (int64_t child_i = 0; child_i < schema->n_children; child_i++) {
    struct ArrowSchema *child_schema = schema->children[child_i];
    struct ArrowArray *child_values = values->children[child_i];
    auto child =
        arrow_column(env, child_schema, child_values, offset, count, resource);
    auto name =
        std::string(child_schema->name == nullptr ? "" : child_schema->name);
    fields.push_back(
        fine::encode(env, ExAdbcField{name, child.type, child.metadata}));
    child_data_terms.push_back(child.data);
  }

  const uint8_t *struct_bitmap = (const uint8_t *)values->buffers[0];
  int struct_bit_offset;
  auto struct_validity =
      slice_validity_bitmap(env, struct_bitmap, offset, count,
                            values->null_count, resource, struct_bit_offset);
  auto values_list = fine::encode(env, child_data_terms);

  auto type = fine::encode(env, std::tuple(atoms::struct_, std::move(fields)));
  auto data = fine::encode(env, ExAdbcStructData{struct_validity,
                                                 (uint64_t)struct_bit_offset,
                                                 values_list});
  return {type, data, metadata};
}

static ColumnResult arrow_run_end_encoded_to_column(
    ErlNifEnv *env, struct ArrowSchema *schema, struct ArrowArray *values,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->n_children != 2 || values->n_children != 2) {
    throw std::invalid_argument(
        "invalid ArrowSchema (run_end_encoded), n_children != 2");
  }
  if (schema->children == nullptr || values->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (run_end_encoded), children == nullptr");
  }
  if (std::string_view(schema->children[0]->name) != "run_ends") {
    throw std::invalid_argument("invalid ArrowSchema (run_end_encoded), "
                                "first child is not named run_ends");
  }
  if (std::string_view(schema->children[1]->name) != "values") {
    throw std::invalid_argument("invalid ArrowSchema (run_end_encoded), "
                                "second child is not named values");
  }

  auto run_ends =
      arrow_to_column(env, schema->children[0], values->children[0], resource);
  auto vals =
      arrow_to_column(env, schema->children[1], values->children[1], resource);
  auto re_name0 = std::string(schema->children[0]->name);
  auto re_name1 = std::string(schema->children[1]->name);
  auto re_field0 = ExAdbcField{re_name0, run_ends.type, run_ends.metadata};
  auto re_field1 = ExAdbcField{re_name1, vals.type, vals.metadata};
  auto type = fine::encode(
      env, std::tuple(atoms::run_end_encoded, re_field0, re_field1));
  auto data = fine::encode(
      env, ExAdbcRunEndEncodedData{run_ends.data, vals.data, values->length,
                                   values->offset});
  return {type, data, metadata};
}

static ColumnResult
arrow_map_to_column(ErlNifEnv *env, struct ArrowSchema *schema,
                    struct ArrowArray *values, int64_t offset, int64_t count,
                    fine::ResourcePtr<ArrowArrayStreamRecord> resource,
                    fine::Term metadata) {
  if (schema->children == nullptr || schema->n_children != 1) {
    throw std::invalid_argument("invalid ArrowSchema (map), expected 1 child");
  }
  if (values->children == nullptr || values->n_children != 1) {
    throw std::invalid_argument("invalid ArrowArray (map), expected 1 child");
  }
  struct ArrowSchema *entries_schema = schema->children[0];
  struct ArrowArray *entries_values = values->children[0];
  if (std::string_view(entries_schema->name) != "entries") {
    throw std::invalid_argument(
        "invalid ArrowSchema (map), its single child is not named entries");
  }
  if (entries_schema->n_children != 2) {
    throw std::invalid_argument(
        "invalid ArrowSchema (map), entries n_children != 2");
  }

  struct ArrowSchema *key_schema = nullptr, *value_schema = nullptr;
  struct ArrowArray *key_values = nullptr, *value_values = nullptr;
  for (int64_t i = 0; i < 2; i++) {
    std::string_view entry_name = entries_schema->children[i]->name;
    if (entry_name == "key") {
      key_schema = entries_schema->children[i];
      key_values = entries_values->children[i];
    } else if (entry_name == "value") {
      value_schema = entries_schema->children[i];
      value_values = entries_values->children[i];
    }
  }
  if (key_schema == nullptr || value_schema == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowSchema (map), key or value field missing");
  }

  auto key_result = arrow_to_column(env, key_schema, key_values, resource);
  auto val_result = arrow_to_column(env, value_schema, value_values, resource);

  fine::Term key_field =
      fine::encode(env, ExAdbcField{std::string("key"), key_result.type,
                                    key_result.metadata});
  fine::Term value_field =
      fine::encode(env, ExAdbcField{std::string("value"), val_result.type,
                                    val_result.metadata});

  const int32_t *offsets_ptr = (const int32_t *)values->buffers[1];
  if (offsets_ptr == nullptr) {
    throw std::invalid_argument("invalid ArrowArray (map), offsets == nullptr");
  }
  ERL_NIF_TERM offsets_term = fine::make_resource_binary(
      env, resource, reinterpret_cast<const char *>(&offsets_ptr[offset]),
      (count + 1) * sizeof(int32_t));

  const uint8_t *bitmap_buffer = (const uint8_t *)values->buffers[0];
  int bit_offset_int;
  auto validity =
      slice_validity_bitmap(env, bitmap_buffer, offset, count,
                            values->null_count, resource, bit_offset_int);

  auto type = fine::encode(env, std::tuple(atoms::map, key_field, value_field));
  auto data = ExAdbcMapData{offsets_term, validity, key_result.data,
                            val_result.data, (uint64_t)bit_offset_int};
  return {type, fine::encode(env, data), metadata};
}

static ColumnResult arrow_list_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowSchema *schema,
    struct ArrowArray *values, int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->children == nullptr || schema->n_children != 1) {
    throw std::invalid_argument("invalid ArrowSchema (list), expected 1 child");
  }
  if (values->children == nullptr || values->n_children != 1) {
    throw std::invalid_argument("invalid ArrowArray (list), expected 1 child");
  }
  struct ArrowSchema *items_schema = schema->children[0];
  struct ArrowArray *items_values = values->children[0];
  std::string_view items_name = items_schema->name;
  if (items_name != "item" && items_name != "l") {
    throw std::invalid_argument(
        "invalid ArrowSchema (list), child not named 'item' or 'l'");
  }

  auto items = arrow_to_column(env, items_schema, items_values, resource);
  // Always use "item" as the canonical field name
  fine::Term item_field = fine::encode(
      env, ExAdbcField{std::string("item"), items.type, items.metadata});

  const uint8_t *bitmap_buffer = (const uint8_t *)values->buffers[0];
  int bit_offset;
  auto validity =
      slice_validity_bitmap(env, bitmap_buffer, offset, count,
                            values->null_count, resource, bit_offset);

  fine::Term type, offsets_term;
  if (fmt == "+l") {
    type = fine::encode(env, std::tuple(atoms::list, item_field));
    const int32_t *offsets_ptr = (const int32_t *)values->buffers[1];
    if (offsets_ptr == nullptr) {
      throw std::invalid_argument(
          "invalid ArrowArray (list), offsets == nullptr");
    }
    offsets_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&offsets_ptr[offset]),
        (count + 1) * sizeof(int32_t));
  } else {
    type = fine::encode(env, std::tuple(atoms::large_list, item_field));
    const int64_t *offsets_ptr = (const int64_t *)values->buffers[1];
    if (offsets_ptr == nullptr) {
      throw std::invalid_argument(
          "invalid ArrowArray (large_list), offsets == nullptr");
    }
    offsets_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&offsets_ptr[offset]),
        (count + 1) * sizeof(int64_t));
  }

  auto data =
      ExAdbcListData{offsets_term, validity, enif_make_list1(env, items.data),
                     (uint64_t)bit_offset};
  return {type, fine::encode(env, data), metadata};
}

static ColumnResult arrow_list_view_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowSchema *schema,
    struct ArrowArray *values, int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->children == nullptr || schema->n_children != 1) {
    throw std::invalid_argument(
        "invalid ArrowSchema (list view), expected 1 child");
  }
  if (values->children == nullptr || values->n_children != 1) {
    throw std::invalid_argument(
        "invalid ArrowArray (list view), expected 1 child");
  }
  struct ArrowSchema *items_schema = schema->children[0];
  struct ArrowArray *items_values = values->children[0];
  std::string_view items_name = items_schema->name;
  if (items_name != "item" && items_name != "l") {
    throw std::invalid_argument(
        "invalid ArrowSchema (list view), child not named 'item' or 'l'");
  }

  const void *offsets_ptr = values->buffers[1];
  const void *sizes_ptr = values->buffers[2];
  if (offsets_ptr == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (list view), offsets == nullptr");
  }
  if (sizes_ptr == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (list view), sizes == nullptr");
  }

  const uint8_t *bitmap_buffer = (const uint8_t *)values->buffers[0];
  // According to the Arrow spec the bitmap buffer is not required for child
  // values; clear it to avoid misreading
  items_values->buffers[0] = nullptr;
  auto items = arrow_to_column(env, items_schema, items_values, resource);
  items_values->buffers[0] = bitmap_buffer;

  auto item_field =
      ExAdbcField{std::string("item"), items.type, items.metadata};

  int bit_offset_int;
  auto validity =
      slice_validity_bitmap(env, bitmap_buffer, offset, count,
                            values->null_count, resource, bit_offset_int);

  fine::Term type, offsets_term, sizes_term;
  if (fmt == "+vl") {
    type = fine::encode(env, std::tuple(atoms::list_view, item_field));
    const int32_t *off32 = (const int32_t *)offsets_ptr;
    const int32_t *sz32 = (const int32_t *)sizes_ptr;
    offsets_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&off32[offset]),
        count * sizeof(int32_t));
    sizes_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&sz32[offset]),
        count * sizeof(int32_t));
  } else {
    type = fine::encode(env, std::tuple(atoms::large_list_view, item_field));
    const int64_t *off64 = (const int64_t *)offsets_ptr;
    const int64_t *sz64 = (const int64_t *)sizes_ptr;
    offsets_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&off64[offset]),
        count * sizeof(int64_t));
    sizes_term = fine::make_resource_binary(
        env, resource, reinterpret_cast<const char *>(&sz64[offset]),
        count * sizeof(int64_t));
  }

  auto data = ExAdbcListViewData{offsets_term, sizes_term, validity, items.data,
                                 (uint64_t)bit_offset_int};

  return {type, fine::encode(env, data), metadata};
}

static ColumnResult arrow_fixed_size_list_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowSchema *schema,
    struct ArrowArray *values, int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->children == nullptr || schema->n_children != 1) {
    throw std::invalid_argument(
        "invalid ArrowSchema (fixed_size_list), expected 1 child");
  }
  if (values->children == nullptr || values->n_children != 1) {
    throw std::invalid_argument(
        "invalid ArrowArray (fixed_size_list), expected 1 child");
  }
  unsigned n_items = std::stoul(std::string(fmt.substr(3)));

  struct ArrowSchema *items_schema = schema->children[0];
  struct ArrowArray *items_values = values->children[0];
  auto items = arrow_to_column(env, items_schema, items_values, resource);
  auto item_field =
      ExAdbcField{std::string("item"), items.type, items.metadata};
  const uint8_t *bitmap_buffer = (const uint8_t *)values->buffers[0];
  int bit_offset;
  auto validity =
      slice_validity_bitmap(env, bitmap_buffer, offset, count,
                            values->null_count, resource, bit_offset);

  return {
      fine::encode(env, std::tuple(atoms::fixed_size_list, item_field,
                                   (int64_t)n_items)),
      fine::encode(env, ExAdbcListData{enif_make_int(env, n_items), validity,
                                       enif_make_list1(env, items.data),
                                       (uint64_t)bit_offset}),
      metadata};
}

static ColumnResult arrow_fixed_size_binary_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowArray *values,
    int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  size_t nbytes = std::stoul(std::string(fmt.substr(2)));
  return {
      fine::encode(env, std::tuple(atoms::fixed_size_binary, (int64_t)nbytes)),
      make_buffer_data(env, values, offset, count, nbytes, resource), metadata};
}

static ColumnResult arrow_dense_union_to_column(
    ErlNifEnv *env, struct ArrowSchema *schema, struct ArrowArray *values,
    int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->n_children > 0 && schema->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowSchema (dense union), children == nullptr");
  }
  if (values->n_children > 0 && values->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (dense union), children == nullptr");
  }
  if (offset < 0 || offset >= values->length) {
    throw std::invalid_argument("invalid offset for ArrowArray (dense union)");
  }
  if ((offset + count) > values->length) {
    throw std::invalid_argument(
        "invalid offset/count for ArrowArray (dense union)");
  }
  if (values->n_buffers != 2) {
    throw std::invalid_argument(
        "invalid ArrowArray (dense union), n_buffers != 2");
  }

  const uint8_t *types_buffer = (const uint8_t *)values->buffers[0];
  const int32_t *offsets_buffer = (const int32_t *)values->buffers[1];
  std::vector<fine::Term> elements(count);
  for (int64_t child_i = offset; child_i < offset + count; child_i++) {
    uint8_t child_type = types_buffer[child_i];
    int32_t child_offset = offsets_buffer[child_i];
    if (child_type >= schema->n_children || child_type >= values->n_children) {
      throw std::invalid_argument(
          "invalid child type for ArrowArray (dense union)");
    }
    struct ArrowSchema *field_schema = schema->children[child_type];
    struct ArrowArray *field_array = values->children[child_type];
    auto field =
        arrow_column(env, field_schema, field_array, child_offset, 1, resource);
    ERL_NIF_TERM name_key =
        fine::encode(env, std::string_view(field_schema->name));
    ERL_NIF_TERM field_val = field.data;
    ERL_NIF_TERM element{};
    if (!enif_make_map_from_arrays(env, &name_key, &field_val, 1, &element)) {
      throw std::invalid_argument(
          "failed to enif_make_map_from_arrays for ArrowArray (dense union)");
    }
    elements[child_i - offset] = element;
  }
  return {fine::encode(env, atoms::dense_union), fine::encode(env, elements),
          metadata};
}

static ColumnResult arrow_sparse_union_to_column(
    ErlNifEnv *env, struct ArrowSchema *schema, struct ArrowArray *values,
    int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  if (schema->n_children > 0 && schema->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowSchema (sparse union), children == nullptr");
  }
  if (values->n_children > 0 && values->children == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (sparse union), children == nullptr");
  }
  if (offset < 0 || offset >= values->length) {
    throw std::invalid_argument("invalid offset for ArrowArray (sparse union)");
  }
  if ((offset + count) > values->length) {
    throw std::invalid_argument(
        "invalid offset/count for ArrowArray (sparse union)");
  }
  if (values->n_buffers != 1) {
    throw std::invalid_argument(
        "invalid ArrowArray (sparse union), n_buffers != 1");
  }

  const uint8_t *types_buffer = (const uint8_t *)values->buffers[0];
  std::vector<fine::Term> elements(count);
  for (int64_t child_i = offset; child_i < offset + count; child_i++) {
    uint8_t child_type = types_buffer[child_i];
    if (child_type >= schema->n_children || child_type >= values->n_children) {
      throw std::invalid_argument(
          "invalid child type for ArrowArray (sparse union)");
    }
    struct ArrowSchema *field_schema = schema->children[child_type];
    struct ArrowArray *field_array = values->children[child_type];
    auto field =
        arrow_column(env, field_schema, field_array, child_i, 1, resource);
    ERL_NIF_TERM name_key =
        fine::encode(env, std::string_view(field_schema->name));
    ERL_NIF_TERM field_val = field.data;
    ERL_NIF_TERM element{};
    if (!enif_make_map_from_arrays(env, &name_key, &field_val, 1, &element)) {
      throw std::invalid_argument("failed to enif_make_map_from_arrays for "
                                  "ArrowArray (sparse union)");
    }
    elements[child_i - offset] = element;
  }
  return {fine::encode(env, atoms::sparse_union), fine::encode(env, elements),
          metadata};
}

static ColumnResult arrow_decimal_to_column(
    ErlNifEnv *env, std::string_view fmt, struct ArrowArray *values,
    int64_t offset, int64_t count,
    fine::ResourcePtr<ArrowArrayStreamRecord> resource, fine::Term metadata) {
  // d:P,S[,N]
  int64_t precision = 0, scale = 0, bits = 128;
  int n = sscanf(fmt.data() + 2, "%" SCNd64 ",%" SCNd64 ",%" SCNd64, &precision,
                 &scale, &bits);
  if (n < 2) {
    throw std::invalid_argument(std::string("invalid decimal format: `") +
                                std::string(fmt) + "`");
  }
  auto tag = bits == 128 ? atoms::decimal128 : atoms::decimal256;
  auto type = fine::encode(env, std::tuple(tag, precision, scale));
  auto data = make_buffer_data(env, values, offset, count, bits / 8, resource);
  return {type, data, metadata};
}

static std::optional<fine::Atom> timestamp_unit_to_atom(char unit) {
  if (unit == 's') {
    return atoms::seconds;
  } else if (unit == 'm') {
    return atoms::milliseconds;
  } else if (unit == 'u') {
    return atoms::microseconds;
  } else if (unit == 'n') {
    return atoms::nanoseconds;
  }
  return std::nullopt;
}

static ColumnResult
arrow_column(ErlNifEnv *env, struct ArrowSchema *schema,
             struct ArrowArray *values, int64_t offset, int64_t count,
             fine::ResourcePtr<ArrowArrayStreamRecord> resource) {
  if (schema == nullptr) {
    throw std::invalid_argument("invalid ArrowSchema (nullptr)");
  }
  if (values == nullptr) {
    throw std::invalid_argument("invalid ArrowArray (nullptr)");
  }

  std::string_view fmt = schema->format ? schema->format : "";

  auto metadata = arrow_metadata_to_nif_term(env, schema->metadata);

  if (count == -1 || count > values->length) {
    count = values->length - offset;
  }

  // Dictionary-encoded: parent format encodes index type, schema->dictionary
  // holds the value type and values->dictionary holds the value data.
  if (schema->dictionary != nullptr) {
    return arrow_dictionary_to_column(env, fmt, schema, values, offset, count,
                                      resource, metadata);
  }

  if (values->dictionary != nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (dictionary), schema->dictionary == nullptr");
  }

  // Primitive types: fixed-size buffers
  if (fmt == "n") {
    auto type = fine::encode(env, atoms::nil);
    auto data = fine::encode(env, atoms::nil);
    return {type, data, metadata};
  } else if (fmt == "b") {
    auto type = fine::encode(env, atoms::boolean);
    auto data = make_boolean_data(env, values, offset, count, resource);
    return {type, data, metadata};
  } else if (fmt == "c") {
    auto type = fine::encode(env, atoms::s8);
    auto data = make_buffer_data(env, values, offset, count, 1, resource);
    return {type, data, metadata};
  } else if (fmt == "C") {
    auto type = fine::encode(env, atoms::u8);
    auto data = make_buffer_data(env, values, offset, count, 1, resource);
    return {type, data, metadata};
  } else if (fmt == "s") {
    auto type = fine::encode(env, atoms::s16);
    auto data = make_buffer_data(env, values, offset, count, 2, resource);
    return {type, data, metadata};
  } else if (fmt == "S") {
    auto type = fine::encode(env, atoms::u16);
    auto data = make_buffer_data(env, values, offset, count, 2, resource);
    return {type, data, metadata};
  } else if (fmt == "i") {
    auto type = fine::encode(env, atoms::s32);
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "I") {
    auto type = fine::encode(env, atoms::u32);
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "l") {
    auto type = fine::encode(env, atoms::s64);
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "L") {
    auto type = fine::encode(env, atoms::u64);
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "e") {
    auto type = fine::encode(env, atoms::f16);
    auto data = make_buffer_data(env, values, offset, count, 2, resource);
    return {type, data, metadata};
  } else if (fmt == "f") {
    auto type = fine::encode(env, atoms::f32);
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "g") {
    auto type = fine::encode(env, atoms::f64);
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};

    // Variable-size binary/string
  } else if (fmt == "z") {
    auto type = fine::encode(env, atoms::binary);
    auto data = make_binary_data<int32_t>(env, values, offset, count, resource);
    return {type, data, metadata};
  } else if (fmt == "Z") {
    auto type = fine::encode(env, atoms::large_binary);
    auto data = make_binary_data<int64_t>(env, values, offset, count, resource);
    return {type, data, metadata};
  } else if (fmt == "u") {
    auto type = fine::encode(env, atoms::string);
    auto data = make_binary_data<int32_t>(env, values, offset, count, resource);
    return {type, data, metadata};
  } else if (fmt == "U") {
    auto type = fine::encode(env, atoms::large_string);
    auto data = make_binary_data<int64_t>(env, values, offset, count, resource);
    return {type, data, metadata};
  } else if (fmt == "vz" || fmt == "vu") {
    auto type = fine::encode(env, (fmt == "vz") ? atoms::binary_view
                                                : atoms::string_view);
    auto data = string_views_from_buffer(env, values, offset, count);
    return {type, data, metadata};

    // Dates
  } else if (fmt == "tdD") {
    auto type = fine::encode(env, atoms::date32);
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "tdm") {
    auto type = fine::encode(env, atoms::date64);
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};

    // Times
  } else if (fmt == "tts") {
    auto type = fine::encode(env, std::tuple(atoms::time32, atoms::seconds));
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "ttm") {
    auto type =
        fine::encode(env, std::tuple(atoms::time32, atoms::milliseconds));
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "ttu") {
    auto type =
        fine::encode(env, std::tuple(atoms::time64, atoms::microseconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "ttn") {
    auto type =
        fine::encode(env, std::tuple(atoms::time64, atoms::nanoseconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};

    // Durations
  } else if (fmt == "tDs") {
    auto type = fine::encode(env, std::tuple(atoms::duration, atoms::seconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "tDm") {
    auto type =
        fine::encode(env, std::tuple(atoms::duration, atoms::milliseconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "tDu") {
    auto type =
        fine::encode(env, std::tuple(atoms::duration, atoms::microseconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "tDn") {
    auto type =
        fine::encode(env, std::tuple(atoms::duration, atoms::nanoseconds));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};

    // Intervals
  } else if (fmt == "tiM") {
    auto type = fine::encode(env, std::tuple(atoms::interval, atoms::month));
    auto data = make_buffer_data(env, values, offset, count, 4, resource);
    return {type, data, metadata};
  } else if (fmt == "tiD") {
    auto type = fine::encode(env, std::tuple(atoms::interval, atoms::day_time));
    auto data = make_buffer_data(env, values, offset, count, 8, resource);
    return {type, data, metadata};
  } else if (fmt == "tin") {
    auto type =
        fine::encode(env, std::tuple(atoms::interval, atoms::month_day_nano));
    auto data = make_buffer_data(env, values, offset, count, 16, resource);
    return {type, data, metadata};

    // Timestamp: tss:, tsm:, tsu:, tsn: [+optional timezone]
  } else if (fmt.size() >= 4 && fmt[0] == 't' && fmt[1] == 's' &&
             fmt[3] == ':') {
    auto unit = timestamp_unit_to_atom(fmt[2]);
    if (unit) {
      auto timezone =
          (fmt.size() > 4) ? std::optional(fmt.substr(4)) : std::nullopt;
      auto type =
          fine::encode(env, std::tuple(atoms::timestamp, unit, timezone));
      auto data = make_buffer_data(env, values, offset, count, 8, resource);
      return {type, data, metadata};
    }

    // Struct
  } else if (fmt == "+s") {
    return arrow_struct_to_column(env, schema, values, offset, count, resource,
                                  metadata);

    // Run-end encoded
  } else if (fmt == "+r") {
    return arrow_run_end_encoded_to_column(env, schema, values, resource,
                                           metadata);

    // Map
  } else if (fmt == "+m") {
    return arrow_map_to_column(env, schema, values, offset, count, resource,
                               metadata);

    // List types
  } else if (fmt == "+l" || fmt == "+L") {
    return arrow_list_to_column(env, fmt, schema, values, offset, count,
                                resource, metadata);

    // List view types
  } else if (fmt == "+vl" || fmt == "+vL") {
    return arrow_list_view_to_column(env, fmt, schema, values, offset, count,
                                     resource, metadata);

    // Fixed-size list
  } else if (fmt.substr(0, 3) == "+w:") {
    return arrow_fixed_size_list_to_column(env, fmt, schema, values, offset,
                                           count, resource, metadata);

    // Fixed-size binary
  } else if (fmt.substr(0, 2) == "w:") {
    return arrow_fixed_size_binary_to_column(env, fmt, values, offset, count,
                                             resource, metadata);

    // Dense union
  } else if (fmt.substr(0, 4) == "+ud:") {
    return arrow_dense_union_to_column(env, schema, values, offset, count,
                                       resource, metadata);

    // Sparse union
  } else if (fmt.substr(0, 4) == "+us:") {
    return arrow_sparse_union_to_column(env, schema, values, offset, count,
                                        resource, metadata);

    // Decimal
  } else if (fmt.substr(0, 2) == "d:") {
    return arrow_decimal_to_column(env, fmt, values, offset, count, resource,
                                   metadata);
  }

  throw std::invalid_argument(std::string("not yet implemented for format: `") +
                              std::string(fmt) + "`");
}

static fine::Term arrow_record_batch_to_columns(ErlNifEnv *env,
                                                struct ArrowSchema *schema,
                                                struct ArrowArray *array) {
  if (schema == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowSchema (nullptr) when invoking next");
  }
  if (array == nullptr) {
    throw std::invalid_argument(
        "invalid ArrowArray (nullptr) at top-level entry");
  }

  std::string_view fmt = schema->format ? schema->format : "";

  // A record batch is always an Arrow struct.
  if (fmt != "+s") {
    throw std::invalid_argument(
        "expected top-level ArrowSchema to be a struct (+s)");
  }

  if (schema->n_children > 0 && schema->children == nullptr) {
    throw std::invalid_argument("invalid ArrowSchema, schema->children == "
                                "nullptr while schema->n_children > 0");
  }

  std::vector<fine::Term> columns(schema->n_children);
  for (int64_t child_i = 0; child_i < schema->n_children; child_i++) {
    struct ArrowSchema *child_schema = schema->children[child_i];
    struct ArrowArray *child_array = array->children[child_i];

    // Create a resource per column to keep the sub-array alive for zero-copy
    // binary slices
    auto record = fine::make_resource<ArrowArrayStreamRecord>();
    NANOARROW_THROW_NOT_OK(
        ArrowSchemaDeepCopy(child_schema, record->schema.get()));
    ArrowArrayMove(child_array, record->values.get());

    auto result = arrow_to_column(env, record->schema.get(),
                                  record->values.get(), record);

    auto name =
        std::string(child_schema->name == nullptr ? "" : child_schema->name);
    ExAdbcField field{name, result.type, result.metadata};
    columns[child_i] =
        fine::encode(env, ExAdbcColumn{field, result.data, std::nullopt});
  }

  return fine::encode(env, columns);
}

} // namespace adbc_nif
